-- Module loading tests for explorer submodules
-- Validates that require() wiring works correctly after _set_*_module removal

describe("Explorer submodules", function()
  describe("module loading", function()
    it("loads actions module", function()
      local ok, mod = pcall(require, "codediff.ui.explorer.actions")
      assert.is_true(ok, "Failed to require codediff.ui.explorer.actions: " .. tostring(mod))
      assert.is_not_nil(mod)
    end)

    it("loads keymaps module", function()
      local ok, mod = pcall(require, "codediff.ui.explorer.keymaps")
      assert.is_true(ok, "Failed to require codediff.ui.explorer.keymaps")
      assert.is_not_nil(mod)
    end)

    it("loads render module", function()
      local ok, mod = pcall(require, "codediff.ui.explorer.render")
      assert.is_true(ok, "Failed to require codediff.ui.explorer.render")
      assert.is_not_nil(mod)
    end)

    it("loads refresh module", function()
      local ok, mod = pcall(require, "codediff.ui.explorer.refresh")
      assert.is_true(ok, "Failed to require codediff.ui.explorer.refresh")
      assert.is_not_nil(mod)
    end)

    it("loads tree module", function()
      local ok, mod = pcall(require, "codediff.ui.explorer.tree")
      assert.is_true(ok, "Failed to require codediff.ui.explorer.tree")
      assert.is_not_nil(mod)
    end)

    it("loads init facade", function()
      local ok, mod = pcall(require, "codediff.ui.explorer")
      assert.is_true(ok, "Failed to require codediff.ui.explorer")
      assert.is_not_nil(mod)
    end)
  end)

  describe("public API", function()
    it("actions exports expected functions", function()
      local mod = require("codediff.ui.explorer.actions")
      assert.is_function(mod.navigate_next)
      assert.is_function(mod.navigate_prev)
      assert.is_function(mod.toggle_visibility)
      assert.is_function(mod.toggle_view_mode)
      assert.is_function(mod.toggle_stage_file)
      assert.is_function(mod.toggle_stage_entry)
      assert.is_function(mod.stage_all)
      assert.is_function(mod.unstage_all)
      assert.is_function(mod.restore_entry)
    end)

    it("keymaps exports setup function", function()
      local mod = require("codediff.ui.explorer.keymaps")
      assert.is_function(mod.setup)
    end)

    it("render exports create function", function()
      local mod = require("codediff.ui.explorer.render")
      assert.is_function(mod.create)
    end)

    it("refresh exports expected functions", function()
      local mod = require("codediff.ui.explorer.refresh")
      assert.is_function(mod.setup_auto_refresh)
      assert.is_function(mod.refresh)
      assert.is_function(mod.get_all_files)
    end)

    it("tree exports create_tree_data", function()
      local mod = require("codediff.ui.explorer.tree")
      assert.is_function(mod.create_tree_data)
    end)
  end)
end)

describe("explorer file navigation with a skip", function()
  local actions = require("codediff.ui.explorer.actions")
  local refresh = require("codediff.ui.explorer.refresh")
  local config = require("codediff.config")
  local original_get_all_files, original_cycle

  local paths = { "shop/a.go", "shop/b.go", "other/c.go" }

  before_each(function()
    original_get_all_files = refresh.get_all_files
    original_cycle = config.options.diff.cycle_next_file
    refresh.get_all_files = function()
      return vim.tbl_map(function(path)
        return { data = { path = path, group = "unstaged" } }
      end, paths)
    end
  end)

  after_each(function()
    refresh.get_all_files = original_get_all_files
    config.options.diff.cycle_next_file = original_cycle
  end)

  local function step(fn, from, skip)
    local selected
    local explorer = {
      tree = {},
      winid = -1,
      current_file_path = from,
      current_file_group = "unstaged",
      on_file_select = function(data)
        selected = data.path
      end,
    }
    fn(explorer, skip)
    return selected
  end

  local function in_shop(data)
    return data.path:match("^shop/") ~= nil
  end

  it("passes over skipped files in both directions", function()
    config.options.diff.cycle_next_file = true
    assert.equals("other/c.go", step(actions.navigate_next, "shop/a.go", in_shop))
    assert.equals("other/c.go", step(actions.navigate_prev, "shop/b.go", in_shop))
  end)

  it("stops at the end when every file left is skipped and cycling is off", function()
    config.options.diff.cycle_next_file = false
    paths = { "other/c.go", "shop/a.go", "shop/b.go" }
    assert.is_nil(step(actions.navigate_next, "shop/a.go", in_shop))
    paths = { "shop/a.go", "shop/b.go", "other/c.go" }
  end)

  it("steps file by file without a skip", function()
    config.options.diff.cycle_next_file = true
    assert.equals("shop/b.go", step(actions.navigate_next, "shop/a.go"))
    assert.equals("shop/a.go", step(actions.navigate_prev, "shop/b.go"))
  end)
end)
