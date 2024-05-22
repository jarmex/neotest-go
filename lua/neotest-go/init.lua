local fn = vim.fn
local Path = require("plenary.path")
local lib = require("neotest.lib")
local logger = require("neotest.logging")
local async = require("neotest.async")
local utils = require("neotest-go.utils")
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
      function: (identifier) @func_name (#match? @func_name "^(Describe|Context|When)$")
      arguments: (argument_list (interpreted_string_literal) @namespace.name (func_literal))
    )) @namespace.definition

    ;;query for It or DescribeTable block
    ((call_expression
        function: (identifier) @func_name
        arguments: (argument_list (interpreted_string_literal) @test.name (func_literal))
    ) (#match? @func_name "^(It|DescribeTable)$")) @test.definition


  ]]

  return lib.treesitter.parse_positions(path, query, {
    require_namespaces = true,
    nested_tests = true,
    -- build_position = "require('neotest-go')._build_position",
    position_id = "require('neotest-go')._generate_position_id",
  })
end

local function get_default_strategy_config(strategy, command, cwd)
  local config = {
    dap = function()
      return {
        name = "Debug Go Tests",
        type = "go",
        request = "launch",
        mode = "test",
        args = { unpack(command, 2) },
        runtimeExecutable = command[1],
        console = "integratedTerminal",
        internalConsoleOptions = "neverOpen",
        rootPath = "${workspaceFolder}",
        cwd = cwd or "${workspaceFolder}",
      }
    end,
  }
  if config[strategy] then
    return config[strategy]()
  end
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
    "ginkgo",
    "-v",
    -- "-json",
    -- "-failfast",
  })

  -- print(vim.inspect(position))
  if position.type == "test" or position.type == "namespace" then
    -- e.g.: id = '/Users/jarmex/Projects/go/testing/main_test.go::"Main"::can_multiply_up_two_numbers',
    local testName = string.sub(position.id, string.find(position.id, "::") + 2)
    testName, _ = string.gsub(testName, "::", " ")
    testName, _ = string.gsub(testName, "_", " ") -- temporary fix for ginkgo
    testName, _ = string.gsub(testName, '"', "")
    vim.list_extend(command, { "--focus", '"' .. testName .. '"' })
  else
    vim.list_extend(command, { dir })
  end

  -- print(vim.inspect(command))

  return {
    command = table.concat(command, " "),
    context = {
      results_path = results_path,
      file = position.path,
      name = position.name,
    },
    strategy = get_default_strategy_config(args.strategy, command, position.path),
  }
end

---@async
---@param spec neotest.RunSpec
---@param result neotest.StrategyResult
---@param tree neotest.Tree
---@return table<string, neotest.Result[]>
function GoLangNeotestAdapter.results(spec, result, tree)
  local success, lines = pcall(lib.files.read_lines, result.output)
  if not success then
    logger.error("neotest-go: could not read output: " .. lines)
    return {}
  end

  return GoLangNeotestAdapter.prepare_results(tree, lines)
end

local isTestFailed = function(lines, testname)
  testname = string.gsub(testname, '"', "")
  local pattern = "%[%w+.*%].+%[It%]%s" .. testname

  for _, text in ipairs(lines) do
    for line in text:gmatch("[^\r\n]+") do
      if line:find(pattern) then
        return test_statuses.fail
      end
    end
  end

  return test_statuses.pass
end

local isTestAllFailed = function(lines)
  local pattern = "(%u+)!.+%d+%s*Passed.+%d+%s*Failed.+%d+%s*Pending.+%d+%s*Skipped"

  for _, text in ipairs(lines) do
    for line in text:gmatch("[^\r\n]+") do
      local status = line:match(pattern)
      if status and status == "FAIL" then
        -- print("Status: " .. status)
        return test_statuses.fail
      end
    end
  end

  return test_statuses.pass
end

---@param tree neotest.Tree
---@param lines string[]
---@param go_root string
---@param go_module string
---@return table<string, neotest.Result[]>
function GoLangNeotestAdapter.prepare_results(tree, lines)
  local results = {}
  local empty_result_fname
  empty_result_fname = async.fn.tempname()
  fn.writefile(lines, empty_result_fname)

  for _, node in tree:iter_nodes() do
    local value = node:data()

    if value.type == "file" then
      results[value.id] = {
        status = isTestAllFailed(lines),
        output = empty_result_fname,
      }
    elseif value.type == "test" then
      results[value.id] = {
        status = isTestAllFailed(lines),
        output = empty_result_fname,
      }
    else
      results[value.id] = {
        status = isTestFailed(lines, value.name),
        output = empty_result_fname,
      }
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
