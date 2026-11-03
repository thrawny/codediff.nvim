-- The API view: what a module exports, without any bodies, in a read-only
-- buffer. <CR> on a line opens its source, and gd opens the API view of the
-- definition's module. Each language has an extractor in codediff.api.<lang>.
--
-- Browse mode (:Api toggle) makes the API view the normal way to read code: a
-- source file opened in a window shows its module's API view instead.
local M = {}

local languages = {
  go = require("codediff.api.go"),
}

local enabled = false
-- Whether API views show comments and unexported declarations. One setting
-- each for every view. nil until toggled, which means the configured default.
local comments = nil
local private = nil
-- Windows whose next source file stays the real file, because <CR> asked for it.
local skip_next = {}
-- Per API buffer: { language = ..., targets = { [line] = { file, line } } }.
local views = {}
-- Per view name, such as a Go package directory: its API buffer.
local buffers = {}

-- The language with an API extractor for a filetype, or nil.
function M.language_for_filetype(filetype)
  return languages[filetype or ""]
end

local function language_of(path)
  return languages[vim.filetype.match({ filename = path }) or ""]
end

-- The API buffer for path's module, built fresh from the files on disk. Returns
-- nil if path's language has no extractor, or its module exports nothing.
local function build(path)
  local language = language_of(path)
  if not language then
    return nil
  end
  local files, name = language.files(path)
  if not files or #files == 0 then
    return nil
  end
  local sources = {}
  for _, file in ipairs(files) do
    sources[#sources + 1] = { path = file, text = table.concat(vim.fn.readfile(file), "\n") }
  end
  local lines, targets = language.extract(sources, { comments = M.comments_shown(), private = M.private_shown() })
  if not lines then
    return nil
  end

  local buf = buffers[name]
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    buf = vim.api.nvim_create_buf(true, false)
    buffers[name] = buf
    vim.api.nvim_buf_set_name(buf, "codediff-api://" .. name)
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].bufhidden = "hide"
    vim.bo[buf].swapfile = false
    M.attach_keymaps(buf)
  end
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].modified = false
  if vim.bo[buf].filetype ~= language.filetype then
    vim.bo[buf].filetype = language.filetype
  end
  views[buf] = { language = language, targets = targets }
  return buf
end

-- The API line for a source position: an exact match, else the nearest
-- declaration above it in the same file.
local function line_for(buf, file, line)
  local best, best_line
  for api_line, target in pairs(views[buf].targets) do
    if target.file == file and target.line <= line and (not best_line or target.line > best_line) then
      best, best_line = api_line, target.line
    end
  end
  return best, best_line == line
end

local function first_line_of(buf, file)
  local first
  for api_line, target in pairs(views[buf].targets) do
    if target.file == file and (not first or api_line < first) then
      first = api_line
    end
  end
  return first or 1
end

-- Show the API view of file's package in win, with the cursor at file:line.
local function show(win, file, line)
  local buf = build(file)
  if not buf then
    return false
  end
  vim.api.nvim_win_call(win, function()
    vim.cmd("normal! m'")
    vim.cmd("buffer " .. buf)
  end)
  local api_line = line and line_for(buf, file, line) or first_line_of(buf, file)
  vim.api.nvim_win_set_cursor(win, { api_line or first_line_of(buf, file), 0 })
  return true
end

local function open_source(win, file, line)
  skip_next[win] = true
  vim.api.nvim_win_call(win, function()
    vim.cmd("normal! m'")
    vim.cmd("edit " .. vim.fn.fnameescape(file))
  end)
  skip_next[win] = nil
  vim.api.nvim_win_set_cursor(win, { line, 0 })
  vim.api.nvim_win_call(win, function()
    vim.cmd("normal! zz")
  end)
end

local function cursor_target()
  local view = views[vim.api.nvim_get_current_buf()]
  return view and view.targets[vim.api.nvim_win_get_cursor(0)[1]]
end

-- The word under the cursor, found on its source line. The API line can differ
-- from the source line in spacing only, so the nth occurrence of the word on one
-- is the nth on the other. Returns the source line text and a 0-based byte
-- column, or nil.
local function source_position(target, word)
  local pattern = "%f[%w_]" .. vim.pesc(word) .. "%f[^%w_]"
  local api_text = vim.api.nvim_get_current_line()
  local cursor_col = vim.api.nvim_win_get_cursor(0)[2] + 1
  local nth, from = 0, 1
  while true do
    local start, finish = api_text:find(pattern, from)
    if not start or start > cursor_col then
      break
    end
    nth, from = nth + 1, finish + 1
  end

  local text = vim.fn.readfile(target.file)[target.line] or ""
  local col
  from = 1
  for _ = 1, math.max(nth, 1) do
    local start, finish = text:find(pattern, from)
    if not start then
      break
    end
    col, from = start, finish + 1
  end
  return col and text, col and col - 1
end

local function first_location(result)
  if not result or vim.tbl_isempty(result) then
    return nil
  end
  local loc = vim.islist(result) and result[1] or result
  local uri = loc.uri or loc.targetUri
  local range = loc.targetSelectionRange or loc.range
  return vim.uri_to_fname(uri), range.start.line + 1
end

-- gd: ask the language server for the definition of the word under the cursor at its source
-- position. An exported definition opens in its package's API view, anything
-- else in its source file.
local function goto_definition()
  local target = cursor_target()
  local word = vim.fn.expand("<cword>")
  if not target or word == "" then
    return
  end
  local text, col = source_position(target, word)
  local client = vim.lsp.get_clients({ name = views[vim.api.nvim_get_current_buf()].language.lsp })[1]
  if not text or not client then
    if text then
      open_source(0, target.file, target.line)
      vim.api.nvim_win_set_cursor(0, { target.line, col })
      vim.lsp.buf.definition()
    end
    return
  end

  local win = vim.api.nvim_get_current_win()
  local params = {
    textDocument = { uri = vim.uri_from_fname(target.file) },
    position = { line = target.line - 1, character = vim.str_utfindex(text, "utf-16", col) },
  }
  client:request("textDocument/definition", params, function(err, result)
    local file, line = first_location(result)
    if err or not file then
      vim.notify("No definition found for " .. word, vim.log.levels.WARN)
      return
    end
    local buf = build(file)
    local api_line, exact
    if buf then
      api_line, exact = line_for(buf, file, line)
    end
    if exact then
      vim.api.nvim_win_call(win, function()
        vim.cmd("normal! m'")
        vim.cmd("buffer " .. buf)
      end)
      vim.api.nvim_win_set_cursor(win, { api_line, 0 })
      return
    end
    open_source(win, file, line)
  end)
end

function M.attach_keymaps(buf)
  vim.keymap.set("n", "<CR>", function()
    local target = cursor_target()
    if target then
      open_source(vim.api.nvim_get_current_win(), target.file, target.line)
    end
  end, { buffer = buf, desc = "Open source" })
  vim.keymap.set("n", "gd", goto_definition, { buffer = buf, desc = "Go to definition in API view" })
  vim.keymap.set("n", "C", M.toggle_comments, { buffer = buf, desc = "Toggle comments in API views" })
  vim.keymap.set("n", "P", M.toggle_private, { buffer = buf, desc = "Toggle unexported declarations in API views" })
end

-- Windows where browse mode leaves Go files alone: floats such as picker
-- previews, diff windows, and CodeDiff tabs.
local function excluded(win)
  if vim.api.nvim_win_get_config(win).relative ~= "" or vim.wo[win].diff then
    return true
  end
  local ok, lifecycle = pcall(require, "codediff.ui.lifecycle")
  return ok and lifecycle.get_session(vim.api.nvim_win_get_tabpage(win)) ~= nil
end

local function redirect(win, buf)
  if not enabled or skip_next[win] or not vim.api.nvim_win_is_valid(win) then
    return
  end
  if vim.api.nvim_win_get_buf(win) ~= buf or vim.bo[buf].buftype ~= "" or excluded(win) then
    return
  end
  show(win, vim.api.nvim_buf_get_name(buf), vim.api.nvim_win_get_cursor(win)[1])
end

local function create_autocmds()
  local group = vim.api.nvim_create_augroup("CodeDiffApiBrowse", { clear = true })
  vim.api.nvim_create_autocmd("BufWinEnter", {
    group = group,
    callback = function(args)
      local win = vim.api.nvim_get_current_win()
      if not enabled or skip_next[win] or not language_of(args.file) then
        return
      end
      vim.schedule(function()
        redirect(win, args.buf)
      end)
    end,
    desc = "Show the API view for source files in browse mode",
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = group,
    callback = function(args)
      views[args.buf] = nil
    end,
  })
end

local function git(git_root, args, stdin)
  local result = vim.system(vim.list_extend({ "git", "-C", git_root }, args), { stdin = stdin }):wait()
  return result.code == 0 and result.stdout or nil
end

-- The sources of the module that holds rel_path, at a revision, as extract
-- takes them: { { path, text }, ... }, with absolute paths. revision is a
-- commit, ":0" or "STAGED" for the index, or nil or "WORKING" for the files on
-- disk. Returns nil if the language has no extractor, and an empty list if
-- the module has no files at that revision.
function M.module_sources(git_root, revision, rel_path, language)
  local rel_dir = vim.fn.fnamemodify(rel_path, ":h")
  local prefix = rel_dir == "." and "" or rel_dir .. "/"
  local sources = {}

  if revision == nil or revision == "WORKING" then
    for _, file in ipairs(vim.fn.glob(git_root .. "/" .. prefix .. "*", false, true)) do
      if language.in_package(file) and vim.fn.filereadable(file) == 1 then
        sources[#sources + 1] = { path = file, text = table.concat(vim.fn.readfile(file), "\n") }
      end
    end
    return sources
  end

  -- List the directory's blobs at the revision, then read them all in one
  -- git cat-file call.
  local listing
  if revision == ":0" or revision == "STAGED" then
    listing = git(git_root, { "ls-files", "-s", "--", prefix })
  else
    listing = git(git_root, { "ls-tree", revision, "--", prefix })
  end
  local blobs = {}
  for line in (listing or ""):gmatch("[^\n]+") do
    -- ls-files: "<mode> <sha> <stage>\t<path>", ls-tree: "<mode> blob <sha>\t<path>"
    local meta, path = line:match("^(.-)\t(.+)$")
    local sha = meta and meta:match("(%x%x%x%x%x%x%x+)")
    if sha and path:find("/", #prefix + 1, true) == nil and language.in_package(path) then
      blobs[#blobs + 1] = { sha = sha, path = path }
    end
  end
  if #blobs == 0 then
    return sources
  end

  local stdin = table.concat(
    vim.tbl_map(function(blob)
      return blob.sha
    end, blobs),
    "\n"
  ) .. "\n"
  local out = git(git_root, { "cat-file", "--batch" }, stdin) or ""
  local pos = 1
  for _, blob in ipairs(blobs) do
    local header_end = out:find("\n", pos, true)
    if not header_end then
      break
    end
    local size = tonumber(out:sub(pos, header_end - 1):match(" (%d+)$"))
    if not size then
      break
    end
    sources[#sources + 1] = { path = git_root .. "/" .. blob.path, text = out:sub(header_end + 1, header_end + size) }
    pos = header_end + size + 2
  end
  return sources
end

local function configured(name)
  local options = require("codediff.config").options.api or {}
  return options[name] == true
end

function M.comments_shown()
  if comments == nil then
    return configured("comments")
  end
  return comments
end

function M.private_shown()
  if private == nil then
    return configured("private")
  end
  return private
end

-- Rebuild every shown API view after a setting changed, with the cursor on the
-- same declaration, and the API state of every diff view.
local function rebuild_all()
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local buf = vim.api.nvim_win_get_buf(win)
    local view = views[buf]
    if view then
      local target = vim.api.nvim_win_call(win, cursor_target)
      local rebuilt = target and build(target.file)
      if rebuilt then
        -- A hidden comment's line has no match, so take the declaration below it.
        local best, best_line
        for api_line, t in pairs(views[rebuilt].targets) do
          if t.file == target.file and t.line >= target.line and (not best_line or t.line < best_line) then
            best, best_line = api_line, t.line
          end
        end
        vim.api.nvim_win_set_cursor(win, { best or line_for(rebuilt, target.file, target.line) or 1, 0 })
      end
    end
  end

  local skeleton = require("codediff.ui.view.skeleton")
  local lifecycle = require("codediff.ui.lifecycle")
  for _, tabpage in ipairs(vim.api.nvim_list_tabpages()) do
    local session = lifecycle.get_session(tabpage)
    if session and session.skeleton_want == "api" then
      skeleton.on_diff_refresh(tabpage)
    end
  end
end

-- Show or hide comments in every API view.
function M.toggle_comments()
  local shown = not M.comments_shown()
  -- Matching the configured default again means following the config.
  comments = shown
  if shown == configured("comments") then
    comments = nil
  end
  rebuild_all()
  vim.notify("API view comments " .. (shown and "shown" or "hidden"))
end

-- Show or hide unexported declarations in every API view.
function M.toggle_private()
  local shown = not M.private_shown()
  private = shown
  if shown == configured("private") then
    private = nil
  end
  rebuild_all()
  vim.notify("API view unexported declarations " .. (shown and "shown" or "hidden"))
end

function M.is_enabled()
  return enabled
end

function M.toggle()
  enabled = not enabled
  if enabled then
    create_autocmds()
  end
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local buf = vim.api.nvim_win_get_buf(win)
    if enabled then
      redirect(win, buf)
    elseif views[buf] then
      local target = vim.api.nvim_win_call(win, cursor_target)
      if target then
        open_source(win, target.file, target.line)
      end
    end
  end
  vim.notify("API browse mode " .. (enabled and "enabled" or "disabled"))
end

-- Open the API view of a file's module, or of a directory's first supported
-- file, in a vertical split. Defaults to the current file.
function M.open(path)
  path = vim.fn.fnamemodify(path and path ~= "" and path or vim.fn.expand("%"), ":p")
  if vim.fn.isdirectory(path) == 1 then
    for _, file in ipairs(vim.fn.glob(path .. "/*", false, true)) do
      if language_of(file) and build(file) then
        path = file
        break
      end
    end
  end
  local buf = build(path)
  if not buf then
    vim.notify("No exported API for " .. path, vim.log.levels.WARN)
    return
  end
  vim.cmd("vsplit")
  vim.cmd("buffer " .. buf)
end

return M
