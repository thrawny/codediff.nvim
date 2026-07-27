-- Tests for impl-only file splitting in explorer tree building
local tree_module = require("codediff.ui.explorer.tree")
local config = require("codediff.config")

local function make_status(unstaged, staged)
  return {
    unstaged = unstaged or {},
    staged = staged or {},
    conflicts = {},
  }
end

local function labels(nodes)
  local result = {}
  for _, node in ipairs(nodes) do
    table.insert(result, node.text)
  end
  return result
end

local function find_group(nodes, prefix)
  for _, node in ipairs(nodes) do
    if vim.startswith(node.text, prefix) then
      return node
    end
  end
  return nil
end

describe("explorer tree impl-only split", function()
  local git_root = vim.fn.getcwd()

  it("keeps all files in the regular group without seam results", function()
    local status = make_status({
      { path = "a.lua", status = "M" },
      { path = "b.lua", status = "M" },
    })
    local nodes = tree_module.create_tree_data(status, git_root, nil, false, nil, nil)
    assert.is_not_nil(find_group(nodes, "Changes (2)"))
    assert.is_nil(find_group(nodes, "Implementation-only"))
  end)

  it("moves impl-classified modified files into a collapsed group", function()
    local status = make_status({
      { path = "a.lua", status = "M" },
      { path = "b.lua", status = "M" },
    })
    local seam_results = {
      ["unstaged:a.lua"] = { result = "impl", fingerprint = "x" },
      ["unstaged:b.lua"] = { result = "seam", fingerprint = "x" },
    }
    local nodes = tree_module.create_tree_data(status, git_root, nil, false, nil, seam_results)

    assert.is_not_nil(find_group(nodes, "Changes (1)"))
    local impl_group = find_group(nodes, "Implementation-only Changes (1)")
    assert.is_not_nil(impl_group, "missing impl-only group in: " .. vim.inspect(labels(nodes)))
    assert.is_true(impl_group.data.default_collapsed)
    assert.equals("unstaged", impl_group.data.name)
  end)

  it("splits staged files into their own impl-only group", function()
    local status = make_status({}, {
      { path = "a.lua", status = "M" },
    })
    local seam_results = {
      ["staged:a.lua"] = { result = "impl", fingerprint = "x" },
    }
    local nodes = tree_module.create_tree_data(status, git_root, nil, false, nil, seam_results)

    assert.is_not_nil(find_group(nodes, "Staged Changes (0)"))
    local impl_group = find_group(nodes, "Implementation-only Staged Changes (1)")
    assert.is_not_nil(impl_group)
    assert.equals("staged", impl_group.data.name)
  end)

  it("never moves added/deleted/renamed files", function()
    local status = make_status({
      { path = "a.lua", status = "A" },
    })
    local seam_results = {
      ["unstaged:a.lua"] = { result = "impl", fingerprint = "x" },
    }
    local nodes = tree_module.create_tree_data(status, git_root, nil, false, nil, seam_results)

    assert.is_not_nil(find_group(nodes, "Changes (1)"))
    assert.is_nil(find_group(nodes, "Implementation-only"))
  end)

  it("keys results by group, not just path", function()
    local status = make_status({
      { path = "a.lua", status = "M" },
    })
    -- Result exists only for the staged copy; the unstaged one stays regular
    local seam_results = {
      ["staged:a.lua"] = { result = "impl", fingerprint = "x" },
    }
    local nodes = tree_module.create_tree_data(status, git_root, nil, false, nil, seam_results)
    assert.is_not_nil(find_group(nodes, "Changes (1)"))
    assert.is_nil(find_group(nodes, "Implementation-only"))
  end)

  it("honors collapse_impl_only = false", function()
    local saved = config.options.explorer.collapse_impl_only
    config.options.explorer.collapse_impl_only = false

    local status = make_status({
      { path = "a.lua", status = "M" },
    })
    local seam_results = {
      ["unstaged:a.lua"] = { result = "impl", fingerprint = "x" },
    }
    local nodes = tree_module.create_tree_data(status, git_root, nil, false, nil, seam_results)

    config.options.explorer.collapse_impl_only = saved

    assert.is_not_nil(find_group(nodes, "Changes (1)"))
    assert.is_nil(find_group(nodes, "Implementation-only"))
  end)

  it("adds the impl-only group in revision mode", function()
    local status = make_status({
      { path = "a.lua", status = "M" },
      { path = "b.lua", status = "M" },
    })
    local seam_results = {
      ["unstaged:b.lua"] = { result = "impl", fingerprint = "x" },
    }
    local nodes = tree_module.create_tree_data(status, git_root, "HEAD~1", false, nil, seam_results)

    assert.is_not_nil(find_group(nodes, "Changes (1)"))
    assert.is_not_nil(find_group(nodes, "Implementation-only Changes (1)"))
  end)
end)
