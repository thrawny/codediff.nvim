-- Skeleton view: fold unchanged function bodies so the diff reads as
-- signatures + changed code. Folds are computed on the modified side and
-- mirrored to the original side through unchanged region pairs, which keeps
-- the filler-line alignment between the two panes intact.
local M = {}

local lifecycle = require("codediff.ui.lifecycle")
local symbols_mod = require("codediff.core.symbols")

-- ============================================================================
-- Pure computation (unit-testable)
-- ============================================================================

---Derive aligned unchanged region pairs from diff changes.
---Regions have equal length on both sides by construction.
---@param changes table[] lines_diff.changes (ranges 1-based, end exclusive)
---@param orig_line_count number
---@param mod_line_count number
---@return { orig_start: number, mod_start: number, len: number }[]
function M.unchanged_regions(changes, orig_line_count, mod_line_count)
  local sorted = vim.deepcopy(changes or {})
  table.sort(sorted, function(a, b)
    return a.modified.start_line < b.modified.start_line
  end)

  local regions = {}
  local orig_next, mod_next = 1, 1

  local function emit(orig_stop, mod_stop)
    -- Unchanged gaps are common line runs, so both sides have the same
    -- length; min() guards against inconsistent input.
    local len = math.min(orig_stop - orig_next, mod_stop - mod_next)
    if len > 0 then
      table.insert(regions, { orig_start = orig_next, mod_start = mod_next, len = len })
    end
  end

  for _, mapping in ipairs(sorted) do
    emit(mapping.original.start_line, mapping.modified.start_line)
    orig_next = math.max(orig_next, mapping.original.end_line)
    mod_next = math.max(mod_next, mapping.modified.end_line)
  end
  emit(orig_line_count + 1, mod_line_count + 1)

  return regions
end

local function region_containing(regions, first, last)
  for _, region in ipairs(regions) do
    if region.mod_start <= first and last <= region.mod_start + region.len - 1 then
      return region
    end
  end
  return nil
end

---Compute symmetric fold ranges for both panes.
---A symbol body (everything below its first line) folds when it lies fully
---inside one unchanged region; otherwise its children are considered.
---@param symbols codediff.Symbol[] symbol tree of the modified buffer
---@param regions { orig_start: number, mod_start: number, len: number }[]
---@return { first: number, last: number }[] mod_folds
---@return { first: number, last: number }[] orig_folds
function M.compute_folds(symbols, regions)
  local mod_folds, orig_folds = {}, {}

  local function visit(list)
    for _, symbol in ipairs(list) do
      local first = symbol.fold_start
      local last = symbol.end_line
      local region = last > first and region_containing(regions, first, last) or nil
      if region then
        table.insert(mod_folds, { first = first, last = last })
        local offset = region.orig_start - region.mod_start
        table.insert(orig_folds, { first = first + offset, last = last + offset })
      else
        visit(symbol.children)
      end
    end
  end
  visit(symbols)

  return mod_folds, orig_folds
end

---Seam-only folds for the single inline pane: every callable body folds,
---changed or not, so only signatures and non-implementation changes remain.
---Container (class/impl) bodies stay open so member signatures show.
---@param symbols codediff.Symbol[]
---@return { first: number, last: number }[]
function M.compute_seam_folds_inline(symbols)
  local folds = {}
  local function visit(list)
    for _, symbol in ipairs(list) do
      if symbol.container then
        visit(symbol.children)
      elseif symbol.end_line > symbol.fold_start then
        table.insert(folds, { first = symbol.fold_start, last = symbol.end_line })
      end
    end
  end
  visit(symbols)
  return folds
end

local function index_callables_by_name(symbols)
  local by_name = {}
  local function visit(list, prefix)
    for _, symbol in ipairs(list) do
      local key = symbol.name and (prefix .. symbol.name) or nil
      if symbol.container then
        visit(symbol.children, key and (key .. ".") or prefix)
      elseif key and not by_name[key] then
        by_name[key] = symbol
      end
    end
  end
  visit(symbols, "")
  return by_name
end

---Seam-only folds for side-by-side: every callable body folds on both sides.
---Unchanged bodies mirror exactly through unchanged regions; changed bodies
---are paired across panes by qualified name (each side folds its own body
---range, and both collapse to one line so alignment is preserved).
---Added/deleted/renamed callables stay open — they are seams to look at.
---@param mod_symbols codediff.Symbol[]
---@param orig_symbols codediff.Symbol[]
---@param regions { orig_start: number, mod_start: number, len: number }[]
---@return { first: number, last: number }[] mod_folds
---@return { first: number, last: number }[] orig_folds
function M.compute_seam_folds(mod_symbols, orig_symbols, regions)
  local mod_folds, orig_folds = {}, {}
  local orig_by_name = index_callables_by_name(orig_symbols)

  local function visit(list, prefix)
    for _, symbol in ipairs(list) do
      local key = symbol.name and (prefix .. symbol.name) or nil
      if symbol.container then
        visit(symbol.children, key and (key .. ".") or prefix)
      else
        local first, last = symbol.fold_start, symbol.end_line
        if last > first then
          local region = region_containing(regions, first, last)
          if region then
            table.insert(mod_folds, { first = first, last = last })
            local offset = region.orig_start - region.mod_start
            table.insert(orig_folds, { first = first + offset, last = last + offset })
          else
            local pair = key and orig_by_name[key]
            if pair and pair.end_line > pair.fold_start then
              table.insert(mod_folds, { first = first, last = last })
              table.insert(orig_folds, { first = pair.fold_start, last = pair.end_line })
            end
          end
        end
      end
    end
  end
  visit(mod_symbols, "")

  return mod_folds, orig_folds
end

---Collect modified-buffer lines a fold may not swallow in inline layout:
---changed lines plus every deletion-overlay anchor line. Inline deletions are
---virt_lines extmarks anchored above a real line; virtual lines attached to
---folded lines are not rendered, so anchors must stay outside folds.
---@param changes table[] lines_diff.changes
---@param line_count number modified buffer line count
---@return table<number, boolean> blocked set of 1-based line numbers
function M.inline_blocked_lines(changes, line_count)
  local blocked = {}
  for _, mapping in ipairs(changes or {}) do
    for line = mapping.modified.start_line, mapping.modified.end_line - 1 do
      blocked[line] = true
    end
    if mapping.original.end_line > mapping.original.start_line then
      -- Deletion overlay anchor (see codediff.ui.inline render anchoring)
      blocked[math.max(1, math.min(mapping.modified.start_line, line_count))] = true
    end
  end
  return blocked
end

---Compute fold ranges for the single inline pane.
---A symbol body folds when it contains no blocked line; otherwise its
---children are considered.
---@param symbols codediff.Symbol[]
---@param blocked table<number, boolean>
---@return { first: number, last: number }[]
function M.compute_folds_inline(symbols, blocked)
  local folds = {}

  local function range_is_clear(first, last)
    for line = first, last do
      if blocked[line] then
        return false
      end
    end
    return true
  end

  local function visit(list)
    for _, symbol in ipairs(list) do
      local first = symbol.fold_start
      local last = symbol.end_line
      if last > first and range_is_clear(first, last) then
        table.insert(folds, { first = first, last = last })
      else
        visit(symbol.children)
      end
    end
  end
  visit(symbols)

  return folds
end

-- ============================================================================
-- Window fold application
-- ============================================================================

local SAVED_OPTS = { "foldmethod", "foldenable", "foldtext", "foldlevel", "foldminlines" }

function M.foldtext()
  local count = vim.v.foldend - vim.v.foldstart + 1
  return "⋯ " .. count .. " unchanged lines"
end

local function apply_folds(win, folds, saved)
  saved[win] = {}
  for _, opt in ipairs(SAVED_OPTS) do
    saved[win][opt] = vim.wo[win][opt]
  end

  vim.wo[win].foldmethod = "manual"
  vim.wo[win].foldenable = true
  vim.wo[win].foldminlines = 1
  vim.wo[win].foldlevel = 0
  vim.wo[win].foldtext = 'v:lua.require("codediff.ui.view.skeleton").foldtext()'

  vim.api.nvim_win_call(win, function()
    pcall(vim.cmd, "normal! zE")
    local line_count = vim.api.nvim_buf_line_count(0)
    for _, fold in ipairs(folds) do
      local first = math.max(1, fold.first)
      local last = math.min(line_count, fold.last)
      if last > first then
        vim.cmd(string.format("%d,%dfold", first, last))
      end
    end
  end)
end

local function restore_window(win, opts)
  if not vim.api.nvim_win_is_valid(win) then
    return
  end
  vim.wo[win].foldmethod = "manual"
  vim.api.nvim_win_call(win, function()
    pcall(vim.cmd, "normal! zE")
  end)
  for opt, value in pairs(opts) do
    vim.wo[win][opt] = value
  end
end

-- ============================================================================
-- Session toggle
-- ============================================================================

local augroup

local function ensure_autocmds()
  if augroup then
    return
  end
  augroup = vim.api.nvim_create_augroup("CodeDiffSkeleton", { clear = true })
  -- File switches and layout toggles replace buffers and recompute the diff;
  -- manual folds do not survive that. Once every render completes, re-apply
  -- the skeleton if the session still wants it.
  vim.api.nvim_create_autocmd("User", {
    group = augroup,
    pattern = "CodeDiffRender",
    callback = function(event)
      local tabpage = event.data and event.data.tabpage
      if not tabpage then
        return
      end
      local session = lifecycle.get_session(tabpage)
      if not session or not session.skeleton_want then
        return
      end
      vim.schedule(function()
        -- Re-check: the user may have toggled off before this ran
        local live = lifecycle.get_session(tabpage)
        if not live or not live.skeleton_want then
          return
        end
        M.reset(tabpage)
        M.enable(tabpage, { mode = live.skeleton_want, silent = true })
      end)
    end,
  })
end

---Drop the applied fold state and restore window options.
---Keeps session.skeleton_want so the view re-applies after the next render.
function M.reset(tabpage)
  local session = lifecycle.get_session(tabpage)
  if session and session.skeleton then
    for win, opts in pairs(session.skeleton.saved) do
      restore_window(win, opts)
    end
    session.skeleton = nil
  end
end

function M.is_active(tabpage)
  local session = lifecycle.get_session(tabpage)
  return session ~= nil and session.skeleton ~= nil
end

local function notify(silent, msg, level)
  if not silent then
    vim.notify(msg, level)
  end
end

---Why a buffer yielded no symbols: a missing parser is a different problem
---from a file that simply has no functions in it.
local function no_symbols_message(bufnr)
  if not symbols_mod.get_buf_lang(bufnr) then
    local ft = vim.b[bufnr].codediff_filetype or vim.bo[bufnr].filetype
    return string.format("Skeleton view: no treesitter parser for '%s'", ft ~= "" and ft or "unknown filetype")
  end
  return "Skeleton view: no functions found in this file"
end

local function enable_inline(session, diff_result, mode, silent)
  local win = session.modified_win
  local buf = session.modified_bufnr
  if not (win and vim.api.nvim_win_is_valid(win) and buf and vim.api.nvim_buf_is_valid(buf)) then
    notify(silent, "Skeleton view: no valid diff window", vim.log.levels.WARN)
    return false
  end

  local symbols = symbols_mod.get_symbols(buf)
  if #symbols == 0 then
    notify(silent, no_symbols_message(buf), vim.log.levels.WARN)
    return false
  end

  local folds
  if mode == "seams" then
    folds = M.compute_seam_folds_inline(symbols)
  else
    local blocked = M.inline_blocked_lines(diff_result.changes, vim.api.nvim_buf_line_count(buf))
    folds = M.compute_folds_inline(symbols, blocked)
  end
  if #folds == 0 then
    notify(silent, "Skeleton view: nothing to fold in this file", vim.log.levels.INFO)
  end

  local saved = {}
  apply_folds(win, folds, saved)
  session.skeleton = { saved = saved, mode = mode }
  return true
end

local function enable_side_by_side(session, diff_result, tabpage, mode, silent)
  local original_win, modified_win = lifecycle.get_windows(tabpage)
  local original_buf, modified_buf = lifecycle.get_buffers(tabpage)
  if not (original_win and modified_win and vim.api.nvim_win_is_valid(original_win) and vim.api.nvim_win_is_valid(modified_win)) or not (original_buf and modified_buf) then
    notify(silent, "Skeleton view needs both diff panes", vim.log.levels.WARN)
    return false
  end

  local symbols = symbols_mod.get_symbols(modified_buf)
  if #symbols == 0 then
    notify(silent, no_symbols_message(modified_buf), vim.log.levels.WARN)
    return false
  end

  local regions = M.unchanged_regions(diff_result.changes, vim.api.nvim_buf_line_count(original_buf), vim.api.nvim_buf_line_count(modified_buf))
  local mod_folds, orig_folds
  if mode == "seams" then
    mod_folds, orig_folds = M.compute_seam_folds(symbols, symbols_mod.get_symbols(original_buf), regions)
  else
    mod_folds, orig_folds = M.compute_folds(symbols, regions)
  end
  if #mod_folds == 0 then
    notify(silent, "Skeleton view: nothing to fold in this file", vim.log.levels.INFO)
  end

  local saved = {}
  apply_folds(modified_win, mod_folds, saved)
  apply_folds(original_win, orig_folds, saved)
  session.skeleton = { saved = saved, mode = mode }
  return true
end

---@param tabpage number
---@param opts? { mode?: "skeleton"|"seams", silent?: boolean } silent suppresses notifications (auto re-apply)
function M.enable(tabpage, opts)
  local silent = opts ~= nil and opts.silent == true
  local mode = (opts and opts.mode) or "skeleton"
  local session = lifecycle.get_session(tabpage)
  if not session then
    return false
  end

  local diff_result = session.stored_diff_result
  if not diff_result or not diff_result.changes then
    notify(silent, "No diff result available", vim.log.levels.WARN)
    return false
  end

  local ok
  if session.layout == "inline" then
    ok = enable_inline(session, diff_result, mode, silent)
  else
    ok = enable_side_by_side(session, diff_result, tabpage, mode, silent)
  end

  if ok then
    session.skeleton_want = mode
    ensure_autocmds()
  end
  return ok
end

---Called by auto_refresh after the diff is recomputed for edited buffers:
---the applied folds are stale, so rebuild them (or just drop them when the
---skeleton is not wanted).
function M.on_diff_refresh(tabpage)
  local session = lifecycle.get_session(tabpage)
  if not session then
    return
  end
  if session.skeleton then
    M.reset(tabpage)
  end
  if session.skeleton_want then
    M.enable(tabpage, { mode = session.skeleton_want, silent = true })
  end
end

function M.disable(tabpage)
  local session = lifecycle.get_session(tabpage)
  if session then
    session.skeleton_want = nil
  end
  if not session or not session.skeleton then
    return
  end
  for win, opts in pairs(session.skeleton.saved) do
    restore_window(win, opts)
  end
  session.skeleton = nil
end

---Cycle the view mode: off → skeleton (signatures + changes) → seams only → off.
function M.cycle(tabpage)
  tabpage = tabpage or vim.api.nvim_get_current_tabpage()
  local session = lifecycle.get_session(tabpage)
  if not session then
    return
  end

  local current = session.skeleton_want
  if current == nil then
    if M.enable(tabpage, { mode = "skeleton" }) then
      vim.notify("Skeleton view: signatures + changes", vim.log.levels.INFO)
    end
  elseif current == "skeleton" then
    M.reset(tabpage)
    if M.enable(tabpage, { mode = "seams" }) then
      vim.notify("Skeleton view: seam changes only", vim.log.levels.INFO)
    end
  else
    M.disable(tabpage)
    vim.notify("Skeleton view: off", vim.log.levels.INFO)
  end
end

-- Backward-compatible alias: the keymap cycles through all modes.
M.toggle = M.cycle

return M
