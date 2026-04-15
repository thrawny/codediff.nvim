-- Navigation module - provides public API for navigating hunks and files
local M = {}

local lifecycle = require("codediff.ui.lifecycle")
local config = require("codediff.config")

local function echo_hunk_message(chunks)
  if not config.options.diff.show_hunk_navigation_message then
    return
  end
  vim.api.nvim_echo(chunks, false, {})
end

-- Navigate to next hunk in the current diff view
-- Returns true if navigation succeeded, false otherwise
function M.next_hunk()
  local tabpage = vim.api.nvim_get_current_tabpage()
  local session = lifecycle.get_session(tabpage)
  if not session or not session.stored_diff_result then
    return false
  end

  local diff_result = session.stored_diff_result
  if not diff_result.changes or #diff_result.changes == 0 then
    return false
  end

  local current_buf = vim.api.nvim_get_current_buf()
  local original_bufnr = session.original_bufnr
  local modified_bufnr = session.modified_bufnr
  local is_inline = session.layout == "inline"

  local is_original = current_buf == original_bufnr
  local is_modified = current_buf == modified_bufnr
  local is_result = session.result_bufnr and current_buf == session.result_bufnr

  -- Inline mode: always use modified line numbers
  if is_inline then
    is_original = false
  -- If cursor is in result buffer (conflict mode), use modified side line numbers
  elseif is_result then
    is_original = false
  -- If cursor is not in any diff buffer, switch to modified window
  elseif not is_original and not is_modified then
    is_original = false
    local target_win = session.modified_win
    if target_win and vim.api.nvim_win_is_valid(target_win) then
      vim.api.nvim_set_current_win(target_win)
    else
      return false
    end
  end

  local cursor = vim.api.nvim_win_get_cursor(0)
  local current_line = cursor[1]

  -- Find next hunk after current line
  for i, mapping in ipairs(diff_result.changes) do
    local target_line = is_original and mapping.original.start_line or mapping.modified.start_line
    if target_line > current_line then
      pcall(vim.api.nvim_win_set_cursor, 0, { target_line, 0 })
      vim.cmd("normal! zz")
      echo_hunk_message({ { string.format("Hunk %d of %d", i, #diff_result.changes), "None" } })
      return true
    end
  end

  -- Wrap around to first hunk (if cycling enabled)
  if config.options.diff.cycle_next_hunk then
    local first_hunk = diff_result.changes[1]
    local target_line = is_original and first_hunk.original.start_line or first_hunk.modified.start_line
    pcall(vim.api.nvim_win_set_cursor, 0, { target_line, 0 })
    vim.cmd("normal! zz")
    echo_hunk_message({ { string.format("Hunk 1 of %d", #diff_result.changes), "None" } })
    return true
  else
    echo_hunk_message({ { string.format("Last hunk (%d of %d)", #diff_result.changes, #diff_result.changes), "WarningMsg" } })
    return false
  end
end

-- Navigate to previous hunk in the current diff view
-- Returns true if navigation succeeded, false otherwise
function M.prev_hunk()
  local tabpage = vim.api.nvim_get_current_tabpage()
  local session = lifecycle.get_session(tabpage)
  if not session or not session.stored_diff_result then
    return false
  end

  local diff_result = session.stored_diff_result
  if not diff_result.changes or #diff_result.changes == 0 then
    return false
  end

  local current_buf = vim.api.nvim_get_current_buf()
  local original_bufnr = session.original_bufnr
  local modified_bufnr = session.modified_bufnr
  local is_inline = session.layout == "inline"

  local is_original = current_buf == original_bufnr
  local is_modified = current_buf == modified_bufnr
  local is_result = session.result_bufnr and current_buf == session.result_bufnr

  -- Inline mode: always use modified line numbers
  if is_inline then
    is_original = false
  -- If cursor is in result buffer (conflict mode), use modified side line numbers
  elseif is_result then
    is_original = false
  -- If cursor is not in any diff buffer, switch to modified window
  elseif not is_original and not is_modified then
    is_original = false
    local target_win = session.modified_win
    if target_win and vim.api.nvim_win_is_valid(target_win) then
      vim.api.nvim_set_current_win(target_win)
    else
      return false
    end
  end

  local cursor = vim.api.nvim_win_get_cursor(0)
  local current_line = cursor[1]

  -- Find previous hunk before current line (search backwards)
  for i = #diff_result.changes, 1, -1 do
    local mapping = diff_result.changes[i]
    local target_line = is_original and mapping.original.start_line or mapping.modified.start_line
    if target_line < current_line then
      pcall(vim.api.nvim_win_set_cursor, 0, { target_line, 0 })
      vim.cmd("normal! zz")
      echo_hunk_message({ { string.format("Hunk %d of %d", i, #diff_result.changes), "None" } })
      return true
    end
  end

  -- Wrap around to last hunk (if cycling enabled)
  if config.options.diff.cycle_next_hunk then
    local last_hunk = diff_result.changes[#diff_result.changes]
    local target_line = is_original and last_hunk.original.start_line or last_hunk.modified.start_line
    pcall(vim.api.nvim_win_set_cursor, 0, { target_line, 0 })
    vim.cmd("normal! zz")
    echo_hunk_message({ { string.format("Hunk %d of %d", #diff_result.changes, #diff_result.changes), "None" } })
    return true
  else
    echo_hunk_message({ { string.format("First hunk (1 of %d)", #diff_result.changes), "WarningMsg" } })
    return false
  end
end

local function navigate_file(direction, tabpage)
  local session = lifecycle.get_session(tabpage)
  local panel_obj = lifecycle.get_explorer(tabpage)

  if not panel_obj then
    return false
  end

  local is_history_mode = session and session.mode == "history"

  if is_history_mode then
    local history = require("codediff.ui.history")
    if direction == "next" then
      if panel_obj.is_single_file_mode then
        history.navigate_next_commit(panel_obj)
      else
        history.navigate_next(panel_obj)
      end
    else
      if panel_obj.is_single_file_mode then
        history.navigate_prev_commit(panel_obj)
      else
        history.navigate_prev(panel_obj)
      end
    end
  else
    local explorer = require("codediff.ui.explorer")
    if direction == "next" then
      explorer.navigate_next(panel_obj)
    else
      explorer.navigate_prev(panel_obj)
    end
  end

  return true
end

local function session_matches_selected_file(tabpage)
  local session = lifecycle.get_session(tabpage)
  local explorer = lifecycle.get_explorer(tabpage)
  if not session or not explorer or not explorer.current_file_path then
    return true
  end

  local rel = explorer.current_file_path
  local abs = session.git_root and (session.git_root .. "/" .. rel) or nil
  for _, path in ipairs({ session.modified_path, session.original_path }) do
    if path == rel or (abs and path == abs) then
      return true
    end
  end
  return false
end

local function navigate_hunk_or_file(direction, tabpage, queue_if_pending)
  queue_if_pending = queue_if_pending ~= false

  local session = lifecycle.get_session(tabpage)
  if not session then
    return false
  end

  if lifecycle.is_render_pending(tabpage) and (not session_matches_selected_file(tabpage) or not session.stored_diff_result) then
    if queue_if_pending then
      lifecycle.queue_pending_navigation(
        tabpage,
        direction == "next" and "next_hunk_or_file" or "prev_hunk_or_file",
        session.render_seq
      )
    end
    return false
  end

  if vim.api.nvim_get_current_tabpage() ~= tabpage then
    return false
  end

  local old = config.options.diff.cycle_next_hunk
  config.options.diff.cycle_next_hunk = false
  local ok, result = pcall(direction == "next" and M.next_hunk or M.prev_hunk)
  config.options.diff.cycle_next_hunk = old
  if not ok then
    error(result)
  end

  if result then
    return true
  end

  return navigate_file(direction, tabpage)
end

function M.next_hunk_or_file()
  return navigate_hunk_or_file("next", vim.api.nvim_get_current_tabpage())
end

function M.prev_hunk_or_file()
  return navigate_hunk_or_file("prev", vim.api.nvim_get_current_tabpage())
end

function M.flush_pending_navigation(tabpage, pending)
  if not pending then
    return false
  end

  if pending.kind == "next_hunk_or_file" then
    return navigate_hunk_or_file("next", tabpage, false)
  end
  if pending.kind == "prev_hunk_or_file" then
    return navigate_hunk_or_file("prev", tabpage, false)
  end

  return false
end

-- Navigate to next file in explorer/history mode
-- In single-file history mode, navigates to next commit instead
-- Returns true if navigation succeeded, false otherwise
function M.next_file()
  return navigate_file("next", vim.api.nvim_get_current_tabpage())
end

-- Navigate to previous file in explorer/history mode
-- In single-file history mode, navigates to previous commit instead
-- Returns true if navigation succeeded, false otherwise
function M.prev_file()
  return navigate_file("prev", vim.api.nvim_get_current_tabpage())
end

return M
