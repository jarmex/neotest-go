local fn = vim.fn
local Path = require("plenary.path")
local lib = require("neotest.lib")
local logger = require("neotest.logging")
local async = require("neotest.async")
local utils = require("neotest-go.utils")
local output = require("neotest-go.output")
local test_statuses = require("neotest-go.test_status")

local recursive_run = function()
  return false
end

---@type neotest.Adapter
local GoLangNeotestAdapter = { name = "neotest-go" }

GoLangNeotestAdapter.root = lib.files.match_root_pattern("go.mod", "go.sum")

function GoLangNeotestAdapter.is_test_file(file_path)
  if not vim.endswith(file_path, ".go") then
    return false
  end
  local elems = vim.split(file_path, Path.path.sep)
  local file_name = elems[#elems]
  local is_test = vim.endswith(file_name, "_test.go")
  return is_test
end

---@param position neotest.Position The position to return an ID for
---@param namespaces neotest.Position[] Any namespaces the position is within
function GoLangNeotestAdapter._generate_position_id(position, namespaces)
  local prefix = {}
  for _, namespace in ipairs(namespaces) do
    if namespace.type ~= "file" then
      table.insert(prefix, namespace.name)
    end
  end
  local name = utils.transform_test_name(position.name)
  return table.concat(vim.tbl_flatten({ position.path, prefix, name }), "::")
end

---@async
---@return neotest.Tree| nil
function GoLangNeotestAdapter.discover_positions(path)
  local query = [[
    ;;query for Namespace or Context Block
    ((call_expression
      function: (identifier) @func_name (#match? @func_name "^(Describe|Context)$")
      arguments: (argument_list (_) @namespace.name (func_literal))
    )) @namespace.definition

    ;;query for It or DescribeTable block
    ((call_expression
        function: (identifier) @func_name
        arguments: (argument_list (_) @test.name (func_literal))
    ) (#match? @func_name "^(It|DescribeTable)$")) @test.definition


  ]]

  return lib.treesitter.parse_positions(path, query, {
    require_namespaces = true,
    nested_tests = true,
    -- build_position = "require('neotest-go')._build_position",
    position_id = "require('neotest-go')._generate_position_id",
  })
end

local function escapeTestPattern(s)
  return (
    s:gsub("%(", "%\\(")
      :gsub("%)", "%\\)")
      :gsub("%]", "%\\]")
      :gsub("%[", "%\\[")
      :gsub("%*", "%\\*")
      :gsub("%+", "%\\+")
      :gsub("%-", "%\\-")
      :gsub("%?", "%\\?")
      :gsub("%$", "%\\$")
      :gsub("%^", "%\\^")
      :gsub("%/", "%\\/")
      :gsub("%'", "%\\'")
  )
end

---@async
---@param args neotest.RunArgs
---@return nil | neotest.RunSpec | neotest.RunSpec[]
GoLangNeotestAdapter.build_spec = function(args)
  local results_path = async.fn.tempname() .. ".json"
  local tree = args.tree

  if not tree then
    return
  end

  local position = tree:data()

  local dir = "./"
  if recursive_run() then
    dir = "./..."
  end

  local location = position.path
  if fn.isdirectory(position.path) ~= 1 then
    location = fn.fnamemodify(position.path, ":h")
  end

  local command = vim.tbl_flatten({
    "cd",
    location,
    "&&",
    "go",
    "test",
    "-v",
    "-json",
  })

  local testNamePattern = position.name
  if position.type == "test" or position.type == "namespace" then
    -- pos.id in form "path/to/file::Describe text::test text"
    -- e.g.: id = '/Users/jarmex/Projects/go/testing/main_test.go::"Main"::can_multiply_up_two_numbers',
    local testName = string.sub(position.id, string.find(position.id, "::") + 2)
    testName, _ = string.gsub(testName, "::", " ")
    testName, _ = string.gsub(testName, '"', "")
    testNamePattern = escapeTestPattern(testName)
    vim.list_extend(command, { "-ginkgo.focus", '"' .. testNamePattern .. '"' })
  else
    vim.list_extend(command, { dir })
  end

  return {
    command = table.concat(command, " "),
    context = {
      results_path = results_path,
      file = position.path,
      name = position.name,
    },
  }
end

---@async
---@param spec neotest.RunSpec
---@param result neotest.StrategyResult
---@param tree neotest.Tree
---@return table<string, neotest.Result[]>
function GoLangNeotestAdapter.results(spec, result, tree)
  local go_root = utils.get_go_root(spec.context.file)
  if not go_root then
    return {}
  end
  local go_module = utils.get_go_module_name(go_root)
  if not go_module then
    return {}
  end

  local success, lines = pcall(lib.files.read_lines, result.output)
  if not success then
    logger.error("neotest-go: could not read output: " .. lines)
    return {}
  end
  return GoLangNeotestAdapter.prepare_results(tree, lines, go_root, go_module)
end

---@param tree neotest.Tree
---@param lines string[]
---@param go_root string
---@param go_module string
---@return table<string, neotest.Result[]>
function GoLangNeotestAdapter.prepare_results(tree, lines, go_root, go_module)
  local tests, log = output.marshal_gotest_output(lines)
  local results = {}
  local no_results = vim.tbl_isempty(tests)
  local empty_result_fname
  local file_id
  empty_result_fname = async.fn.tempname()
  fn.writefile(log, empty_result_fname)

  for _, node in tree:iter_nodes() do
    local value = node:data()
    if no_results then
      results[value.id] = {
        status = test_statuses.fail,
        output = empty_result_fname,
      }
      break
    end
    if value.type == "file" then
      results[value.id] = {
        status = test_statuses.pass,
        output = empty_result_fname,
      }
      file_id = value.id
    else
      -- this is a hack for now. if one test fails all tests fails. However, the test that passed should still be marked as passed [TODO]
      local _, test = next(tests)

      local fname = async.fn.tempname()
      fn.writefile(test.output, fname)
      results[value.id] = {
        status = test.status,
        output = fname,
      }

      local errors = utils.get_errors_from_test(test, utils.get_filename_from_id(value.id))
      if errors then
        results[value.id].errors = errors
      end
      if test.status == test_statuses.fail and file_id then
        results[file_id].status = test_statuses.fail
      end
    end
  end

  return results
end

local is_callable = function(obj)
  return type(obj) == "function" or (type(obj) == "table" and obj.__call)
end

setmetatable(GoLangNeotestAdapter, {
  __call = function(_, opts)
    if is_callable(opts.experimental) then
      get_experimental_opts = opts.experimental
    elseif opts.experimental then
      get_experimental_opts = function()
        return opts.experimental
      end
    end

    if is_callable(opts.args) then
      get_args = opts.args
    elseif opts.args then
      get_args = function()
        return opts.args
      end
    end

    if is_callable(opts.recursive_run) then
      recursive_run = opts.recursive_run
    elseif opts.recursive_run then
      recursive_run = function()
        return opts.recursive_run
      end
    end
    return GoLangNeotestAdapter
  end,
})

return GoLangNeotestAdapter
