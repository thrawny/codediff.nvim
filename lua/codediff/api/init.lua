-- The API view: what a module exports, without any bodies, in a read-only
-- buffer. <CR> on a line opens its source, and gd opens the API view of the
-- definition's module. Each language has an extractor in codediff.api.<lang>.
--
-- Browse mode (:Api toggle) makes the API view the normal way to read code: a
-- source file opened in a window shows its module's API view instead.
local M = {}

local languages = {
  go = require("codediff.api.go"),
  python = require("codediff.api.python"),
  typescript = require("codediff.api.typescript"),
  typescriptreact = require("codediff.api.typescript"),
}

local enabled = false
-- Whether API views show comments and unexported declarations. One setting
-- each for every view. nil until toggled, which means the configured default.
local comments = nil
local private = nil
-- Windows whose next source file stays the real file, because <CR> asked for it.
local skip_next = {}
-- Per API buffer: { language = ..., path = the file it was built for,
-- targets = { [line] = { file, line } } }.
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
  views[buf] = { language = language, path = path, targets = targets }
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

-- The language server to ask for definitions: the language's named one, or
-- else any running client for one of its filetypes that answers definition
-- requests.
local function client_for(language)
  local filetypes = language.filetypes or { language.filetype }
  local function handled(filetype)
    return vim.tbl_contains(filetypes, filetype)
  end
  for _, client in ipairs(vim.lsp.get_clients(language.lsp and { name = language.lsp } or nil)) do
    local handles = language.lsp ~= nil or vim.iter(client.config.filetypes or {}):any(handled)
    for buf in pairs(client.attached_buffers or {}) do
      handles = handles or (vim.api.nvim_buf_is_valid(buf) and handled(vim.bo[buf].filetype))
    end
    if handles and client:supports_method("textDocument/definition") then
      return client
    end
  end
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
  local client = client_for(views[vim.api.nvim_get_current_buf()].language)
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

-- Windows where browse mode leaves source files alone: floats such as picker
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

-- Results of slow work on sources, by a hash of the work and the sources, so
-- an explorer refresh over unchanged files does not parse them again.
local results = {}
local result_count = 0
local MAX_RESULTS = 4000

-- The files read_directories found in a directory at a commit, by commit and
-- directory.
local commit_files = {}
local commit_count = 0

local function cached(kind, language, sources, compute)
  local parts = { kind, language.filetype }
  for _, source in ipairs(sources) do
    parts[#parts + 1] = source.path
    parts[#parts + 1] = source.text
  end
  local key = vim.fn.sha256(table.concat(parts, "\0"))
  local hit = results[key]
  if hit == nil then
    if result_count >= MAX_RESULTS then
      results, result_count = {}, 0
    end
    -- false stands for a nil result.
    hit = compute()
    if hit == nil then
      hit = false
    end
    results[key] = hit
    result_count = result_count + 1
  end
  return hit or nil
end

-- The files directly in each of rel_dirs at a revision that keep(path) is
-- true for, as { [rel_dir] = { { path, text }, ... } } with absolute paths.
-- rel_dirs are relative to git_root, with "." for the root. A revision reads
-- every directory with one listing and one git cat-file call.
local function read_directories(git_root, revision, rel_dirs, keep)
  local found = {}
  for _, rel_dir in ipairs(rel_dirs) do
    found[rel_dir] = {}
  end
  local function prefix_of(rel_dir)
    return rel_dir == "." and "" or rel_dir .. "/"
  end

  if revision == nil or revision == "WORKING" then
    for _, rel_dir in ipairs(rel_dirs) do
      for _, file in ipairs(vim.fn.glob(git_root .. "/" .. prefix_of(rel_dir) .. "*", false, true)) do
        if keep(file) and vim.fn.filereadable(file) == 1 then
          table.insert(found[rel_dir], { path = file, text = table.concat(vim.fn.readfile(file), "\n") })
        end
      end
    end
    return found
  end

  -- A commit never changes, so its directories are read once.
  local commit = revision ~= ":0" and revision ~= "STAGED" and revision:match("^%x+$") and #revision == 40
  local to_read = rel_dirs
  if commit then
    to_read = {}
    for _, rel_dir in ipairs(rel_dirs) do
      local hit = commit_files[revision .. "\0" .. rel_dir]
      if hit then
        found[rel_dir] = vim.tbl_filter(function(file)
          return keep(file.path)
        end, hit)
      else
        to_read[#to_read + 1] = rel_dir
      end
    end
    if #to_read == 0 then
      return found
    end
  end

  local args
  if revision == ":0" or revision == "STAGED" then
    args = { "ls-files", "-s", "--" }
  else
    args = { "ls-tree", revision, "--" }
  end
  for _, rel_dir in ipairs(to_read) do
    -- git rejects an empty pathspec, so the root is ".".
    args[#args + 1] = rel_dir == "." and "." or prefix_of(rel_dir)
  end
  local blobs = {}
  for line in (git(git_root, args) or ""):gmatch("[^\n]+") do
    -- ls-files: "<mode> <sha> <stage>\t<path>", ls-tree: "<mode> blob <sha>\t<path>"
    local meta, path = line:match("^(.-)\t(.+)$")
    local sha = meta and not meta:find(" tree ", 1, true) and meta:match("(%x%x%x%x%x%x%x+)")
    -- ls-files lists subdirectories' files too, so take each file's own directory.
    local rel_dir = path and vim.fn.fnamemodify(path, ":h")
    if sha and found[rel_dir] and keep(path) then
      blobs[#blobs + 1] = { sha = sha, path = path, rel_dir = rel_dir }
    end
  end
  if #blobs == 0 then
    return found
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
    table.insert(found[blob.rel_dir], { path = git_root .. "/" .. blob.path, text = out:sub(header_end + 1, header_end + size) })
    pos = header_end + size + 2
  end
  if commit then
    if commit_count + #to_read > MAX_RESULTS then
      commit_files, commit_count = {}, 0
    end
    for _, rel_dir in ipairs(to_read) do
      commit_files[revision .. "\0" .. rel_dir] = found[rel_dir]
      commit_count = commit_count + 1
    end
  end
  return found
end

-- The sources of the module that holds rel_path, at a revision, as extract
-- takes them: { { path, text }, ... }, with absolute paths. revision is a
-- commit, ":0" or "STAGED" for the index, or nil or "WORKING" for the files on
-- disk. Returns an empty list if the module has no files at that revision. A
-- language whose module can be less than its directory, such as one Python
-- file, picks the module's sources out of the directory's with select.
-- directories, if given, holds the files read_directories found, by revision
-- then directory, and is read from instead of git where it has the directory.
-- It also keeps each directory's sources and covered set for the next call.
function M.module_sources(git_root, revision, rel_path, language, directories)
  local rel_dir = vim.fn.fnamemodify(rel_path, ":h")
  local key = table.concat({ language.filetype, revision or "WORKING", rel_dir }, "\0")
  local memo = directories and directories[key]
  if not memo then
    local files = directories and directories[revision or "WORKING"] and directories[revision or "WORKING"][rel_dir]
    if not files then
      files = read_directories(git_root, revision, { rel_dir }, language.in_package)[rel_dir]
    end
    local sources = vim.tbl_filter(function(source)
      return language.in_package(source.path)
    end, files)
    local covered = language.covered and cached("covered", language, sources, function()
      return language.covered(sources)
    end)
    memo = { sources = sources, covered = covered }
    if directories then
      directories[key] = memo
    end
  end
  -- Go's module is the whole directory.
  if not language.covered then
    return memo.sources
  end
  local path = git_root .. "/" .. rel_path
  if memo.covered and memo.covered[path] then
    return memo.sources
  end
  for _, source in ipairs(memo.sources) do
    if source.path == path then
      return { source }
    end
  end
  return {}
end

-- Whether path is a test file of a language with an API view.
function M.is_test(path)
  local language = language_of(path)
  return language ~= nil and language.is_test(path)
end

-- The name a whole-directory module goes by in the explorer, such as
-- "package shop": Go's package clause, or the directory's name.
local function module_name(git_root, dir, first_line)
  if type(first_line) == "table" then
    first_line = first_line.text
  end
  local clause = type(first_line) == "string" and first_line:match("^package [%w_]+")
  if clause then
    return clause
  end
  return "package " .. vim.fn.fnamemodify(dir == "." and git_root or dir, ":t")
end

-- Sort changed files for the explorer's API layout. files are explorer
-- entries { path, old_path, status }, with paths relative to git_root.
-- revisions(file) returns the revisions to read the file's module at, old
-- side then new side, as module_sources takes them. Returns:
--   modules  one entry per module whose API differs between the revisions,
--            as { label, name, files }, where files are its changed files
--            in the order given. label is the module's directory with a
--            trailing slash, or the file's path for a module of one file.
--            name, such as "package shop", is set for a directory module.
--   tests    the test files of languages with an API view.
--   rest     every other file, including the files of modules whose API is
--            the same on both sides.
function M.sort_changes(git_root, files, revisions)
  local opts = { comments = M.comments_shown(), private = M.private_shown() }

  -- Look each file's language up once.
  local languages_of = {}
  local function lang(path)
    if languages_of[path] == nil then
      languages_of[path] = language_of(path) or false
    end
    return languages_of[path] or nil
  end

  -- A commit read by its hash is read from the cache on the next sort. The
  -- index and the working tree are read each time.
  local hashes = {}
  local function resolve(revision)
    if revision == nil or revision == "WORKING" or revision == ":0" or revision == "STAGED" then
      return revision
    end
    if hashes[revision] == nil then
      hashes[revision] = vim.trim(git(git_root, { "rev-parse", "--verify", "--quiet", revision .. "^{commit}" }) or "")
    end
    return hashes[revision] ~= "" and hashes[revision] or revision
  end

  -- Read every directory a module comes from in one go per revision.
  local wanted, revision_order = {}, {}
  local function want(revision, path)
    local key = revision or "WORKING"
    if not wanted[key] then
      wanted[key] = { revision = revision, dirs = {}, seen = {} }
      revision_order[#revision_order + 1] = key
    end
    local rel_dir = vim.fn.fnamemodify(path, ":h")
    if not wanted[key].seen[rel_dir] then
      wanted[key].seen[rel_dir] = true
      table.insert(wanted[key].dirs, rel_dir)
    end
  end
  for _, file in ipairs(files) do
    local language = lang(file.path)
    if language and not language.is_test(file.path) then
      local old_revision, new_revision = revisions(file)
      want(resolve(old_revision), file.old_path or file.path)
      want(resolve(new_revision), file.path)
    end
  end
  local directories = {}
  local function source_file(path)
    return lang(path) ~= nil
  end
  for _, key in ipairs(revision_order) do
    directories[key] = read_directories(git_root, wanted[key].revision, wanted[key].dirs, source_file)
  end

  local by_key, order, module_of_file, tests, test_set = {}, {}, {}, {}, {}

  for _, file in ipairs(files) do
    local language = lang(file.path)
    if language and language.is_test(file.path) then
      tests[#tests + 1] = file
      test_set[file] = true
    elseif language then
      local old_revision, new_revision = revisions(file)
      old_revision, new_revision = resolve(old_revision), resolve(new_revision)
      local added = file.status == "A" or file.status == "??"
      local old_sources = added and {} or M.module_sources(git_root, old_revision, file.old_path or file.path, language, directories)
      local new_sources = file.status == "D" and {} or M.module_sources(git_root, new_revision, file.path, language, directories)
      -- Go's module is the directory. A Python package view or TypeScript
      -- barrel view covers more than one file of the directory.
      local dir = vim.fn.fnamemodify(file.path, ":h")
      local whole_dir = language.module_of ~= nil or #old_sources > 1 or #new_sources > 1
      local key = language.filetype .. "\0" .. (whole_dir and dir or file.path)
      local module = by_key[key]
      if not module then
        local kind = string.format("extract:%s:%s", opts.comments, opts.private)
        local function lines_of(sources)
          return cached(kind, language, sources, function()
            return (language.extract(sources, opts))
          end) or {}
        end
        local old_lines, new_lines = lines_of(old_sources), lines_of(new_sources)
        module = {
          label = whole_dir and (dir == "." and "./" or dir .. "/") or file.path,
          name = whole_dir and module_name(git_root, dir, new_lines[1] or old_lines[1]) or nil,
          files = {},
          changed = not vim.deep_equal(old_lines, new_lines),
        }
        by_key[key] = module
        order[#order + 1] = module
      end
      module.files[#module.files + 1] = file
      module_of_file[file] = module
    end
  end

  local modules, rest = {}, {}
  for _, module in ipairs(order) do
    if module.changed then
      modules[#modules + 1] = { label = module.label, name = module.name, files = module.files }
    end
  end
  for _, file in ipairs(files) do
    local module = module_of_file[file]
    if not test_set[file] and not (module and module.changed) then
      rest[#rest + 1] = file
    end
  end
  return modules, tests, rest
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
      -- A line without a source, such as a blank one, rebuilds from the file
      -- the view was built for, with the cursor on the same line.
      local rebuilt = build(target and target.file or view.path)
      if rebuilt and not target then
        vim.api.nvim_win_set_cursor(win, { math.min(vim.api.nvim_win_get_cursor(win)[1], vim.api.nvim_buf_line_count(rebuilt)), 0 })
      elseif rebuilt then
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
