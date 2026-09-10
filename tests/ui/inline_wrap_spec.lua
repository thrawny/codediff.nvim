local inline = require("codediff.ui.inline")
local highlights = require("codediff.ui.highlights")

describe("Inline deleted-line wrapping", function()
  local buf, win
  local source = "- **Edge controller**: " .. string.rep("Linux MIPS routers; ", 8) .. "README.md"
  local change = { changes = { { original = { start_line = 1, end_line = 2 }, modified = { start_line = 1, end_line = 2 } } } }

  local function rows()
    for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, inline.ns_inline, 0, -1, { details = true })) do
      if mark[4].virt_lines then
        return mark[4].virt_lines
      end
    end
    return {}
  end

  local function content(lines)
    local parts = {}
    for _, row in ipairs(lines) do
      -- The last chunk is background padding.
      for i = 1, #row - 1 do
        table.insert(parts, row[i][1])
      end
    end
    return table.concat(parts)
  end

  local function refresh(event, pattern)
    vim.api.nvim_exec_autocmds(event, { pattern = pattern })
    vim.wait(30, function()
      return false
    end)
  end

  before_each(function()
    highlights.setup()
    buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "replacement" })
    win = vim.api.nvim_open_win(buf, true, { relative = "editor", row = 0, col = 0, width = 40, height = 10, style = "minimal" })
    vim.wo[win].wrap = true
  end)

  after_each(function()
    inline.clear(buf)
    vim.api.nvim_win_close(win, true)
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("keeps all deleted Markdown text visible in a narrow window", function()
    inline.render_inline_diff(buf, change, { source }, { "replacement" }, { filetype = "markdown" })
    assert.is_true(#rows() > 1)
    assert.equals(source, content(rows()))
    for _, row in ipairs(rows()) do
      local text = ""
      for _, chunk in ipairs(row) do
        text = text .. chunk[1]
      end
      assert.equals(40, vim.fn.strdisplaywidth(text))
    end
  end)

  it("reflows on resize and when wrapping is toggled", function()
    inline.render_inline_diff(buf, change, { source }, { "replacement" })
    local narrow_count = #rows()
    vim.api.nvim_win_set_width(win, 65)
    refresh("WinResized")
    assert.is_true(#rows() < narrow_count)
    assert.equals(source, content(rows()))
    vim.wo[win].wrap = false
    refresh("OptionSet", "wrap")
    assert.equals(1, #rows())
    assert.equals(source, rows()[1][1][1])
    vim.wo[win].wrap = true
    refresh("OptionSet", "wrap")
    assert.is_true(#rows() > 1)
    assert.equals(source, content(rows()))
  end)

  it("preserves Unicode and character highlights across rows", function()
    local original = string.rep("界é", 25)
    local mapping = vim.deepcopy(change)
    mapping.changes[1].inner_changes = {
      { original = { start_line = 1, end_line = 1, start_col = 1, end_col = 51 }, modified = { start_line = 1, end_line = 1, start_col = 1, end_col = 1 } },
    }
    inline.render_inline_diff(buf, mapping, { original }, { "replacement" })
    assert.equals(original, content(rows()))
    assert.is_true(#rows() > 1)
    for _, row in ipairs(rows()) do
      assert.equals("CodeDiffCharDelete", row[1][2])
    end
  end)

  it("accounts for the gutter and expands tabs without losing trailing text", function()
    vim.wo[win].number = true
    vim.wo[win].numberwidth = 4
    vim.bo[buf].tabstop = 8
    local original = string.rep("x", 35) .. "\tTAIL"
    inline.render_inline_diff(buf, change, { original }, { "replacement" })
    assert.equals(string.rep("x", 35) .. string.rep(" ", 5) .. "TAIL", content(rows()))
    local width = vim.api.nvim_win_get_width(win) - vim.fn.getwininfo(win)[1].textoff
    for _, row in ipairs(rows()) do
      local text = ""
      for _, chunk in ipairs(row) do
        text = text .. chunk[1]
      end
      assert.equals(width, vim.fn.strdisplaywidth(text))
    end
  end)

  it("does not wrap background padding and does not restore cleared marks", function()
    inline.render_inline_diff(buf, change, { "" }, { "replacement" })
    assert.equals(1, #rows())
    inline.clear(buf)
    refresh("WinResized")
    assert.equals(0, #rows())
  end)
end)
