local M = {}

local config = require("codediff.review.config")

local function github_config()
  local cfg = config.get()
  return vim.tbl_deep_extend("force", { remote = "origin", pr_limit = 100 }, cfg.github or {})
end

local function system(args, cwd)
  return vim.system(args, { cwd = cwd, text = true }):wait()
end

local function shell_error(result)
  return vim.trim((result and result.stderr) or (result and result.stdout) or "command failed")
end

local function notify_error(message)
  vim.notify(message, vim.log.levels.ERROR, { title = "codediff.review" })
end

local function git_root(deps)
  local result = (deps.system or system)({ "git", "rev-parse", "--show-toplevel" }, deps.cwd)
  if result.code ~= 0 then
    return nil, "Not in a git repository: " .. shell_error(result)
  end
  return vim.trim(result.stdout or ""), nil
end

function M.format_pr(pr)
  local draft = pr.isDraft and "[draft] " or ""
  local author = pr.author and pr.author.login or "unknown"
  return string.format("#%d %s%s  @%s  %s → %s", pr.number, draft, pr.title or "", author, pr.headRefName or "?", pr.baseRefName or "?")
end

function M.parse_prs(json)
  local ok, parsed = pcall(vim.fn.json_decode, json)
  if not ok or type(parsed) ~= "table" then
    return nil, "Could not parse PR data from gh"
  end
  return parsed, nil
end

function M.review_ref(number)
  return "refs/review/pr-" .. tostring(number)
end

function M.remote_base_ref(base, remote)
  return "refs/remotes/" .. (remote or github_config().remote) .. "/" .. base
end

function M.fetch_args(pr, opts)
  opts = opts or {}
  local remote = opts.remote or github_config().remote
  local pr_ref = M.review_ref(pr.number)
  return {
    "git",
    "fetch",
    remote,
    "+refs/pull/" .. tostring(pr.number) .. "/head:" .. pr_ref,
    "+refs/heads/" .. pr.baseRefName .. ":" .. M.remote_base_ref(pr.baseRefName, remote),
  }
end

function M.list_prs(root, deps)
  deps = deps or {}
  local run = deps.system or system
  local gh = github_config()
  local result = run({
    "gh",
    "pr",
    "list",
    "--state",
    "open",
    "--limit",
    tostring(gh.pr_limit),
    "--json",
    "number,title,author,headRefName,baseRefName,isDraft,url",
  }, root)

  if result.code ~= 0 then
    return nil, "gh pr list failed: " .. shell_error(result)
  end

  local prs, err = M.parse_prs(result.stdout or "")
  if err then
    return nil, err
  end
  if #prs == 0 then
    return nil, "No open GitHub PRs found"
  end
  return prs, nil
end

function M.get_pr(number, root, deps)
  deps = deps or {}
  local result = (deps.system or system)({
    "gh",
    "pr",
    "view",
    tostring(number),
    "--json",
    "number,title,author,headRefName,baseRefName,isDraft,url,body",
  }, root)

  if result.code ~= 0 then
    return nil, "gh pr view failed: " .. shell_error(result)
  end

  local ok, pr = pcall(vim.fn.json_decode, result.stdout or "")
  if not ok or type(pr) ~= "table" then
    return nil, "Could not parse PR data from gh"
  end
  return pr, nil
end

local function rev_parse(ref, root, deps)
  local result = (deps.system or system)({ "git", "rev-parse", ref }, root)
  if result.code ~= 0 then
    return nil, "git rev-parse failed: " .. shell_error(result)
  end
  local sha = vim.trim(result.stdout or "")
  if sha == "" then
    return nil, "git rev-parse returned no commit"
  end
  return sha, nil
end

local function cleanup_ref(ref, root, deps)
  (deps.system or system)({ "git", "update-ref", "-d", ref }, root)
end

-- The PR list omits the body to keep `gh pr list` cheap; fetch it on demand so
-- the explorer can show the description alongside the changed files.
local function with_body(pr, root, deps)
  if pr.body ~= nil then
    return pr
  end
  local full = M.get_pr(pr.number, root, deps)
  return full or pr
end

function M.review_pr(pr, root, deps)
  deps = deps or {}
  local run = deps.system or system
  local gh = github_config()

  local fetch = run(M.fetch_args(pr, gh), root)
  if fetch.code ~= 0 then
    notify_error("git fetch failed: " .. shell_error(fetch))
    return
  end

  local pr_ref = M.review_ref(pr.number)
  local base_ref = M.remote_base_ref(pr.baseRefName, gh.remote)
  local merge_base = run({ "git", "merge-base", base_ref, pr_ref }, root)
  if merge_base.code ~= 0 then
    cleanup_ref(pr_ref, root, deps)
    notify_error("git merge-base failed: " .. shell_error(merge_base))
    return
  end

  local base_sha = vim.trim(merge_base.stdout or "")
  if base_sha == "" then
    cleanup_ref(pr_ref, root, deps)
    notify_error("git merge-base returned no commit")
    return
  end

  local pr_sha, err = rev_parse(pr_ref, root, deps)
  cleanup_ref(pr_ref, root, deps)
  if err then
    notify_error(err)
    return
  end

  local open_commits = deps.open_commits or require("codediff.review").open_commits
  local context = require("codediff.review.context")
  context.set_pending(context.entries_for_pr(with_body(pr, root, deps)))
  open_commits(base_sha, pr_sha)
end

local function ref_exists(ref, root, deps)
  return (deps.system or system)({ "git", "rev-parse", "--verify", "--quiet", ref }, root).code == 0
end

-- The base to review the checked-out branch against: its open PR's base, so a
-- stacked PR is reviewed against its parent branch, else the remote's default branch.
function M.branch_base(deps)
  deps = deps or {}
  local run = deps.system or system
  local root, root_err = git_root(deps)
  if root_err then
    return nil, root_err
  end
  local remote = github_config().remote

  local view = run({ "gh", "pr", "view", "--json", "baseRefName", "--jq", ".baseRefName" }, root)
  local pr_base = view.code == 0 and vim.trim(view.stdout or "") or ""
  if pr_base ~= "" then
    local remote_ref = remote .. "/" .. pr_base
    if ref_exists(M.remote_base_ref(pr_base, remote), root, deps) then
      return remote_ref, nil
    end
    if ref_exists("refs/heads/" .. pr_base, root, deps) then
      return pr_base, nil
    end
  end

  local head = run({ "git", "symbolic-ref", "--short", "refs/remotes/" .. remote .. "/HEAD" }, root)
  local default_ref = head.code == 0 and vim.trim(head.stdout or "") or ""
  if default_ref ~= "" then
    return default_ref, nil
  end
  return remote .. "/main", nil
end

function M.open(number, deps)
  deps = deps or {}
  local root, root_err = git_root(deps)
  if root_err then
    notify_error(root_err)
    return
  end

  if number then
    local pr, err = M.get_pr(number, root, deps)
    if err then
      notify_error(err)
      return
    end
    M.review_pr(pr, root, deps)
    return
  end

  local prs, err = M.list_prs(root, deps)
  if err then
    notify_error(err)
    return
  end

  (deps.select or vim.ui.select)(prs, {
    prompt = "Review GitHub PR",
    kind = "review_pr",
    format_item = M.format_pr,
  }, function(pr)
    if pr then
      M.review_pr(pr, root, deps)
    end
  end)
end

return M
