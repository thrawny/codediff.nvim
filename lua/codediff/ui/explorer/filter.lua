local M = {}

local gitattributes_cache = {}

-- Convert glob pattern to Lua pattern
function M.glob_to_pattern(glob)
  -- Use unique placeholders that won't appear in file paths
  local DOUBLE_STAR_SLASH = "\001DOUBLESTARSLASH\001"
  local DOUBLE_STAR = "\001DOUBLESTAR\001"
  local SINGLE_STAR = "\001SINGLESTAR\001"

  local pattern = glob
  -- Escape Lua magic characters (except * and ?)
  pattern = pattern:gsub("([%.%+%-%^%$%(%)%[%]%%])", "%%%1")
  -- Convert glob wildcards to placeholders first (order matters!)
  -- Handle **/ specially - it matches zero or more directories
  pattern = pattern:gsub("%*%*/", DOUBLE_STAR_SLASH)
  pattern = pattern:gsub("%*%*", DOUBLE_STAR)
  pattern = pattern:gsub("%*", SINGLE_STAR)
  pattern = pattern:gsub("%?", ".") -- ? matches single character
  -- Now convert placeholders to Lua patterns
  pattern = pattern:gsub(DOUBLE_STAR_SLASH, ".-") -- **/ matches zero or more dirs (including trailing /)
  pattern = pattern:gsub(DOUBLE_STAR, ".*") -- ** matches anything including /
  pattern = pattern:gsub(SINGLE_STAR, "[^/]*") -- * matches anything except /
  return "^" .. pattern .. "$"
end

-- Check if a file path matches any of the given glob patterns
-- Follows gitignore-style matching:
--   *.pb.go      → match basename anywhere
--   /*.pb.go     → match only in root (leading / anchors)
--   foo/*.pb.go  → match in foo/ directory
--   **/*.pb.go   → match anywhere (explicit)
function M.matches_any_pattern(path, patterns)
  if not patterns or #patterns == 0 then
    return false
  end
  local basename = path:match("([^/]+)$") or path
  for _, glob in ipairs(patterns) do
    local match_target
    local match_pattern

    if glob:sub(1, 1) == "/" then
      -- Leading / anchors to root - match full path against pattern without /
      match_target = path
      match_pattern = M.glob_to_pattern(glob:sub(2))
    elseif glob:find("/") then
      -- Contains / but no leading / - match full path
      match_target = path
      match_pattern = M.glob_to_pattern(glob)
    else
      -- No / at all - match basename only (matches anywhere)
      match_target = basename
      match_pattern = M.glob_to_pattern(glob)
    end

    if match_target:match(match_pattern) then
      return true
    end
  end
  return false
end

-- Filter files based on explorer.file_filter config
-- Returns files that should be shown (not ignored)
function M.apply(files, ignore_patterns)
  if not ignore_patterns or #ignore_patterns == 0 then
    return files
  end

  local filtered = {}
  for _, file in ipairs(files) do
    if not M.matches_any_pattern(file.path, ignore_patterns) then
      filtered[#filtered + 1] = file
    end
  end

  return filtered
end

local function normalize_gitattributes_pattern(pattern)
  if not pattern or pattern == "" then
    return nil
  end

  -- Quoted patterns and escaped spaces are uncommon for generated-file markers;
  -- keep this parser intentionally conservative for the common GitHub/Linguist case.
  if pattern:sub(1, 1) == '"' then
    return nil
  end

  -- A trailing slash is a common shorthand users expect to mean the whole directory.
  if pattern:sub(-1) == "/" then
    pattern = pattern .. "**"
  end

  return pattern
end

local function parse_linguist_generated(attrs)
  local result = nil

  for _, attr in ipairs(attrs) do
    if attr == "linguist-generated" or attr == "linguist-generated=true" then
      result = true
    elseif attr == "-linguist-generated" or attr == "linguist-generated=false" then
      result = false
    end
  end

  return result
end

function M.parse_gitattributes(lines)
  local rules = {}

  for _, line in ipairs(lines or {}) do
    line = line:match("^%s*(.-)%s*$")
    if line ~= "" and line:sub(1, 1) ~= "#" then
      local parts = {}
      for part in line:gmatch("%S+") do
        parts[#parts + 1] = part
      end

      local pattern = normalize_gitattributes_pattern(parts[1])
      if pattern and #parts > 1 then
        local attrs = {}
        for i = 2, #parts do
          attrs[#attrs + 1] = parts[i]
        end

        local generated = parse_linguist_generated(attrs)
        if generated ~= nil then
          rules[#rules + 1] = { pattern = pattern, generated = generated }
        end
      end
    end
  end

  return rules
end

function M.get_gitattributes_generated_rules(git_root)
  if not git_root or git_root == "" then
    return {}
  end

  local attr_path = git_root .. "/.gitattributes"
  local uv = vim.uv or vim.loop
  local stat = uv and uv.fs_stat(attr_path) or nil
  if not stat then
    gitattributes_cache[attr_path] = nil
    return {}
  end

  local mtime = stat.mtime and (stat.mtime.sec .. ":" .. stat.mtime.nsec) or ""
  local cache_key = table.concat({ tostring(stat.size or 0), mtime }, ":")
  local cached = gitattributes_cache[attr_path]
  if cached and cached.cache_key == cache_key then
    return cached.rules
  end

  local ok, lines = pcall(vim.fn.readfile, attr_path)
  if not ok then
    return {}
  end

  local rules = M.parse_gitattributes(lines)
  gitattributes_cache[attr_path] = { cache_key = cache_key, rules = rules }
  return rules
end

function M.matches_gitattributes_generated(path, git_root)
  local rules = M.get_gitattributes_generated_rules(git_root)
  local generated = nil

  for _, rule in ipairs(rules) do
    if M.matches_any_pattern(path, { rule.pattern }) then
      -- Match .gitattributes' later-lines-win behavior for the subset we support.
      generated = rule.generated
    end
  end

  return generated == true
end

function M.is_generated(path, generated_patterns, git_root, use_gitattributes)
  if M.matches_any_pattern(path, generated_patterns) then
    return true
  end

  if use_gitattributes ~= false and M.matches_gitattributes_generated(path, git_root) then
    return true
  end

  return false
end

function M.split_generated(files, generated_patterns, git_root, use_gitattributes)
  local regular = {}
  local generated = {}

  for _, file in ipairs(files or {}) do
    if
      M.is_generated(file.path, generated_patterns, git_root, use_gitattributes)
      or (file.old_path and M.is_generated(file.old_path, generated_patterns, git_root, use_gitattributes))
    then
      file.is_generated = true
      generated[#generated + 1] = file
    else
      regular[#regular + 1] = file
    end
  end

  return regular, generated
end

return M
