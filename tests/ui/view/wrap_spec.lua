-- Test: diff.wrap option
-- Long lines should wrap instead of clipping when diff.wrap is enabled.

local spec_path = debug.getinfo(1, "S").source:sub(2)
local plugin_root = vim.fn.fnamemodify(spec_path, ":p:h:h:h:h")
vim.opt.rtp:prepend(plugin_root)
package.path = package.path .. ";" .. plugin_root .. "/lua/?.lua;" .. plugin_root .. "/lua/?/init.lua"

local h = dofile("tests/helpers.lua")
h.ensure_plugin_loaded()

local config = require("codediff.config")
local lifecycle = require("codediff.ui.lifecycle")

local LONG_LINE =
  "func veryLongSignature(ctx context.Context, a uuid.UUID, b uuid.UUID, c uuid.UUID) ([]stylophone.MatchedTrack, error)"

local function open_diff(repo)
  vim.fn.chdir(repo.dir)
  vim.cmd("edit " .. repo.path("main.go"))
  vim.cmd("CodeDiff")

  local tabpage
  local ready = vim.wait(10000, function()
    for _, tp in ipairs(vim.api.nvim_list_tabpages()) do
      local session = lifecycle.get_session(tp)
      if session and session.stored_diff_result then
        tabpage = tp
        return true
      end
    end
    return false
  end, 100)

  assert.is_true(ready, "CodeDiff should open a session")
  return lifecycle.get_session(tabpage)
end

local function wrap_values(session)
  local values = {}
  for _, name in ipairs({ "original_win", "modified_win" }) do
    local win = session[name]
    if win and vim.api.nvim_win_is_valid(win) then
      table.insert(values, vim.wo[win].wrap)
    end
  end
  return values
end

describe("diff.wrap", function()
  local repo
  local original_cwd

  local function setup_repo(layout, wrap)
    require("codediff").setup({ diff = { layout = layout, wrap = wrap } })
    original_cwd = vim.fn.getcwd()

    repo = h.create_temp_git_repo()
    repo.write_file("main.go", { "package main", LONG_LINE })
    repo.git("add main.go")
    repo.git("commit -m initial")
    repo.write_file("main.go", { "package main", LONG_LINE .. " // changed" })
  end

  after_each(function()
    vim.cmd("tabnew")
    vim.cmd("tabonly")
    vim.wait(200)
    if original_cwd then
      vim.fn.chdir(original_cwd)
    end
    if repo then
      repo.cleanup()
      repo = nil
    end
    require("codediff").setup({})
  end)

  it("defaults to off", function()
    require("codediff").setup({})
    assert.is_false(config.options.diff.wrap)
  end)

  it("leaves wrap off in inline layout by default", function()
    setup_repo("inline", nil)
    local values = wrap_values(open_diff(repo))
    assert.is_true(#values > 0, "session should expose at least one window")
    for _, value in ipairs(values) do
      assert.is_false(value)
    end
  end)

  it("enables wrap in inline layout when requested", function()
    setup_repo("inline", true)
    local values = wrap_values(open_diff(repo))
    assert.is_true(#values > 0, "session should expose at least one window")
    for _, value in ipairs(values) do
      assert.is_true(value)
    end
  end)

  it("enables wrap in side-by-side layout when requested", function()
    setup_repo("side-by-side", true)
    local values = wrap_values(open_diff(repo))
    assert.is_true(#values > 0, "session should expose at least one window")
    for _, value in ipairs(values) do
      assert.is_true(value)
    end
  end)
end)
