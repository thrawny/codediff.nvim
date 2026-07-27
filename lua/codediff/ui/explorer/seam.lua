-- Seam classification for explorer file lists.
-- Classifies each modified file as "seam" (declaration/signature-level
-- changes), "impl" (implementation-only changes), or "unsupported" (no
-- treesitter parser). Implementation-only files are moved to a collapsed
-- group by the tree builder — never hidden, just out of the way.
local M = {}

local config = require("codediff.config")
local git = require("codediff.core.git")
local symbols = require("codediff.core.symbols")

local function enabled()
  local explorer_config = config.options.explorer or {}
  return explorer_config.collapse_impl_only ~= false
end

---Result for a file, or nil when not (yet) classified.
---@return "seam"|"impl"|"unsupported"|nil
function M.get_result(explorer, group, path)
  local results = explorer and explorer.seam_results
  local entry = results and results[group .. ":" .. path]
  return entry and entry.result or nil
end

local function fs_fingerprint(abs_path)
  local uv = vim.uv or vim.loop
  local stat = uv.fs_stat(abs_path)
  if not stat then
    return nil
  end
  return stat.mtime.sec .. ":" .. stat.size
end

local function read_file(abs_path)
  local f = io.open(abs_path, "r")
  if not f then
    return nil
  end
  local content = f:read("*a")
  f:close()
  return content
end

---@class codediff.SeamJob
---@field path string repo-relative path
---@field group string "unstaged"|"staged"
---@field old_revision string git revision for the old side
---@field new_source string "worktree" or a git revision
---@field volatile boolean? content behind new_source can change (index) — never cache

local function collect_jobs(jobs, files, group, old_revision, new_source, volatile)
  for _, file in ipairs(files or {}) do
    -- Only plain modifications are classified; adds/deletes/renames are
    -- seams by definition and stay in the regular group.
    if file.status == "M" then
      table.insert(jobs, {
        path = file.path,
        group = group,
        old_revision = old_revision,
        new_source = new_source,
        volatile = volatile,
      })
    end
  end
end

local function run_job(explorer, job, finish)
  local results = explorer.seam_results
  local key = job.group .. ":" .. job.path
  local prev = results[key]

  local function set(result, fingerprint)
    -- Only impl↔non-impl transitions move files between tree groups, so only
    -- those count as changes worth a tree rebuild.
    local was_impl = prev ~= nil and prev.result == "impl"
    local did_change = (result == "impl") ~= was_impl
    results[key] = { result = result, fingerprint = fingerprint }
    finish(did_change)
  end

  local lang = symbols.get_path_lang(job.path)
  if not lang then
    if prev then
      finish(false)
    else
      set("unsupported", "static")
    end
    return
  end

  -- git content arrives as lines; rejoin with a trailing newline so it
  -- diffs cleanly against worktree reads (which keep their final newline)
  local function join_lines(lines)
    return table.concat(lines, "\n") .. "\n"
  end

  local function classify_with_new(new_content, fingerprint)
    git.get_file_content(job.old_revision, explorer.git_root, job.path, function(err, old_lines)
      vim.schedule(function()
        if err or not old_lines then
          -- Cannot read the old side: never collapse what we cannot classify
          set("seam", fingerprint)
          return
        end
        local ok, result = pcall(symbols.classify_file, lang, join_lines(old_lines), new_content)
        set(ok and result or "unsupported", fingerprint)
      end)
    end)
  end

  if job.new_source == "worktree" then
    local abs = explorer.git_root .. "/" .. job.path
    local fingerprint = fs_fingerprint(abs) or "missing"
    if prev and prev.fingerprint == fingerprint then
      finish(false)
      return
    end
    local content = read_file(abs)
    if not content then
      set("seam", fingerprint)
      return
    end
    classify_with_new(content, fingerprint)
  else
    local fingerprint = job.old_revision .. ".." .. job.new_source
    if not job.volatile and prev and prev.fingerprint == fingerprint then
      finish(false)
      return
    end
    git.get_file_content(job.new_source, explorer.git_root, job.path, function(err, new_lines)
      vim.schedule(function()
        if err or not new_lines then
          set("seam", fingerprint)
          return
        end
        classify_with_new(join_lines(new_lines), fingerprint)
      end)
    end)
  end
end

---Classify all modified files in the status result (async).
---Calls on_done(changed_count) where changed_count is the number of files
---whose impl-only membership changed — the caller only needs to rebuild the
---tree when it is > 0.
---@param explorer table
---@param status_result table
---@param on_done? fun(changed: number)
function M.classify(explorer, status_result, on_done)
  on_done = on_done or function() end
  if not enabled() or not explorer.git_root then
    on_done(0)
    return
  end
  explorer.seam_results = explorer.seam_results or {}

  local jobs = {}
  if explorer.base_revision then
    -- Revision mode: single "unstaged" group against the base revision
    local target = explorer.target_revision
    local new_source = (target and target ~= "WORKING") and target or "worktree"
    collect_jobs(jobs, status_result.unstaged, "unstaged", explorer.base_revision, new_source)
  else
    -- Status mode: unstaged is worktree vs index, staged is index vs HEAD.
    -- Index content changes as hunks are staged, so staged jobs are volatile.
    collect_jobs(jobs, status_result.unstaged, "unstaged", ":0", "worktree")
    collect_jobs(jobs, status_result.staged, "staged", "HEAD", ":0", true)
  end

  if #jobs == 0 then
    on_done(0)
    return
  end

  local pending = #jobs
  local changed = 0
  local function finish(did_change)
    if did_change then
      changed = changed + 1
    end
    pending = pending - 1
    if pending == 0 then
      vim.schedule(function()
        on_done(changed)
      end)
    end
  end

  for _, job in ipairs(jobs) do
    run_job(explorer, job, finish)
  end
end

return M
