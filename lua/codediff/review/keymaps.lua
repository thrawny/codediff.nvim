local M = {}

local config = require("codediff.review.config")

local keymapped_buffers = {}

local function is_enabled(key)
  return key ~= nil and key ~= false and key ~= ""
end

local function del_keymap(bufnr, mode, lhs)
  if lhs and vim.api.nvim_buf_is_valid(bufnr) then
    pcall(vim.keymap.del, mode, lhs, { buffer = bufnr })
  end
end

local function clear_buffer_keymaps(bufnr)
  local tracked = keymapped_buffers[bufnr]
  if tracked then
    for _, entry in ipairs(tracked) do
      del_keymap(bufnr, entry[1], entry[2])
    end
  end
end

local function get_explorer_owned_keymaps(bufnr)
  local lifecycle = require("codediff.ui.lifecycle")
  local session = lifecycle.get_session(vim.api.nvim_get_current_tabpage())
  if not session or not session.explorer or session.explorer.bufnr ~= bufnr then
    return {}
  end

  local owned = {}
  local explorer_keymaps = require("codediff.config").options.keymaps.explorer or {}
  local function add(key)
    if type(key) == "table" then
      for _, nested in ipairs(key) do
        add(nested)
      end
    elseif is_enabled(key) then
      owned[key] = true
    end
  end
  for _, key in pairs(explorer_keymaps) do
    add(key)
  end
  return owned
end

local function format_key(key)
  local inner = key:match("^<(.+)>$")
  if not inner then
    return key
  end
  if inner:lower() == "leader" or inner:lower() == "localleader" then
    return key
  end
  inner = inner:gsub("^C%-", "Ctrl-")
  return inner
end

local function add_section(entries, title, lines, max_key_width)
  if #entries == 0 then
    return
  end
  table.insert(lines, "")
  table.insert(lines, "  " .. title)
  for _, entry in ipairs(entries) do
    local padding = string.rep(" ", max_key_width - #entry.key + 3)
    table.insert(lines, "   " .. entry.key .. padding .. entry.desc)
  end
end

local help_popup = nil

local function close_help()
  if help_popup then
    help_popup:unmount()
    help_popup = nil
  end
end

local function show_help()
  if help_popup then
    close_help()
    return
  end

  local cfg = config.get()
  local km = cfg.keymaps
  local nav_entries, action_entries = {}, {}

  local function entry(key_name, desc, tbl)
    local key = km[key_name]
    if not is_enabled(key) then
      return
    end
    table.insert(tbl, { key = format_key(key), desc = desc })
  end

  entry("next_file", "Next file", nav_entries)
  entry("prev_file", "Previous file", nav_entries)
  entry("toggle_file_panel", "Toggle file panel", nav_entries)

  entry("toggle_readonly", "Toggle readonly/edit", action_entries)
  entry("close", "Close review", action_entries)
  entry("show_help", "This help", action_entries)
  table.insert(action_entries, { key = "t", desc = "Toggle layout" })
  table.insert(action_entries, { key = "g?", desc = "Codediff help" })

  local all_entries = {}
  vim.list_extend(all_entries, nav_entries)
  vim.list_extend(all_entries, action_entries)
  local max_key_width = 0
  for _, e in ipairs(all_entries) do
    max_key_width = math.max(max_key_width, #e.key)
  end

  local lines = {}
  add_section(nav_entries, "Navigation", lines, max_key_width)
  add_section(action_entries, "Actions", lines, max_key_width)
  table.insert(lines, "")

  local max_line_width = 0
  for _, line in ipairs(lines) do
    max_line_width = math.max(max_line_width, #line)
  end
  local width = math.max(max_line_width + 2, 30)
  local height = #lines

  local Popup = require("nui.popup")
  help_popup = Popup({
    position = "50%",
    size = { width = width, height = height },
    border = { style = "rounded", text = { top = " Review Keymaps ", top_align = "center" } },
    buf_options = { modifiable = false, buftype = "nofile" },
  })
  help_popup:mount()

  local buf = help_popup.bufnr
  vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
  vim.api.nvim_set_current_win(help_popup.winid)

  local map_opts = { noremap = true, nowait = true }
  help_popup:map("n", "?", close_help, map_opts)
  help_popup:map("n", "q", close_help, map_opts)
  help_popup:map("n", "<Esc>", close_help, map_opts)
end

local function set_buffer_keymaps(bufnr)
  clear_buffer_keymaps(bufnr)

  local cfg = config.get()
  local km = cfg.keymaps
  local mapped = {}
  local explorer_owned_keymaps = get_explorer_owned_keymaps(bufnr)

  local function set(lhs, rhs, desc)
    if is_enabled(lhs) and not explorer_owned_keymaps[lhs] then
      vim.keymap.set("n", lhs, rhs, { buffer = bufnr, noremap = true, silent = true, nowait = true, desc = desc })
      table.insert(mapped, { "n", lhs })
    end
  end

  local function jump_to_first_hunk()
    local ok, lifecycle = pcall(require, "codediff.ui.lifecycle")
    if not ok then
      return
    end
    local tabpage = vim.api.nvim_get_current_tabpage()
    local session = lifecycle.get_session(tabpage)
    if not session or not session.stored_diff_result then
      return
    end
    local diff_result = session.stored_diff_result
    if #diff_result.changes == 0 then
      return
    end

    local orig_buf, mod_buf = lifecycle.get_buffers(tabpage)
    local current_buf = vim.api.nvim_get_current_buf()
    local is_original = current_buf == orig_buf
    local first_hunk = diff_result.changes[1]
    local target_line = is_original and first_hunk.original.start_line or first_hunk.modified.start_line
    pcall(vim.api.nvim_win_set_cursor, 0, { target_line, 0 })
  end

  local function navigate(direction)
    return function()
      local ok, lifecycle = pcall(require, "codediff.ui.lifecycle")
      if not ok then
        return
      end
      local tabpage = vim.api.nvim_get_current_tabpage()
      local explorer_obj = lifecycle.get_explorer(tabpage)
      if explorer_obj then
        require("codediff.ui.explorer")["navigate_" .. direction](explorer_obj)
        vim.defer_fn(jump_to_first_hunk, 100)
      end
    end
  end

  set(km.next_file, navigate("next"), "Next file")
  set(km.prev_file, navigate("prev"), "Previous file")
  set(km.toggle_file_panel, function()
    local ok, lifecycle = pcall(require, "codediff.ui.lifecycle")
    if not ok then
      return
    end
    local tabpage = vim.api.nvim_get_current_tabpage()
    local explorer_obj = lifecycle.get_explorer(tabpage)
    if explorer_obj then
      require("codediff.ui.explorer").toggle_visibility(explorer_obj)
    end
  end, "Toggle file panel")
  set(km.close, function()
    require("codediff.review").close()
  end, "Close")
  set(km.toggle_readonly, function()
    require("codediff.review").toggle_readonly()
  end, "Toggle readonly mode")
  set(km.show_help, show_help, "Show help")

  require("codediff.review.lsp_proxy").apply_to_buffer(vim.api.nvim_get_current_tabpage(), bufnr, mapped)

  keymapped_buffers[bufnr] = mapped
end

local augroup = nil

function M.setup_keymaps(tabpage)
  local ok, lifecycle = pcall(require, "codediff.ui.lifecycle")
  if not ok then
    vim.notify("codediff.ui.lifecycle not available", vim.log.levels.WARN, { title = "codediff.review" })
    return
  end

  if augroup then
    vim.api.nvim_del_augroup_by_id(augroup)
  end
  augroup = vim.api.nvim_create_augroup("codediff_review_keymaps", { clear = true })

  for bufnr in pairs(keymapped_buffers) do
    clear_buffer_keymaps(bufnr)
  end
  keymapped_buffers = {}

  set_buffer_keymaps(vim.api.nvim_get_current_buf())

  vim.api.nvim_create_autocmd("BufEnter", {
    group = augroup,
    callback = function()
      if vim.api.nvim_get_current_tabpage() ~= tabpage then
        return
      end
      if not lifecycle.get_session(tabpage) then
        return
      end
      set_buffer_keymaps(vim.api.nvim_get_current_buf())
    end,
  })
end

function M.clear_keymaps()
  for bufnr in pairs(keymapped_buffers) do
    clear_buffer_keymaps(bufnr)
  end
  keymapped_buffers = {}
end

function M.cleanup()
  if augroup then
    vim.api.nvim_del_augroup_by_id(augroup)
    augroup = nil
  end
  close_help()
  M.clear_keymaps()
end

M._test = {
  format_key = format_key,
  add_section = add_section,
  is_enabled = is_enabled,
}

return M
