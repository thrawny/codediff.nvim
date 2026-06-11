local M = {}

local marks = require("codediff.review.marks")
local config = require("codediff.review.config")
local normalize_path = require("codediff.review.utils").normalize_path

---@type number|nil
local current_tabpage = nil
---@type number|nil
local buf_augroup = nil

local function set_buffer_filetype(bufnr, path)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) or not path or path == "" then
    return
  end

  local ft = vim.filetype.match({ filename = path, buf = bufnr })
  if not ft then
    return
  end

  local bufname = vim.api.nvim_buf_get_name(bufnr)
  local buftype = vim.api.nvim_get_option_value("buftype", { buf = bufnr })
  if buftype ~= "" or bufname == "" or bufname:match("^codediff://") then
    -- Do not set 'filetype' for synthetic review buffers. Setting it fires
    -- FileType autocmds, which makes LSP plugins attach to buffers that are
    -- not real files. Keep the detected type for CodeDiff rendering without
    -- triggering LSP.
    vim.b[bufnr].codediff_filetype = ft
    local lang = vim.treesitter.language.get_lang(ft) or ft
    if not pcall(vim.treesitter.start, bufnr, lang) then
      vim.api.nvim_set_option_value("syntax", ft, { buf = bufnr })
    end
    return
  end

  vim.api.nvim_set_option_value("filetype", ft, { buf = bufnr })
end

---@return number|nil
function M.get_current_tabpage()
  return current_tabpage
end

local function get_lifecycle()
  local ok, lifecycle = pcall(require, "codediff.ui.lifecycle")
  if not ok then
    return nil
  end
  return lifecycle
end

function M.get_session()
  if not current_tabpage then
    return nil
  end
  local lifecycle = get_lifecycle()
  if not lifecycle then
    return nil
  end
  return lifecycle.get_session(current_tabpage)
end

local function relativize_path(path, lifecycle, tabpage)
  if not path then
    return nil
  end
  local git_ctx = lifecycle.get_git_context(tabpage)
  if git_ctx and git_ctx.git_root then
    local abs = vim.fn.fnamemodify(path, ":p")
    return normalize_path(abs:gsub("^" .. vim.pesc(git_ctx.git_root) .. "/", ""))
  end
  return normalize_path(vim.fn.fnamemodify(path, ":."))
end

---@return string|nil, number|nil, "old"|"new"|nil
function M.get_cursor_position()
  local lifecycle = get_lifecycle()
  if not lifecycle or not current_tabpage then
    return nil, nil, nil
  end

  local sess = lifecycle.get_session(current_tabpage)
  if not sess then
    return nil, nil, nil
  end

  local cursor = vim.api.nvim_win_get_cursor(0)
  local current_buf = vim.api.nvim_get_current_buf()
  local orig_path, mod_path = lifecycle.get_paths(current_tabpage)
  local orig_buf, mod_buf = lifecycle.get_buffers(current_tabpage)

  local file_path
  local side
  if current_buf == orig_buf then
    file_path = orig_path
    side = "old"
  elseif current_buf == mod_buf then
    file_path = mod_path
    side = "new"
  else
    local bufname = vim.api.nvim_buf_get_name(current_buf)
    if bufname and bufname ~= "" then
      if bufname:match("^codediff://") then
        file_path = mod_path or orig_path
      else
        file_path = vim.fn.fnamemodify(bufname, ":.")
      end
    end
  end

  if not file_path then
    return nil, nil, nil
  end

  return relativize_path(file_path, lifecycle, current_tabpage), cursor[1], side
end

---@return string|nil, number|nil, number|nil, "old"|"new"|nil
function M.get_visual_range()
  local start_line = vim.fn.line("'<")
  local end_line = vim.fn.line("'>")
  if start_line > end_line then
    start_line, end_line = end_line, start_line
  end

  local file, _, side = M.get_cursor_position()
  if not file then
    return nil, nil, nil, nil
  end

  return file, start_line, end_line, side
end

function M.get_buffers()
  local lifecycle = get_lifecycle()
  if not lifecycle or not current_tabpage then
    return nil, nil
  end
  return lifecycle.get_buffers(current_tabpage)
end

function M.get_paths()
  local lifecycle = get_lifecycle()
  if not lifecycle or not current_tabpage then
    return nil, nil
  end
  local orig_path, mod_path = lifecycle.get_paths(current_tabpage)
  return relativize_path(orig_path, lifecycle, current_tabpage), relativize_path(mod_path, lifecycle, current_tabpage)
end

function M.on_session_created(tabpage)
  current_tabpage = tabpage

  local lifecycle = get_lifecycle()
  if not lifecycle then
    return
  end

  local orig_buf, mod_buf = lifecycle.get_buffers(tabpage)
  local raw_orig_path, raw_mod_path = lifecycle.get_paths(tabpage)
  set_buffer_filetype(orig_buf, raw_orig_path)
  set_buffer_filetype(mod_buf, raw_mod_path)

  local cfg = config.get()
  if cfg.codediff.readonly then
    if orig_buf and vim.api.nvim_buf_is_valid(orig_buf) then
      vim.api.nvim_set_option_value("modifiable", false, { buf = orig_buf })
      vim.api.nvim_set_option_value("readonly", true, { buf = orig_buf })
    end
    if mod_buf and vim.api.nvim_buf_is_valid(mod_buf) then
      vim.api.nvim_set_option_value("modifiable", false, { buf = mod_buf })
      vim.api.nvim_set_option_value("readonly", true, { buf = mod_buf })
    end
  end

  if buf_augroup then
    pcall(vim.api.nvim_del_augroup_by_id, buf_augroup)
  end
  buf_augroup = vim.api.nvim_create_augroup("codediff_review_buf_marks", { clear = true })

  vim.api.nvim_create_autocmd("BufEnter", {
    group = buf_augroup,
    callback = function()
      if vim.api.nvim_get_current_tabpage() ~= current_tabpage then
        return
      end
      local bufnr = vim.api.nvim_get_current_buf()
      local ob, mb = lifecycle.get_buffers(current_tabpage)
      if bufnr ~= ob and bufnr ~= mb then
        return
      end
      marks.refresh()
    end,
  })

  vim.defer_fn(function()
    marks.refresh()
  end, 100)

  vim.defer_fn(function()
    M._focus_modified_pane(lifecycle, tabpage)
  end, 150)
end

function M._focus_modified_pane(lifecycle, tabpage)
  local cfg = config.get()
  if cfg.codediff.focus_modified_pane == false then
    return
  end

  local current_win = vim.api.nvim_get_current_win()
  local cur_cfg = vim.api.nvim_win_get_config(current_win)
  if cur_cfg.relative ~= "" then
    return
  end

  local sess = lifecycle.get_session(tabpage)
  if not sess or not sess.modified_win or not vim.api.nvim_win_is_valid(sess.modified_win) then
    return
  end

  local explorer = lifecycle.get_explorer and lifecycle.get_explorer(tabpage) or nil
  if explorer and explorer.winid and vim.api.nvim_win_is_valid(explorer.winid) and current_win == explorer.winid then
    return
  end

  vim.api.nvim_set_current_win(sess.modified_win)
end

function M.on_session_closed()
  current_tabpage = nil
  if buf_augroup then
    pcall(vim.api.nvim_del_augroup_by_id, buf_augroup)
    buf_augroup = nil
  end
  require("codediff.review.keymaps").cleanup()
end

function M.on_file_changed(tabpage)
  current_tabpage = tabpage
  local lifecycle = get_lifecycle()
  if not lifecycle then
    return
  end
  vim.defer_fn(function()
    marks.refresh()
  end, 50)
end

return M
