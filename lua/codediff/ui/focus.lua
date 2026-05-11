-- Tracks whether this Neovim instance is the focused application/window.
-- Used to keep background review tabs passive while repo activity happens elsewhere.
local M = {}

local focused = true
local setup_done = false

function M.setup()
  if setup_done then
    return
  end
  setup_done = true

  local group = vim.api.nvim_create_augroup("CodeDiffFocus", { clear = true })

  vim.api.nvim_create_autocmd("FocusGained", {
    group = group,
    callback = function()
      focused = true
    end,
  })

  vim.api.nvim_create_autocmd("FocusLost", {
    group = group,
    callback = function()
      focused = false
    end,
  })
end

function M.is_focused()
  M.setup()
  return focused
end

function M.is_tab_focused(tabpage)
  return M.is_focused() and vim.api.nvim_tabpage_is_valid(tabpage) and vim.api.nvim_get_current_tabpage() == tabpage
end

return M
