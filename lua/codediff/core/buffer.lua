-- Load files into buffers without letting other plugins' autocmds abort a render
local M = {}

--- Add a buffer for name and load it.
--- An error raised by a BufRead autocmd is ignored once the buffer is loaded.
--- Neovim's own diagnostic handlers raise one when diagnostics stored for an
--- unloaded buffer point past the end of the file read from disk.
---@param name string File path or URL
---@return integer bufnr
function M.load(name)
  local bufnr = vim.fn.bufadd(name)
  local ok, err = pcall(vim.fn.bufload, bufnr)
  if not ok and not vim.api.nvim_buf_is_loaded(bufnr) then
    error(err, 0)
  end
  return bufnr
end

return M
