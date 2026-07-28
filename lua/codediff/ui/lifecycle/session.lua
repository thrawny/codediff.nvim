-- Session CRUD operations for diff views
-- Manages the active_diffs data structure
local M = {}

local config = require("codediff.config")
local virtual_file = require("codediff.core.virtual_file")
local accessors = require("codediff.ui.lifecycle.accessors")
local welcome_window = require("codediff.ui.view.welcome_window")
local hunk_range = require("codediff.ui.hunk_range")

local FILE_STATUS = {
  M = { symbol = "M", highlight = "CodeDiffStatusModified" },
  A = { symbol = "A", highlight = "CodeDiffStatusAdded" },
  D = { symbol = "D", highlight = "CodeDiffStatusDeleted" },
  R = { symbol = "R", highlight = "CodeDiffStatusRenamed" },
  ["??"] = { symbol = "??", highlight = "CodeDiffStatusUntracked" },
  ["!"] = { symbol = "!", highlight = "CodeDiffStatusConflict" },
}

-- Track active diff sessions
-- Structure: {
--   tabpage_id = {
--     original_bufnr, modified_bufnr, original_win, modified_win,
--     mode = "standalone" | "explorer",
--     git_root = string?,
--     original_path = string,
--     modified_path = string,
--     original_revision = string?, -- nil | "WORKING" | "STAGED" | commit_hash
--     modified_revision = string?,
--     original_state, modified_state,
--     suspended = bool,
--     stored_diff_result = table,
--     changedtick = { original = number, modified = number },
--     mtime = { original = number?, modified = number? },
--     -- Conflict mode result buffer (3-way merge)
--     result_bufnr = number?,  -- Real file buffer reset to BASE
--     result_win = number?,    -- Bottom window for result
--     conflict_files = table?, -- { [file_path] = true } tracks files opened in conflict mode
--   }
-- }
local active_diffs = {}

-- Get the active_diffs table (for other modules to access)
function M.get_active_diffs()
  return active_diffs
end

-- Check if a revision represents a virtual buffer
local function is_virtual_revision(revision)
  return revision ~= nil and revision ~= "WORKING"
end

local function build_winbar(sess, win)
  local winbar_config = config.options.diff.winbar or {}
  if not winbar_config.enabled then
    return ""
  end

  local parts = {}

  if winbar_config.show_file_index ~= false and sess.explorer and sess.explorer.tree then
    local ok, refresh = pcall(require, "codediff.ui.explorer.refresh")
    if ok then
      local all_files = refresh.get_all_files(sess.explorer.tree)
      local current = sess.explorer.current_file_path
      for i, file in ipairs(all_files) do
        if file.data and file.data.path == current then
          local file_part = string.format("󰈔 %d/%d  %s", i, #all_files, current)
          local status = winbar_config.show_file_status ~= false and FILE_STATUS[file.data.status] or nil
          if status then
            file_part = string.format("%%#%s#%s%%*  %s", status.highlight, status.symbol, file_part)
          end
          table.insert(parts, file_part)
          break
        end
      end
    end
  end

  if winbar_config.show_hunk_index ~= false then
    local diff_result = sess.stored_diff_result
    if diff_result and diff_result.changes and #diff_result.changes > 0 then
      local cursor = vim.api.nvim_win_get_cursor(win)[1]
      local line_count = vim.api.nvim_buf_line_count(vim.api.nvim_win_get_buf(win))
      local is_original = win == sess.original_win and win ~= sess.modified_win
      local current_hunk = 0
      for i, mapping in ipairs(diff_result.changes) do
        local side = is_original and mapping.original or mapping.modified
        if side and cursor >= hunk_range.target_line(side, line_count) then
          current_hunk = i
        end
      end
      if current_hunk > 0 then
        table.insert(parts, string.format(" %d/%d", current_hunk, #diff_result.changes))
      end
    end
  end

  if #parts == 0 then
    return ""
  end
  return "%=" .. table.concat(parts, "  ") .. "%="
end

-- Compute virtual URI from revision (not stored, computed on-demand)
local function compute_virtual_uri(git_root, revision, path)
  if not is_virtual_revision(revision) then
    return nil
  end
  return virtual_file.create_url(git_root, revision, path)
end

-- Expose compute_virtual_uri for other modules
M.compute_virtual_uri = compute_virtual_uri

function M.create_session(
  tabpage,
  mode,
  git_root,
  original_path,
  modified_path,
  original_revision,
  modified_revision,
  original_bufnr,
  modified_bufnr,
  original_win,
  modified_win,
  lines_diff,
  reapply_keymaps
)
  local state = require("codediff.ui.lifecycle.state")
  -- Save buffer states
  local original_state = state.save_buffer_state(original_bufnr)
  local modified_state = state.save_buffer_state(modified_bufnr)
  local window_winbars = {}
  if original_win and vim.api.nvim_win_is_valid(original_win) then
    window_winbars[original_win] = vim.wo[original_win].winbar
  end
  if modified_win and vim.api.nvim_win_is_valid(modified_win) and window_winbars[modified_win] == nil then
    window_winbars[modified_win] = vim.wo[modified_win].winbar
  end

  -- Create complete session in one step
  active_diffs[tabpage] = {
    -- Mode & Git Context (immutable)
    mode = mode,
    git_root = git_root,
    original_path = original_path,
    modified_path = modified_path,
    original_revision = original_revision,
    modified_revision = modified_revision,

    -- Buffers & Windows
    original_bufnr = original_bufnr,
    modified_bufnr = modified_bufnr,
    original_win = original_win,
    modified_win = modified_win,
    original_state = original_state,
    modified_state = modified_state,
    window_winbars = window_winbars,

    -- Lifecycle state
    layout = "side-by-side",
    suspended = false,
    stored_diff_result = lines_diff,
    render_seq = 0,
    rendered_seq = 0,
    render_pending = false,
    pending_navigation = nil,
    changedtick = {
      original = vim.api.nvim_buf_get_changedtick(original_bufnr),
      modified = vim.api.nvim_buf_get_changedtick(modified_bufnr),
    },
    mtime = {
      original = state.get_file_mtime(original_bufnr),
      modified = state.get_file_mtime(modified_bufnr),
    },

    -- Explorer reference (only for explorer mode)
    explorer = nil,

    -- Conflict mode result buffer (3-way merge)
    result_bufnr = nil,
    result_win = nil,
    conflict_files = {}, -- Tracks files opened in conflict mode for unsaved warning
    reapply_keymaps = reapply_keymaps,
  }

  welcome_window.capture_session_profiles(active_diffs[tabpage])

  -- Mark windows with restore flag
  vim.w[original_win].codediff_restore = 1
  vim.w[modified_win].codediff_restore = 1

  -- Continuously enforce inlay hint settings via LspAttach (handles LazyVim re-enabling)
  if config.options.diff.disable_inlay_hints and vim.lsp.inlay_hint then
    vim.lsp.inlay_hint.enable(false, { bufnr = original_bufnr })
    vim.lsp.inlay_hint.enable(false, { bufnr = modified_bufnr })
  end

  -- Setup tab autocmds
  local tab_augroup = vim.api.nvim_create_augroup("codediff_lifecycle_tab_" .. tabpage, { clear = true })

  -- Re-disable inlay hints when LSP attaches (LazyVim/distributions may re-enable them)
  if config.options.diff.disable_inlay_hints then
    vim.api.nvim_create_autocmd("LspAttach", {
      group = tab_augroup,
      callback = function(ev)
        if not active_diffs[tabpage] then
          return
        end
        vim.schedule(function()
          if vim.api.nvim_get_current_tabpage() == tabpage then
            pcall(vim.lsp.inlay_hint.enable, false, { bufnr = ev.buf })
          end
        end)
      end,
    })
  end

  -- Keep diff window UI stable. Conflict mode owns its own winbar titles.
  local function sync_window_ui(sess, win)
    if sess and sess.result_win and vim.api.nvim_win_is_valid(sess.result_win) then
      return
    end
    if sess and vim.api.nvim_win_is_valid(win) then
      vim.wo[win].winbar = build_winbar(sess, win)
    end
  end

  vim.api.nvim_create_autocmd({ "BufWinEnter", "BufEnter", "WinEnter", "FileType", "CursorMoved" }, {
    group = tab_augroup,
    callback = function()
      local sess = active_diffs[tabpage]
      if not sess then
        return
      end
      local win = vim.api.nvim_get_current_win()
      if win == sess.original_win or win == sess.modified_win then
        sync_window_ui(sess, win)
        welcome_window.sync(win)
      end
    end,
  })

  vim.api.nvim_create_autocmd("TabLeave", {
    group = tab_augroup,
    callback = function()
      local current_tab = vim.api.nvim_get_current_tabpage()
      if current_tab == tabpage then
        accessors.clear_tab_keymaps(tabpage)
        state.suspend_diff(tabpage)
      end
    end,
  })

  vim.api.nvim_create_autocmd("TabEnter", {
    group = tab_augroup,
    callback = function()
      vim.schedule(function()
        local current_tab = vim.api.nvim_get_current_tabpage()
        if current_tab == tabpage and active_diffs[tabpage] then
          local sess = active_diffs[tabpage]
          if sess.reapply_keymaps then
            pcall(sess.reapply_keymaps)
          end
          state.resume_diff(tabpage)
        end
      end)
    end,
  })
end

return M
