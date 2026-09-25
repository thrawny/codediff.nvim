-- Review context documents (PR description, Jira ticket)
-- Only populated for review sessions: `review` stashes the entries here, and
-- the explorer consumes them when it builds its tree. PR reviews get the PR and
-- its Jira ticket; other reviews get the ticket named in the branch, if any.
local M = {}

local config = require("codediff.review.config")

---@class CodeDiffReviewContextEntry
---@field id string Stable id used for selection highlighting
---@field label string Text shown in the explorer
---@field icon string
---@field icon_color string
---@field kind "pr"|"jira"
---@field title string Buffer title line
---@field body string|nil Content, fetched lazily when nil
---@field key string|nil Jira issue key (jira entries only)

---@type CodeDiffReviewContextEntry[]|nil
local pending = nil

local JIRA_KEY_PATTERN = "%f[%u][%u][%u%d]+%-%d+"

local function system(args, cwd)
  return vim.system(args, { cwd = cwd, text = true }):wait(10000)
end

-- The jira CLI colours and right-pads its output even under `--plain`, so its
-- stdout arrives with SGR escapes and trailing spaces on every line.
---@param text string
---@return string
local function sanitize(text)
  text = text:gsub("\27%[[%d;]*m", "")
  text = text:gsub("[^\n]*", function(line)
    return (line:gsub("%s+$", ""))
  end)
  return vim.trim(text)
end

local function jira_config()
  local cfg = config.get()
  return vim.tbl_deep_extend("force", { enabled = true, cmd = "jira" }, cfg.jira or {})
end

--- Extract a Jira issue key from free text (PR title or branch name).
---@param text string|nil
---@return string|nil
function M.jira_key(text)
  if not text or text == "" then
    return nil
  end
  return text:match(JIRA_KEY_PATTERN)
end

---@param key string
---@return CodeDiffReviewContextEntry|nil
local function jira_entry(key)
  if not key or not jira_config().enabled then
    return nil
  end
  return {
    id = "context:jira",
    label = key,
    icon = "\u{f02b}", -- Nerd Font: tag
    icon_color = "ReviewContextJira",
    kind = "jira",
    title = key,
    key = key,
  }
end

--- Build the context entries for a PR.
---@param pr table
---@return CodeDiffReviewContextEntry[]
function M.entries_for_pr(pr)
  local entries = {}

  entries[#entries + 1] = {
    id = "context:pr",
    label = string.format("#%d %s", pr.number, pr.title or ""),
    icon = "\u{f407}", -- Nerd Font: git-pull-request
    icon_color = "ReviewContextPr",
    kind = "pr",
    title = string.format("PR #%d — %s", pr.number, pr.title or ""),
    body = pr.body,
    url = pr.url,
  }

  entries[#entries + 1] = jira_entry(M.jira_key(pr.title) or M.jira_key(pr.headRefName))

  return entries
end

--- Build the context entries for a review without a PR: the Jira ticket named
--- in the reviewed revision, or failing that in the checked-out branch.
---@param revision string|nil
---@param deps? table
---@return CodeDiffReviewContextEntry[]
function M.entries_for_revision(revision, deps)
  deps = deps or {}
  local key = M.jira_key(revision)
  if not key and jira_config().enabled then
    local result = (deps.system or system)({ "git", "rev-parse", "--abbrev-ref", "HEAD" }, deps.cwd)
    if result.code == 0 then
      key = M.jira_key(vim.trim(result.stdout or ""))
    end
  end
  return { jira_entry(key) }
end

--- Whether entries are already stashed for the next explorer.
---@return boolean
function M.has_pending()
  return pending ~= nil
end

--- Stash entries for the explorer that is about to be created.
---@param entries CodeDiffReviewContextEntry[]|nil
function M.set_pending(entries)
  pending = (entries and #entries > 0) and entries or nil
end

--- Take the stashed entries, clearing them so later non-PR sessions see none.
---@return CodeDiffReviewContextEntry[]|nil
function M.take_pending()
  local entries = pending
  pending = nil
  return entries
end

--- Content lines for an entry, fetching and caching the body when needed.
---@param entry CodeDiffReviewContextEntry
---@param deps? table
---@return string[]|nil lines, string|nil err
function M.lines(entry, deps)
  deps = deps or {}

  if not entry.body then
    if entry.kind == "jira" then
      local jira = jira_config()
      local result = (deps.system or system)({ jira.cmd, "issue", "view", entry.key, "--plain" }, deps.cwd)
      if result.code ~= 0 then
        local stderr = vim.trim((result.stderr or "") ~= "" and result.stderr or (result.stdout or ""))
        return nil, string.format("%s issue view %s failed: %s", jira.cmd, entry.key, stderr)
      end
      entry.body = sanitize(result.stdout or "")
    end
  end

  local body = entry.body
  if not body or body == "" then
    body = "_No description._"
  end

  local lines = { "# " .. entry.title }
  if entry.url then
    lines[#lines + 1] = ""
    lines[#lines + 1] = entry.url
  end
  lines[#lines + 1] = ""
  for line in (body .. "\n"):gmatch("(.-)\r?\n") do
    lines[#lines + 1] = line
  end

  return lines, nil
end

return M
