-- Tests for the skeleton view (codediff.ui.view.skeleton)
local skeleton = require("codediff.ui.view.skeleton")

describe("skeleton.unchanged_regions", function()
  it("derives aligned gaps around a single change", function()
    local changes = {
      { original = { start_line = 5, end_line = 7 }, modified = { start_line = 5, end_line = 10 } },
    }
    local regions = skeleton.unchanged_regions(changes, 20, 23)
    assert.same({
      { orig_start = 1, mod_start = 1, len = 4 },
      { orig_start = 7, mod_start = 10, len = 14 },
    }, regions)
  end)

  it("treats the whole file as unchanged when there are no changes", function()
    local regions = skeleton.unchanged_regions({}, 10, 10)
    assert.same({ { orig_start = 1, mod_start = 1, len = 10 } }, regions)
  end)

  it("handles pure insertions (empty original range)", function()
    local changes = {
      { original = { start_line = 4, end_line = 4 }, modified = { start_line = 4, end_line = 6 } },
    }
    local regions = skeleton.unchanged_regions(changes, 8, 10)
    assert.same({
      { orig_start = 1, mod_start = 1, len = 3 },
      { orig_start = 4, mod_start = 6, len = 5 },
    }, regions)
  end)
end)

describe("skeleton.compute_folds", function()
  it("folds unchanged bodies and mirrors them with the region offset", function()
    -- Symbol at modified lines 10-20, fully inside a region shifted by +3
    local symbols = {
      { name = "f", kind = "function_declaration", start_line = 10, end_line = 20, fold_start = 11, children = {} },
    }
    local regions = { { orig_start = 5, mod_start = 8, len = 20 } }

    local mod_folds, orig_folds = skeleton.compute_folds(symbols, regions)
    assert.same({ { first = 11, last = 20 } }, mod_folds)
    assert.same({ { first = 8, last = 17 } }, orig_folds)
  end)

  it("recurses into children when the symbol touches a change", function()
    local symbols = {
      {
        name = "outer",
        kind = "function_declaration",
        start_line = 1,
        end_line = 30,
        fold_start = 2,
        children = {
          { name = "inner", kind = "function_declaration", start_line = 3, end_line = 8, fold_start = 4, children = {} },
        },
      },
    }
    -- Unchanged region covers only lines 1-10; outer (2-30) doesn't fit, inner body (4-8) does
    local regions = { { orig_start = 1, mod_start = 1, len = 10 } }

    local mod_folds, orig_folds = skeleton.compute_folds(symbols, regions)
    assert.same({ { first = 4, last = 8 } }, mod_folds)
    assert.same({ { first = 4, last = 8 } }, orig_folds)
  end)

  it("skips one-line bodies", function()
    local symbols = {
      { name = "tiny", kind = "function_declaration", start_line = 1, end_line = 2, fold_start = 2, children = {} },
    }
    local regions = { { orig_start = 1, mod_start = 1, len = 10 } }
    local mod_folds = skeleton.compute_folds(symbols, regions)
    assert.same({}, mod_folds)
  end)
end)

describe("skeleton inline fold computation", function()
  it("blocks changed lines and deletion anchors", function()
    local changes = {
      -- modification on lines 4-5
      { original = { start_line = 4, end_line = 6 }, modified = { start_line = 4, end_line = 6 } },
      -- pure deletion anchored at modified line 12
      { original = { start_line = 14, end_line = 16 }, modified = { start_line = 12, end_line = 12 } },
    }
    local blocked = skeleton.inline_blocked_lines(changes, 20)
    assert.same({ [4] = true, [5] = true, [12] = true }, blocked)
  end)

  it("clamps deletion anchors to the buffer end", function()
    local changes = {
      { original = { start_line = 9, end_line = 12 }, modified = { start_line = 11, end_line = 11 } },
    }
    local blocked = skeleton.inline_blocked_lines(changes, 10)
    assert.same({ [10] = true }, blocked)
  end)

  it("folds bodies clear of blocked lines and recurses otherwise", function()
    local symbols = {
      { name = "a", kind = "function_declaration", start_line = 1, end_line = 6, fold_start = 2, children = {} },
      {
        name = "b",
        kind = "function_declaration",
        start_line = 8,
        end_line = 20,
        fold_start = 9,
        children = {
          { name = "inner", kind = "function_declaration", start_line = 9, end_line = 13, fold_start = 10, children = {} },
        },
      },
    }
    -- Line 15 blocked: b cannot fold, but inner (10-13) can; a (2-6) is clear
    local folds = skeleton.compute_folds_inline(symbols, { [15] = true })
    assert.same({ { first = 2, last = 6 }, { first = 10, last = 13 } }, folds)
  end)
end)

describe("skeleton view toggle (integration)", function()
  local lifecycle = require("codediff.ui.lifecycle")
  local session_mod = require("codediff.ui.lifecycle.session")

  local tabpage, orig_buf, mod_buf, orig_win, mod_win

  local original_content = {
    "local M = {}",
    "",
    "function M.alpha()",
    "  local x = 1",
    "  local y = 2",
    "  return x + y",
    "end",
    "",
    "function M.beta()",
    "  return 2",
    "end",
    "",
    "return M",
  }

  -- beta's body changed on line 10; alpha untouched
  local modified_content = vim.deepcopy(original_content)
  modified_content[10] = "  return 3"

  before_each(function()
    vim.cmd("tabnew")
    tabpage = vim.api.nvim_get_current_tabpage()

    orig_buf = vim.api.nvim_create_buf(false, true)
    mod_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(orig_buf, 0, -1, false, original_content)
    vim.api.nvim_buf_set_lines(mod_buf, 0, -1, false, modified_content)
    vim.bo[orig_buf].filetype = "lua"
    vim.bo[mod_buf].filetype = "lua"

    orig_win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(orig_win, orig_buf)
    vim.cmd("rightbelow vsplit")
    mod_win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(mod_win, mod_buf)

    session_mod.get_active_diffs()[tabpage] = {
      mode = "standalone",
      layout = "side-by-side",
      original_bufnr = orig_buf,
      modified_bufnr = mod_buf,
      original_win = orig_win,
      modified_win = mod_win,
      stored_diff_result = {
        changes = {
          {
            original = { start_line = 10, end_line = 11 },
            modified = { start_line = 10, end_line = 11 },
          },
        },
      },
    }
  end)

  after_each(function()
    skeleton.disable(tabpage)
    session_mod.get_active_diffs()[tabpage] = nil
    while vim.fn.tabpagenr("$") > 1 do
      vim.cmd("tabclose!")
    end
    for _, buf in ipairs({ orig_buf, mod_buf }) do
      if buf and vim.api.nvim_buf_is_valid(buf) then
        vim.api.nvim_buf_delete(buf, { force = true })
      end
    end
  end)

  it("folds the unchanged function body in both panes", function()
    assert.is_true(skeleton.enable(tabpage))
    assert.is_true(skeleton.is_active(tabpage))

    -- alpha's body (lines 4-7) folds in both windows, anchored at line 4
    assert.equals(
      4,
      vim.api.nvim_win_call(mod_win, function()
        return vim.fn.foldclosed(5)
      end)
    )
    assert.equals(
      4,
      vim.api.nvim_win_call(orig_win, function()
        return vim.fn.foldclosed(5)
      end)
    )

    -- beta touches the hunk: no fold on its body
    assert.equals(
      -1,
      vim.api.nvim_win_call(mod_win, function()
        return vim.fn.foldclosed(10)
      end)
    )

    -- signature line stays visible
    assert.equals(
      -1,
      vim.api.nvim_win_call(mod_win, function()
        return vim.fn.foldclosed(3)
      end)
    )
  end)

  it("disable removes folds and state", function()
    assert.is_true(skeleton.enable(tabpage))
    skeleton.disable(tabpage)
    assert.is_false(skeleton.is_active(tabpage))
    assert.equals(
      -1,
      vim.api.nvim_win_call(mod_win, function()
        return vim.fn.foldclosed(5)
      end)
    )
  end)

  it("cycle steps off → skeleton → seams → off", function()
    local session = session_mod.get_active_diffs()[tabpage]

    skeleton.cycle(tabpage)
    assert.is_true(skeleton.is_active(tabpage))
    assert.equals("skeleton", session.skeleton_want)

    skeleton.cycle(tabpage)
    assert.is_true(skeleton.is_active(tabpage))
    assert.equals("seams", session.skeleton_want)

    skeleton.cycle(tabpage)
    assert.is_false(skeleton.is_active(tabpage))
    assert.is_nil(session.skeleton_want)
  end)

  it("seams mode folds changed bodies too, paired by name", function()
    assert.is_true(skeleton.enable(tabpage, { mode = "seams" }))

    -- alpha (unchanged) folds via region mirror
    assert.equals(
      4,
      vim.api.nvim_win_call(mod_win, function()
        return vim.fn.foldclosed(5)
      end)
    )
    -- beta's body changed, but in seams mode it folds anyway — on both sides
    assert.equals(
      10,
      vim.api.nvim_win_call(mod_win, function()
        return vim.fn.foldclosed(10)
      end)
    )
    assert.equals(
      10,
      vim.api.nvim_win_call(orig_win, function()
        return vim.fn.foldclosed(10)
      end)
    )
    -- signatures stay visible
    assert.equals(
      -1,
      vim.api.nvim_win_call(mod_win, function()
        return vim.fn.foldclosed(9)
      end)
    )
  end)

  it("re-applies after a render when sticky", function()
    assert.is_true(skeleton.enable(tabpage))

    -- Simulate a file switch dropping the folds
    skeleton.reset(tabpage)
    assert.is_false(skeleton.is_active(tabpage))

    vim.api.nvim_exec_autocmds("User", { pattern = "CodeDiffRender", data = { tabpage = tabpage } })
    vim.wait(500, function()
      return skeleton.is_active(tabpage)
    end)

    assert.is_true(skeleton.is_active(tabpage))
    assert.equals(
      4,
      vim.api.nvim_win_call(mod_win, function()
        return vim.fn.foldclosed(5)
      end)
    )
  end)

  it("disable clears stickiness", function()
    assert.is_true(skeleton.enable(tabpage))
    skeleton.disable(tabpage)

    vim.api.nvim_exec_autocmds("User", { pattern = "CodeDiffRender", data = { tabpage = tabpage } })
    vim.wait(100)

    assert.is_false(skeleton.is_active(tabpage))
  end)

  it("folds unchanged bodies in inline layout using the single pane", function()
    -- Rebuild the session as inline: one window showing the modified buffer
    local session = session_mod.get_active_diffs()[tabpage]
    session.layout = "inline"
    session.original_win = mod_win
    session.modified_win = mod_win

    assert.is_true(skeleton.enable(tabpage))

    -- alpha's body folds
    assert.equals(
      4,
      vim.api.nvim_win_call(mod_win, function()
        return vim.fn.foldclosed(5)
      end)
    )
    -- beta touches the hunk: stays open
    assert.equals(
      -1,
      vim.api.nvim_win_call(mod_win, function()
        return vim.fn.foldclosed(10)
      end)
    )
    -- the original window was never touched
    assert.is_nil(session.skeleton.saved[orig_win])
  end)

  it("inline layout never folds deletion anchor lines", function()
    -- Pure deletion anchored inside alpha's body (modified line 5)
    local session = session_mod.get_active_diffs()[tabpage]
    session.layout = "inline"
    session.original_win = mod_win
    session.modified_win = mod_win
    session.stored_diff_result = {
      changes = {
        {
          original = { start_line = 5, end_line = 7 },
          modified = { start_line = 5, end_line = 5 },
        },
      },
    }

    assert.is_true(skeleton.enable(tabpage))

    -- alpha's body contains the anchor: not folded
    assert.equals(
      -1,
      vim.api.nvim_win_call(mod_win, function()
        return vim.fn.foldclosed(5)
      end)
    )
    -- beta is unchanged here: folded
    assert.equals(
      10,
      vim.api.nvim_win_call(mod_win, function()
        return vim.fn.foldclosed(11)
      end)
    )
  end)
end)
