-- Structural diff views. Seams mode folds implementation bodies. Focused
-- mode also removes unchanged seams and implementation-only changes, leaving
-- changed signatures and data declarations.
local M = {}

local lifecycle = require("codediff.ui.lifecycle")
local symbols_mod = require("codediff.core.symbols")
local hunk_range = require("codediff.ui.hunk_range")
local config = require("codediff.config")

M.ns_spacer = vim.api.nvim_create_namespace("CodeDiffSkeletonSpacer")

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

local function mark_range(visible, first, last, line_count)
  first = math.max(1, first)
  last = math.min(line_count, last)
  for line = first, last do
    visible[line] = true
  end
end

local function range_intersects(first, last, range)
  return range.end_line > range.start_line and range.start_line <= last and range.end_line - 1 >= first
end

local function line_in_ranges(line, ranges)
  for _, range in ipairs(ranges) do
    if range.first <= line and line <= range.last then
      return true
    end
  end
  return false
end

local function mark_changed_signatures(visible, symbols, ranges, line_count)
  local function visit(list)
    for _, symbol in ipairs(list) do
      local signature_last = symbol.fold_start - 1
      for _, range in ipairs(ranges) do
        if range_intersects(symbol.start_line, signature_last, range) then
          mark_range(visible, symbol.start_line, signature_last, line_count)
          break
        end
      end
      visit(symbol.children)
    end
  end
  visit(symbols)
end

---Lines kept by focused mode on one side of the diff. Implementation and
---import changes stay hidden. Changed signatures remain visible in full, and
---a changed top-level data declaration remains visible as a complete block.
local function focused_visible_lines(changes, side, structure, line_count)
  local visible = {}
  local ranges = {}
  for _, mapping in ipairs(changes or {}) do
    table.insert(ranges, mapping[side])
  end

  local blocked = symbols_mod.impl_ranges(structure.symbols)
  vim.list_extend(blocked, structure.imports)
  for _, range in ipairs(ranges) do
    for line = range.start_line, range.end_line - 1 do
      if not line_in_ranges(line, blocked) then
        visible[line] = true
      end
    end
  end

  mark_changed_signatures(visible, structure.symbols, ranges, line_count)
  for _, data_range in ipairs(structure.data or {}) do
    for _, range in ipairs(ranges) do
      if range_intersects(data_range.first, data_range.last, range) then
        mark_range(visible, data_range.first, data_range.last, line_count)
        break
      end
    end
  end

  return visible
end

local function append_fold(folds, first, last)
  if first and last >= first then
    table.insert(folds, { first = first, last = last })
  end
end

local function folds_around_visible(visible, line_count)
  local folds = {}
  local hidden_start

  for line = 1, line_count do
    if visible[line] then
      append_fold(folds, hidden_start, line - 1)
      hidden_start = nil
    else
      hidden_start = hidden_start or line
    end
  end

  append_fold(folds, hidden_start, line_count)
  return folds
end

---Focused seam folds for side-by-side layout.
---@param changes table[] lines_diff.changes
---@param mod_structure codediff.Structure
---@param orig_structure codediff.Structure
---@param orig_line_count number
---@param mod_line_count number
---@return { first: number, last: number }[] mod_folds
---@return { first: number, last: number }[] orig_folds
function M.compute_focused_folds(changes, mod_structure, orig_structure, orig_line_count, mod_line_count)
  local mod_visible = focused_visible_lines(changes, "modified", mod_structure, mod_line_count)
  local orig_visible = focused_visible_lines(changes, "original", orig_structure, orig_line_count)
  return folds_around_visible(mod_visible, mod_line_count), folds_around_visible(orig_visible, orig_line_count)
end

---Focused seam folds for inline layout.
---@param changes table[] lines_diff.changes
---@param structure codediff.Structure
---@param line_count number
---@return { first: number, last: number }[] folds
function M.compute_focused_folds_inline(changes, structure, line_count)
  local visible = focused_visible_lines(changes, "modified", structure, line_count)
  return folds_around_visible(visible, line_count)
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

-- ============================================================================
-- Window fold application
-- ============================================================================

local SAVED_OPTS = { "foldmethod", "foldenable", "foldtext", "foldlevel", "foldminlines" }

function M.foldtext()
  local count = vim.v.foldend - vim.v.foldstart + 1
  local noun = count == 1 and "line" or "lines"
  return "⋯ " .. count .. " hidden " .. noun
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
      if last >= first then
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

local SPACER_TEXT = string.rep(" ", 500)
local SPACER_HL = "CodeDiffSkeletonSpacer"

local function setup_spacer_highlight()
  local normal = vim.api.nvim_get_hl(0, { name = "Normal", link = false })
  vim.api.nvim_set_hl(0, SPACER_HL, {
    fg = normal.fg,
    bg = normal.bg,
    nocombine = true,
  })
end

local function prepend_inline_spacer(bufnr, row)
  local inline = require("codediff.ui.inline")
  local marks = vim.api.nvim_buf_get_extmarks(bufnr, inline.ns_inline, { row, 0 }, { row, -1 }, { details = true })
  for _, mark in ipairs(marks) do
    local details = mark[4]
    if details.virt_lines and details.virt_lines_above then
      local original = vim.deepcopy(details.virt_lines)
      local padded = { { { SPACER_TEXT, SPACER_HL } } }
      vim.list_extend(padded, original)
      vim.api.nvim_buf_set_extmark(bufnr, inline.ns_inline, row, mark[3], {
        id = mark[1],
        virt_lines = padded,
        virt_lines_above = true,
        hl_mode = "replace",
        priority = details.priority or config.options.diff.highlight_priority,
      })
      return {
        bufnr = bufnr,
        ns_id = inline.ns_inline,
        id = mark[1],
        col = mark[3],
        virt_lines = original,
        priority = details.priority,
      }
    end
  end
  return nil
end

local function apply_spacers(bufnr, folds, inline_layout)
  vim.api.nvim_buf_clear_namespace(bufnr, M.ns_spacer, 0, -1)
  setup_spacer_highlight()
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  local inline_spacers = {}
  for _, fold in ipairs(folds) do
    -- Virtual lines anchored inside a closed fold are suppressed. Anchor each
    -- spacer to the adjacent visible line instead.
    if fold.first > 1 then
      vim.api.nvim_buf_set_extmark(bufnr, M.ns_spacer, fold.first - 2, 0, {
        virt_lines = { { { SPACER_TEXT, SPACER_HL } } },
        hl_mode = "replace",
        priority = config.options.diff.highlight_priority + 1,
      })
    end
    if fold.last < line_count then
      local injected = inline_layout and prepend_inline_spacer(bufnr, fold.last) or nil
      if injected then
        table.insert(inline_spacers, injected)
      else
        vim.api.nvim_buf_set_extmark(bufnr, M.ns_spacer, fold.last, 0, {
          virt_lines = { { { SPACER_TEXT, SPACER_HL } } },
          virt_lines_above = true,
          hl_mode = "replace",
          priority = config.options.diff.highlight_priority + 1,
        })
      end
    end
  end
  return inline_spacers
end

local function clear_spacers(state)
  for _, spacer in ipairs(state.inline_spacers or {}) do
    if vim.api.nvim_buf_is_valid(spacer.bufnr) then
      local position = vim.api.nvim_buf_get_extmark_by_id(spacer.bufnr, spacer.ns_id, spacer.id, {})
      if #position > 0 then
        vim.api.nvim_buf_set_extmark(spacer.bufnr, spacer.ns_id, position[1], spacer.col, {
          id = spacer.id,
          virt_lines = spacer.virt_lines,
          virt_lines_above = true,
          hl_mode = "replace",
          priority = spacer.priority or config.options.diff.highlight_priority,
        })
      end
    end
  end
  for _, bufnr in ipairs(state.spacer_bufs or {}) do
    if vim.api.nvim_buf_is_valid(bufnr) then
      vim.api.nvim_buf_clear_namespace(bufnr, M.ns_spacer, 0, -1)
    end
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
    clear_spacers(session.skeleton)
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

  local structure = symbols_mod.get_structure(buf)
  if not structure then
    notify(silent, no_symbols_message(buf), vim.log.levels.WARN)
    return false
  end
  local symbols = structure.symbols
  if mode == "seams" and #symbols == 0 then
    notify(silent, no_symbols_message(buf), vim.log.levels.WARN)
    return false
  end

  local folds
  if mode == "seams" then
    folds = M.compute_seam_folds_inline(symbols)
  else
    folds = M.compute_focused_folds_inline(diff_result.changes, structure, vim.api.nvim_buf_line_count(buf))
  end
  if #folds == 0 then
    notify(silent, "Skeleton view: nothing to fold in this file", vim.log.levels.INFO)
  end

  local saved = {}
  apply_folds(win, folds, saved)
  local spacer_bufs = {}
  local inline_spacers = {}
  if mode == "focused" then
    inline_spacers = apply_spacers(buf, folds, true)
    table.insert(spacer_bufs, buf)
  end
  session.skeleton = { saved = saved, mode = mode, spacer_bufs = spacer_bufs, inline_spacers = inline_spacers }
  return true
end

local function enable_side_by_side(session, diff_result, tabpage, mode, silent)
  local original_win, modified_win = lifecycle.get_windows(tabpage)
  local original_buf, modified_buf = lifecycle.get_buffers(tabpage)
  if not (original_win and modified_win and vim.api.nvim_win_is_valid(original_win) and vim.api.nvim_win_is_valid(modified_win)) or not (original_buf and modified_buf) then
    notify(silent, "Skeleton view needs both diff panes", vim.log.levels.WARN)
    return false
  end

  local mod_structure = symbols_mod.get_structure(modified_buf)
  local orig_structure = symbols_mod.get_structure(original_buf)
  if not mod_structure or not orig_structure then
    notify(silent, no_symbols_message(modified_buf), vim.log.levels.WARN)
    return false
  end
  local mod_symbols = mod_structure.symbols
  local orig_symbols = orig_structure.symbols
  if mode == "seams" and #mod_symbols == 0 then
    notify(silent, no_symbols_message(modified_buf), vim.log.levels.WARN)
    return false
  end

  local mod_folds, orig_folds
  if mode == "seams" then
    local regions = M.unchanged_regions(diff_result.changes, vim.api.nvim_buf_line_count(original_buf), vim.api.nvim_buf_line_count(modified_buf))
    mod_folds, orig_folds = M.compute_seam_folds(mod_symbols, orig_symbols, regions)
  else
    mod_folds, orig_folds =
      M.compute_focused_folds(diff_result.changes, mod_structure, orig_structure, vim.api.nvim_buf_line_count(original_buf), vim.api.nvim_buf_line_count(modified_buf))
  end
  if #mod_folds == 0 then
    notify(silent, "Skeleton view: nothing to fold in this file", vim.log.levels.INFO)
  end

  local saved = {}
  apply_folds(modified_win, mod_folds, saved)
  apply_folds(original_win, orig_folds, saved)
  local spacer_bufs = {}
  if mode == "focused" then
    apply_spacers(modified_buf, mod_folds, false)
    apply_spacers(original_buf, orig_folds, false)
    spacer_bufs = { modified_buf, original_buf }
  end
  session.skeleton = { saved = saved, mode = mode, spacer_bufs = spacer_bufs }
  return true
end

---Keep the cursor out of content this view hides after a file switch.
---Selecting a file jumps to its first change before these folds exist, so
---that landing spot can end up inside a folded body; move on to the first
---change that is actually visible. Only ever called for a newly selected
---file: on the file already on screen the cursor is the user's own, and a
---re-apply triggered by a live edit must not move it.
local function reveal_cursor(session)
  local win = session.modified_win
  if not (win and vim.api.nvim_win_is_valid(win)) then
    return
  end

  local function fold_at(line)
    return vim.api.nvim_win_call(win, function()
      return vim.fn.foldclosed(line)
    end)
  end

  local fold_start = fold_at(vim.api.nvim_win_get_cursor(win)[1])
  if fold_start == -1 then
    return
  end

  local changes = session.stored_diff_result and session.stored_diff_result.changes or {}
  local line_count = vim.api.nvim_buf_line_count(vim.api.nvim_win_get_buf(win))
  for _, mapping in ipairs(changes) do
    local target = hunk_range.target_line(mapping.modified, line_count)
    if fold_at(target) == -1 then
      pcall(vim.api.nvim_win_set_cursor, win, { target, 0 })
      return
    end
  end

  -- Nothing visible to land on: the fold's own first line is at least shown
  pcall(vim.api.nvim_win_set_cursor, win, { fold_start, 0 })
end

---@param tabpage number
---@param opts? { mode?: "seams"|"focused", silent?: boolean } silent suppresses notifications (auto re-apply)
function M.enable(tabpage, opts)
  local silent = opts ~= nil and opts.silent == true
  local mode = (opts and opts.mode) or "seams"
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
    -- Tracked across reset (unlike session.skeleton) so a re-apply can tell a
    -- file switch from a rebuild of the file already on screen.
    local previous_path = session.skeleton_path
    session.skeleton_path = session.modified_path
    session.skeleton_want = mode
    ensure_autocmds()
    if previous_path ~= nil and previous_path ~= session.modified_path then
      reveal_cursor(session)
    end
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
    session.skeleton_path = nil
  end
  if not session or not session.skeleton then
    return
  end
  for win, opts in pairs(session.skeleton.saved) do
    restore_window(win, opts)
  end
  clear_spacers(session.skeleton)
  session.skeleton = nil
end

---Cycle the view mode: off → seams only → focused seams → off.
function M.cycle(tabpage)
  tabpage = tabpage or vim.api.nvim_get_current_tabpage()
  local session = lifecycle.get_session(tabpage)
  if not session then
    return
  end

  local current = session.skeleton_want
  if current == nil then
    if M.enable(tabpage, { mode = "seams", silent = true }) then
      vim.notify("Skeleton view: seams only", vim.log.levels.INFO)
    elseif M.enable(tabpage, { mode = "focused" }) then
      vim.notify("Skeleton view: focused seams", vim.log.levels.INFO)
    end
  elseif current == "seams" then
    M.reset(tabpage)
    if M.enable(tabpage, { mode = "focused" }) then
      vim.notify("Skeleton view: focused seams", vim.log.levels.INFO)
    end
  else
    M.disable(tabpage)
    vim.notify("Skeleton view: off", vim.log.levels.INFO)
  end
end

-- Backward-compatible alias: the keymap cycles through all modes.
M.toggle = M.cycle

return M
