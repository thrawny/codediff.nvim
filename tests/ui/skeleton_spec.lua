-- Tests for the skeleton view (codediff.ui.view.skeleton)
local skeleton = require("codediff.ui.view.skeleton")
local config = require("codediff.config")

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

describe("skeleton focused fold computation", function()
  local function structure(symbols, imports, data)
    return { symbols = symbols or {}, imports = imports or {}, data = data or {} }
  end

  it("hides body-only changes", function()
    local changes = {
      { original = { start_line = 20, end_line = 21 }, modified = { start_line = 20, end_line = 21 } },
    }
    local parsed = structure({
      { name = "target", start_line = 10, end_line = 25, fold_start = 11, children = {} },
    })

    local mod_folds, orig_folds = skeleton.compute_focused_folds(changes, parsed, parsed, 30, 30)
    assert.same({ { first = 1, last = 30 } }, mod_folds)
    assert.same({ { first = 1, last = 30 } }, orig_folds)
  end)

  it("shows a changed multi-line signature without its body", function()
    local changes = {
      { original = { start_line = 11, end_line = 12 }, modified = { start_line = 11, end_line = 12 } },
    }
    local parsed = structure({
      { name = "target", start_line = 10, end_line = 25, fold_start = 13, children = {} },
    })

    local folds = skeleton.compute_focused_folds_inline(changes, parsed, 30)
    assert.same({
      { first = 1, last = 9 },
      { first = 13, last = 30 },
    }, folds)
  end)

  it("shows a changed data declaration in full", function()
    local changes = {
      { original = { start_line = 11, end_line = 12 }, modified = { start_line = 11, end_line = 12 } },
    }
    local parsed = structure({}, {}, { { first = 8, last = 15 } })

    local folds = skeleton.compute_focused_folds_inline(changes, parsed, 20)
    assert.same({
      { first = 1, last = 7 },
      { first = 16, last = 20 },
    }, folds)
  end)

  it("hides import-only changes", function()
    local changes = {
      { original = { start_line = 9, end_line = 10 }, modified = { start_line = 9, end_line = 10 } },
    }
    local parsed = structure({}, { { first = 8, last = 10 } })
    local folds = skeleton.compute_focused_folds_inline(changes, parsed, 20)
    assert.same({ { first = 1, last = 20 } }, folds)
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

  it("focused mode hides implementation-only changes", function()
    assert.is_true(skeleton.enable(tabpage, { mode = "focused" }))
    assert.is_true(skeleton.is_active(tabpage))

    for _, win in ipairs({ mod_win, orig_win }) do
      assert.equals(
        1,
        vim.api.nvim_win_call(win, function()
          return vim.fn.foldclosed(10)
        end)
      )
    end
  end)

  it("focused mode shows a changed signature and hides its body", function()
    local session = session_mod.get_active_diffs()[tabpage]
    vim.api.nvim_buf_set_lines(mod_buf, 8, 9, false, { "function M.beta(value)" })
    session.stored_diff_result = {
      changes = {
        { original = { start_line = 9, end_line = 10 }, modified = { start_line = 9, end_line = 10 } },
      },
    }

    assert.is_true(skeleton.enable(tabpage, { mode = "focused" }))
    assert.equals(
      -1,
      vim.api.nvim_win_call(mod_win, function()
        return vim.fn.foldclosed(9)
      end)
    )
    assert.equals(
      10,
      vim.api.nvim_win_call(mod_win, function()
        return vim.fn.foldclosed(10)
      end)
    )
  end)

  it("focused mode shows a changed top-level struct in full", function()
    local session = session_mod.get_active_diffs()[tabpage]
    local original = {
      "struct User {",
      "  int id;",
      "};",
      "",
      "int helper(void) {",
      "  return 1;",
      "}",
    }
    local modified = vim.deepcopy(original)
    modified[2] = "  long id;"
    vim.api.nvim_buf_set_lines(orig_buf, 0, -1, false, original)
    vim.api.nvim_buf_set_lines(mod_buf, 0, -1, false, modified)
    vim.bo[orig_buf].filetype = "c"
    vim.bo[mod_buf].filetype = "c"
    session.stored_diff_result = {
      changes = {
        { original = { start_line = 2, end_line = 3 }, modified = { start_line = 2, end_line = 3 } },
      },
    }

    assert.is_true(skeleton.enable(tabpage, { mode = "focused" }))
    for line = 1, 3 do
      assert.equals(
        -1,
        vim.api.nvim_win_call(mod_win, function()
          return vim.fn.foldclosed(line)
        end)
      )
    end
    assert.equals(
      4,
      vim.api.nvim_win_call(mod_win, function()
        return vim.fn.foldclosed(5)
      end)
    )
  end)

  it("pads focused hidden-lines rows above and below", function()
    local session = session_mod.get_active_diffs()[tabpage]
    vim.api.nvim_buf_set_lines(mod_buf, 0, 1, false, { "local M = { version = 2 }" })
    vim.api.nvim_buf_set_lines(mod_buf, 12, 13, false, { "return setmetatable(M, {})" })
    session.stored_diff_result = {
      changes = {
        { original = { start_line = 1, end_line = 2 }, modified = { start_line = 1, end_line = 2 } },
        { original = { start_line = 13, end_line = 14 }, modified = { start_line = 13, end_line = 14 } },
      },
    }

    assert.is_true(skeleton.enable(tabpage, { mode = "focused" }))
    for _, pane in ipairs({ { buf = orig_buf, win = orig_win }, { buf = mod_buf, win = mod_win } }) do
      local marks = vim.api.nvim_buf_get_extmarks(pane.buf, skeleton.ns_spacer, 0, -1, { details = true })
      assert.equals(2, #marks)
      assert.equals(0, marks[1][2])
      assert.equals(12, marks[2][2])
      local above, below = 0, 0
      for _, mark in ipairs(marks) do
        local spacer_chunk = mark[4].virt_lines[1][1]
        assert.equals(500, #spacer_chunk[1])
        assert.equals("CodeDiffSkeletonSpacer", spacer_chunk[2])
        assert.equals(config.options.diff.highlight_priority + 1, mark[4].priority)
        assert.equals(nil, spacer_chunk[1]:find("%S"))
        assert.equals(
          -1,
          vim.api.nvim_win_call(pane.win, function()
            return vim.fn.foldclosed(mark[2] + 1)
          end)
        )
        if mark[4].virt_lines_above then
          above = above + 1
        else
          below = below + 1
        end
      end
      assert.equals(1, above)
      assert.equals(1, below)
    end

    skeleton.disable(tabpage)
    for _, buf in ipairs({ orig_buf, mod_buf }) do
      assert.same({}, vim.api.nvim_buf_get_extmarks(buf, skeleton.ns_spacer, 0, -1, {}))
    end
  end)

  it("puts inline fold padding before deleted and added signature pairs", function()
    local inline = require("codediff.ui.inline")
    local session = session_mod.get_active_diffs()[tabpage]
    session.layout = "inline"
    session.original_win = mod_win
    session.modified_win = mod_win

    local signature_content = vim.deepcopy(modified_content)
    signature_content[9] = "function M.beta(value)"
    vim.api.nvim_buf_set_lines(mod_buf, 0, -1, false, signature_content)
    session.stored_diff_result = {
      changes = {
        {
          original = { start_line = 9, end_line = 10 },
          modified = { start_line = 9, end_line = 10 },
          inner_changes = {},
        },
      },
    }
    inline.render_inline_diff(mod_buf, session.stored_diff_result, original_content, signature_content)

    assert.is_true(skeleton.enable(tabpage, { mode = "focused" }))
    local function deletion_mark()
      local marks = vim.api.nvim_buf_get_extmarks(mod_buf, inline.ns_inline, { 8, 0 }, { 8, -1 }, { details = true })
      for _, mark in ipairs(marks) do
        if mark[4].virt_lines then
          return mark
        end
      end
    end

    local mark = assert(deletion_mark())
    assert.equals("CodeDiffSkeletonSpacer", mark[4].virt_lines[1][1][2])
    assert.is_true(#mark[4].virt_lines > 1)

    skeleton.disable(tabpage)
    mark = assert(deletion_mark())
    assert.are_not.equal("CodeDiffSkeletonSpacer", mark[4].virt_lines[1][1][2])
  end)

  it("disable removes folds and state", function()
    assert.is_true(skeleton.enable(tabpage, { mode = "focused" }))
    skeleton.disable(tabpage)
    assert.is_false(skeleton.is_active(tabpage))
    assert.equals(
      -1,
      vim.api.nvim_win_call(mod_win, function()
        return vim.fn.foldclosed(5)
      end)
    )
  end)

  it("cycle steps off → seams → focused → off", function()
    local session = session_mod.get_active_diffs()[tabpage]

    skeleton.cycle(tabpage)
    assert.is_true(skeleton.is_active(tabpage))
    assert.equals("seams", session.skeleton_want)

    skeleton.cycle(tabpage)
    assert.is_true(skeleton.is_active(tabpage))
    assert.equals("focused", session.skeleton_want)

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
    assert.is_true(skeleton.enable(tabpage, { mode = "focused" }))

    -- Simulate a file switch dropping the folds
    skeleton.reset(tabpage)
    assert.is_false(skeleton.is_active(tabpage))

    vim.api.nvim_exec_autocmds("User", { pattern = "CodeDiffRender", data = { tabpage = tabpage } })
    vim.wait(500, function()
      return skeleton.is_active(tabpage)
    end)

    assert.is_true(skeleton.is_active(tabpage))
    assert.equals(
      1,
      vim.api.nvim_win_call(mod_win, function()
        return vim.fn.foldclosed(5)
      end)
    )
  end)

  it("disable clears stickiness", function()
    assert.is_true(skeleton.enable(tabpage, { mode = "focused" }))
    skeleton.disable(tabpage)

    vim.api.nvim_exec_autocmds("User", { pattern = "CodeDiffRender", data = { tabpage = tabpage } })
    vim.wait(100)

    assert.is_false(skeleton.is_active(tabpage))
  end)

  it("hides inline implementation changes in the modified pane", function()
    -- Rebuild the session as inline: one window showing the modified buffer
    local session = session_mod.get_active_diffs()[tabpage]
    session.layout = "inline"
    session.original_win = mod_win
    session.modified_win = mod_win

    assert.is_true(skeleton.enable(tabpage, { mode = "focused" }))

    assert.equals(
      1,
      vim.api.nvim_win_call(mod_win, function()
        return vim.fn.foldclosed(5)
      end)
    )
    assert.equals(
      1,
      vim.api.nvim_win_call(mod_win, function()
        return vim.fn.foldclosed(10)
      end)
    )
    -- the original window was never touched
    assert.is_nil(session.skeleton.saved[orig_win])
  end)

  it("hunk navigation skips changes hidden inside folds", function()
    local navigation = require("codediff.ui.view.navigation")
    vim.api.nvim_set_current_win(mod_win)
    vim.api.nvim_win_set_cursor(mod_win, { 1, 0 })

    -- Focused mode hides beta's implementation hunk.
    assert.is_true(skeleton.enable(tabpage, { mode = "focused" }))
    assert.is_false(navigation.next_hunk())
    assert.equals(1, vim.api.nvim_win_get_cursor(mod_win)[1])

    -- Seams mode also folds beta's body.
    skeleton.reset(tabpage)
    assert.is_true(skeleton.enable(tabpage, { mode = "seams" }))
    vim.api.nvim_win_set_cursor(mod_win, { 1, 0 })
    assert.is_false(navigation.next_hunk())
    assert.equals(1, vim.api.nvim_win_get_cursor(mod_win)[1])
    assert.is_false(navigation.prev_hunk())
  end)

  it("moves off a hidden landing spot when a new file is selected", function()
    local session = session_mod.get_active_diffs()[tabpage]
    session.layout = "inline"
    session.original_win = mod_win
    session.modified_win = mod_win
    session.modified_path = "first.lua"
    -- Two hunks: one inside alpha's body (hidden in seams mode), one on the
    -- top-level return that stays visible
    session.stored_diff_result = {
      changes = {
        { original = { start_line = 5, end_line = 6 }, modified = { start_line = 5, end_line = 6 } },
        { original = { start_line = 13, end_line = 14 }, modified = { start_line = 13, end_line = 14 } },
      },
    }
    assert.is_true(skeleton.enable(tabpage, { mode = "seams", silent = true }))

    -- Simulate selecting another file that lands on its first (hidden) change
    skeleton.reset(tabpage)
    session.modified_path = "second.lua"
    vim.api.nvim_win_set_cursor(mod_win, { 5, 0 })
    assert.is_true(skeleton.enable(tabpage, { mode = "seams", silent = true }))

    -- Cursor advanced to the visible hunk instead of sitting inside the fold
    assert.equals(13, vim.api.nvim_win_get_cursor(mod_win)[1])
  end)

  it("leaves the cursor alone when the same file re-renders", function()
    local session = session_mod.get_active_diffs()[tabpage]
    session.layout = "inline"
    session.original_win = mod_win
    session.modified_win = mod_win
    session.modified_path = "same.lua"

    assert.is_true(skeleton.enable(tabpage, { mode = "seams", silent = true }))
    vim.api.nvim_win_set_cursor(mod_win, { 5, 0 })

    -- A live edit re-applies folds for the file already on screen
    skeleton.on_diff_refresh(tabpage)
    assert.equals(5, vim.api.nvim_win_get_cursor(mod_win)[1])
  end)

  it("hunk navigation reaches every hunk once the view is off", function()
    local navigation = require("codediff.ui.view.navigation")
    vim.api.nvim_set_current_win(mod_win)

    assert.is_true(skeleton.enable(tabpage, { mode = "seams" }))
    skeleton.disable(tabpage)

    vim.api.nvim_win_set_cursor(mod_win, { 1, 0 })
    assert.is_true(navigation.next_hunk())
    assert.equals(10, vim.api.nvim_win_get_cursor(mod_win)[1])
  end)

  it("inline focused mode hides implementation deletion anchors", function()
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

    assert.is_true(skeleton.enable(tabpage, { mode = "focused" }))

    assert.equals(
      1,
      vim.api.nvim_win_call(mod_win, function()
        return vim.fn.foldclosed(5)
      end)
    )
    assert.equals(
      1,
      vim.api.nvim_win_call(mod_win, function()
        return vim.fn.foldclosed(11)
      end)
    )
  end)
end)
