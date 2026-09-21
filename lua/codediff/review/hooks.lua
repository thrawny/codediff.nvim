local M = {}

local config = require("codediff.review.config")

---@type number|nil
local current_tabpage = nil
---@type table<number, { modifiable: boolean, readonly: boolean }>
local review_buffer_options = {}
---@type table<number, number>
local review_window_buffers = {}

local wrap_options = { "wrap", "linebreak", "breakindent", "showbreak", "breakindentopt" }

local function save_review_buffer_options(bufnr)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) or review_buffer_options[bufnr] then
    return
  end

  review_buffer_options[bufnr] = {
    modifiable = vim.api.nvim_get_option_value("modifiable", { buf = bufnr }),
    readonly = vim.api.nvim_get_option_value("readonly", { buf = bufnr }),
  }
end

local function restore_review_buffer_options(bufnr)
  local saved = review_buffer_options[bufnr]
  if not saved then
    return
  end

  review_buffer_options[bufnr] = nil
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  pcall(vim.api.nvim_set_option_value, "modifiable", saved.modifiable, { buf = bufnr })
  pcall(vim.api.nvim_set_option_value, "readonly", saved.readonly, { buf = bufnr })
end

local function restore_all_review_buffer_options()
  local bufs = {}
  for bufnr in pairs(review_buffer_options) do
    table.insert(bufs, bufnr)
  end
  for _, bufnr in ipairs(bufs) do
    restore_review_buffer_options(bufnr)
  end
end

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

  if vim.api.nvim_get_option_value("filetype", { buf = bufnr }) ~= ft then
    vim.api.nvim_set_option_value("filetype", ft, { buf = bufnr })
  end
end

local function inherit_filetype_wrap_options(bufnr, win)
  if not bufnr or not win or not vim.api.nvim_buf_is_valid(bufnr) or not vim.api.nvim_win_is_valid(win) then
    return
  end

  local ft = vim.b[bufnr].codediff_filetype or vim.api.nvim_get_option_value("filetype", { buf = bufnr })
  if not ft or ft == "" then
    return
  end

  -- diff.wrap is an explicit opt-in, so a filetype default must not turn it off.
  local wrap_forced = require("codediff.config").options.diff.wrap

  for _, option in ipairs(wrap_options) do
    if not (wrap_forced and option == "wrap") then
      local ok, value = pcall(vim.filetype.get_option, ft, option)
      if ok and value ~= nil then
        pcall(vim.api.nvim_set_option_value, option, value, { win = win })
      end
    end
  end
end

local function inherit_session_wrap_options(sess)
  local seen = {}
  for _, win in ipairs({ sess.original_win, sess.modified_win }) do
    if win and not seen[win] and vim.api.nvim_win_is_valid(win) then
      seen[win] = true
      local bufnr = vim.api.nvim_win_get_buf(win)
      if review_window_buffers[win] ~= bufnr then
        review_window_buffers[win] = bufnr
        inherit_filetype_wrap_options(bufnr, win)
      end
    end
  end
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

  local sess = lifecycle.get_session(tabpage)
  if sess then
    inherit_session_wrap_options(sess)
  end

  local cfg = config.get()
  if cfg.codediff.readonly then
    if orig_buf and vim.api.nvim_buf_is_valid(orig_buf) then
      save_review_buffer_options(orig_buf)
      vim.api.nvim_set_option_value("modifiable", false, { buf = orig_buf })
      vim.api.nvim_set_option_value("readonly", true, { buf = orig_buf })
    end
    if mod_buf and vim.api.nvim_buf_is_valid(mod_buf) then
      save_review_buffer_options(mod_buf)
      vim.api.nvim_set_option_value("modifiable", false, { buf = mod_buf })
      vim.api.nvim_set_option_value("readonly", true, { buf = mod_buf })
    end
  end

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
  restore_all_review_buffer_options()
  review_window_buffers = {}
  current_tabpage = nil
  require("codediff.review.keymaps").cleanup()
end

return M
