-- Tree data structure building for explorer
-- Handles creating the tree hierarchy from git status
local M = {}

local Tree = require("codediff.ui.lib.tree")
local config = require("codediff.config")
local filter = require("codediff.ui.explorer.filter")
local nodes = require("codediff.ui.explorer.nodes")

-- Filter files based on explorer.file_filter config
-- Returns files that should be shown (not ignored)
local function filter_files(files)
  local explorer_config = config.options.explorer or {}
  local file_filter = explorer_config.file_filter or {}
  local ignore_patterns = file_filter.ignore or {}

  return filter.apply(files, ignore_patterns)
end

local function split_generated(files, git_root)
  local explorer_config = config.options.explorer or {}
  local file_filter = explorer_config.file_filter or {}
  local generated_patterns = file_filter.generated or {}
  local use_gitattributes = file_filter.gitattributes_generated ~= false
  local use_header = file_filter.header_generated ~= false

  return filter.split_generated(files, generated_patterns, git_root, use_gitattributes, use_header)
end

local function make_group(name, label, files, create_nodes, git_root, default_collapsed)
  return Tree.Node({
    text = string.format("%s (%d)", label, #files),
    data = {
      type = "group",
      name = name,
      collapse_key = name .. ":" .. label,
      default_collapsed = default_collapsed,
    },
  }, create_nodes(files, git_root, name))
end

-- Review context group (PR description, Jira ticket). Present only for PR
-- reviews, and deliberately not a file group: these entries are excluded from
-- file cycling (see refresh.get_all_files).
local function make_context_group(entries)
  return Tree.Node({
    text = string.format("Context (%d)", #entries),
    data = {
      type = "group",
      name = "context",
      collapse_key = "context:Context",
    },
  }, nodes.create_context_nodes(entries))
end

-- The revisions to read a group's modules at for the API layout, old side
-- then new side, as api.module_sources takes them.
local function module_revisions(group, base_revision, target_revision)
  if base_revision then
    local target = target_revision ~= "WORKING" and target_revision or nil
    return function()
      return base_revision, target
    end
  end
  if group == "staged" then
    return function()
      return "HEAD", ":0"
    end
  end
  return function()
    return ":0", nil
  end
end

-- One explorer entry for a directory module, placed in its directory and
-- named like "package shop". Selecting it opens the module's first changed
-- file, whose API view shows the whole module. A module whose API did not
-- change shows no status letter.
local function module_entry(module)
  local first = module.files[1]
  local status = first.status
  local paths = {}
  for _, f in ipairs(module.files) do
    paths[#paths + 1] = f.path
    if f.status ~= status then
      status = "M"
    end
  end
  local dir = module.label:gsub("/$", "")
  return {
    path = first.path,
    old_path = first.old_path,
    status = status,
    display_path = (dir == "." or dir == "") and module.name or dir .. "/" .. module.name,
    api_files = paths,
    api_unchanged = not module.changed,
  }
end

-- Sort entries the way the tree shows them: by directory, then a module
-- before the files beside it, then by name.
local function sort_entries(entries)
  local function key(entry)
    local path = entry.display_path or entry.path
    return path:match("^(.*)/") or "", entry.api_files and 0 or 1, path:match("([^/]+)$")
  end
  table.sort(entries, function(a, b)
    local a_dir, a_rank, a_name = key(a)
    local b_dir, b_rank, b_name = key(b)
    if a_dir ~= b_dir then
      return a_dir < b_dir
    end
    if a_rank ~= b_rank then
      return a_rank < b_rank
    end
    return a_name < b_name
  end)
  return entries
end

-- The API layout: the usual groups, where the changed files of each
-- directory module give way to one module entry in their directory. Tests
-- and every other file stay as they are, so next and previous file still
-- step through the whole change.
local function api_layout(sections, git_root, base_revision, target_revision)
  local api = require("codediff.api")
  for _, section in ipairs(sections) do
    if not section.default_collapsed and section.name ~= "conflicts" then
      local modules, tests, rest = api.sort_changes(git_root, section.files, module_revisions(section.name, base_revision, target_revision))
      local entries = {}
      for _, module in ipairs(modules) do
        if module.name then
          entries[#entries + 1] = module_entry(module)
        else
          vim.list_extend(entries, module.files)
        end
      end
      vim.list_extend(entries, tests)
      vim.list_extend(entries, rest)
      section.files = sort_entries(entries)
    end
  end
end

-- Create tree data structure from git status result. opts.api_layout builds
-- the API layout, which needs opts.target_revision in revision mode.
function M.create_tree_data(status_result, git_root, base_revision, is_dir_mode, visible_groups, context_entries, opts)
  opts = opts or {}
  local explorer_config = config.options.explorer or {}
  local view_mode = explorer_config.view_mode or "list"
  visible_groups = visible_groups or explorer_config.visible_groups or {}

  -- Filter merge artifacts and apply file filter
  local unstaged = nodes.filter_merge_artifacts(filter_files(status_result.unstaged))
  local staged = nodes.filter_merge_artifacts(filter_files(status_result.staged))
  local conflicts = status_result.conflicts and nodes.filter_merge_artifacts(filter_files(status_result.conflicts)) or {}

  local generated_unstaged
  local generated_staged
  local generated_conflicts
  unstaged, generated_unstaged = split_generated(unstaged, git_root)
  staged, generated_staged = split_generated(staged, git_root)
  conflicts, generated_conflicts = split_generated(conflicts, git_root)

  local create_nodes = (view_mode == "tree") and nodes.create_tree_file_nodes or nodes.create_file_nodes

  -- The file groups in display order. A section without default_collapsed
  -- shows even when empty.
  local sections = {}
  local function add(name, label, files, default_collapsed)
    if not default_collapsed or #files > 0 then
      sections[#sections + 1] = { name = name, label = label, files = files, default_collapsed = default_collapsed }
    end
  end

  if is_dir_mode or base_revision then
    -- Dir or revision mode: single group showing all changes, with generated files collapsed separately.
    add("unstaged", "Changes", unstaged)
    add("unstaged", "Generated files", generated_unstaged, true)
  else
    -- Status mode: separate conflicts/staged/unstaged groups, conflicts first
    -- (most important).
    if visible_groups.conflicts ~= false then
      if #conflicts > 0 then
        add("conflicts", "Merge Changes", conflicts)
      end
      add("conflicts", "Generated Merge Changes", generated_conflicts, true)
    end
    if visible_groups.unstaged ~= false then
      add("unstaged", "Changes", unstaged)
      add("unstaged", "Generated Changes", generated_unstaged, true)
    end
    if visible_groups.staged ~= false then
      add("staged", "Staged Changes", staged)
      add("staged", "Generated Staged Changes", generated_staged, true)
    end
  end

  local tree_nodes = {}
  if context_entries and #context_entries > 0 then
    tree_nodes[#tree_nodes + 1] = make_context_group(context_entries)
  end
  if opts.api_layout and git_root and not is_dir_mode then
    api_layout(sections, git_root, base_revision, opts.target_revision)
  end
  for _, section in ipairs(sections) do
    tree_nodes[#tree_nodes + 1] = make_group(section.name, section.label, section.files, create_nodes, git_root, section.default_collapsed)
  end
  return tree_nodes
end

return M
