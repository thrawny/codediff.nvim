-- Virtual lines ignore 'wrap'; split deleted text into screen-width rows ourselves.
local M = {}
local buffers = {}

local function text_width(bufnr)
  local width
  for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
    if vim.wo[win].wrap then
      local info = vim.fn.getwininfo(win)[1]
      local available = math.max(1, vim.api.nvim_win_get_width(win) - info.textoff)
      -- Extmarks are buffer-local. Use the narrowest wrapping window so no
      -- deleted text is hidden when the buffer is displayed more than once.
      width = math.min(width or available, available)
    end
  end
  return width
end

local function wrap_lines(lines, width, bufnr)
  if not width then
    return lines
  end
  local result = {}
  for _, chunks in ipairs(lines) do
    local row, column, source_column = {}, 0, 0
    local base_hl = chunks[#chunks][2]
    local function finish()
      table.insert(row, { string.rep(" ", width - column), base_hl })
      table.insert(result, row)
      row, column = {}, 0
    end
    -- The final chunk is background padding, not source text.
    for i = 1, #chunks - 1 do
      local text, hl = unpack(chunks[i])
      for _, char in ipairs(vim.fn.split(text, "\\zs")) do
        local cells
        if char == "\t" then
          cells = vim.bo[bufnr].tabstop - source_column % vim.bo[bufnr].tabstop
          char = string.rep(" ", cells)
        else
          cells = vim.fn.strdisplaywidth(char)
        end
        source_column = source_column + cells
        if column + cells > width and column > 0 and char:sub(1, 1) ~= " " then
          finish()
        end
        -- Tabs may be wider than a very narrow window.
        if char:match("^ +$") then
          for _ = 1, cells do
            if column == width then
              finish()
            end
            table.insert(row, { " ", hl })
            column = column + 1
          end
        else
          local previous = row[#row]
          if previous and previous[2] == hl then
            previous[1] = previous[1] .. char
          else
            table.insert(row, { char, hl })
          end
          column = math.min(width, column + cells)
        end
      end
    end
    finish()
  end
  return result
end

function M.clear(bufnr)
  buffers[bufnr] = nil
end

function M.add(bufnr, ns, line, opts)
  local state = buffers[bufnr]
  if not state then
    state = { ns = ns, marks = {}, width = text_width(bufnr), tabstop = vim.bo[bufnr].tabstop }
    buffers[bufnr] = state
  end
  local source = opts.virt_lines
  opts.virt_lines = wrap_lines(source, state.width, bufnr)
  local id = vim.api.nvim_buf_set_extmark(bufnr, ns, line, 0, opts)
  table.insert(state.marks, { id = id, lines = source, opts = opts })
end

local function refresh()
  for bufnr, state in pairs(buffers) do
    if not vim.api.nvim_buf_is_valid(bufnr) then
      buffers[bufnr] = nil
    else
      local width = text_width(bufnr)
      if width == state.width and vim.bo[bufnr].tabstop == state.tabstop then
        goto continue
      end
      for _, mark in ipairs(state.marks) do
        local pos = vim.api.nvim_buf_get_extmark_by_id(bufnr, state.ns, mark.id, {})
        if #pos > 0 then
          mark.opts.id = mark.id
          mark.opts.virt_lines = wrap_lines(mark.lines, width, bufnr)
          vim.api.nvim_buf_set_extmark(bufnr, state.ns, pos[1], pos[2], mark.opts)
        end
      end
      state.width = width
      state.tabstop = vim.bo[bufnr].tabstop
    end
    ::continue::
  end
end

local group = vim.api.nvim_create_augroup("CodeDiffInlineWrap", { clear = true })
local pending = false
local function schedule_refresh()
  if pending then
    return
  end
  pending = true
  vim.schedule(function()
    pending = false
    refresh()
  end)
end
vim.api.nvim_create_autocmd({ "WinResized", "BufWinEnter", "WinClosed" }, { group = group, callback = schedule_refresh })
vim.api.nvim_create_autocmd("OptionSet", {
  group = group,
  pattern = { "wrap", "number", "relativenumber", "numberwidth", "signcolumn", "foldcolumn", "statuscolumn", "tabstop" },
  callback = schedule_refresh,
})
vim.api.nvim_create_autocmd("BufWipeout", {
  group = group,
  callback = function(args)
    M.clear(args.buf)
  end,
})

return M
