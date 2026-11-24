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

-- The API layout: an API group with one entry per module whose API changed,
-- a Tests group, then the usual groups with every other file. Next and
-- previous file move through the API and Tests groups only, unless both are
-- empty. Generated and conflict groups keep their files.
local function api_layout(sections, git_root, base_revision, target_revision, create_nodes)
  local api = require("codediff.api")
  local modules, test_nodes, test_count = {}, {}, 0
  for _, section in ipairs(sections) do
    if not section.default_collapsed and section.name ~= "conflicts" then
      local section_modules, tests, rest = api.sort_changes(git_root, section.files, module_revisions(section.name, base_revision, target_revision))
      for _, module in ipairs(section_modules) do
        module.group = section.name
        modules[#modules + 1] = module
      end
      if #tests > 0 then
        vim.list_extend(test_nodes, create_nodes(tests, git_root, section.name))
        test_count = test_count + #tests
      end
      section.files = rest
    end
  end

  local tree_nodes = {}
  local navigable = #modules > 0 or #test_nodes > 0
  if #modules > 0 then
    tree_nodes[#tree_nodes + 1] = Tree.Node({
      text = string.format("API (%d)", #modules),
      data = { type = "group", name = "api", collapse_key = "api:API" },
    }, nodes.create_api_nodes(modules, git_root))
  end
  if #test_nodes > 0 then
    tree_nodes[#tree_nodes + 1] = Tree.Node({
      text = string.format("Tests (%d)", test_count),
      data = { type = "group", name = "tests", collapse_key = "tests:Tests" },
    }, test_nodes)
  end
  for _, section in ipairs(sections) do
    if #section.files > 0 then
      local group = make_group(section.name, section.label, section.files, create_nodes, git_root, section.default_collapsed)
      group.data.navigable = not navigable
      tree_nodes[#tree_nodes + 1] = group
    end
  end
  return tree_nodes
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
  -- shows even when empty, except in the API layout.
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
    return vim.list_extend(tree_nodes, api_layout(sections, git_root, base_revision, opts.target_revision, create_nodes))
  end
  for _, section in ipairs(sections) do
    tree_nodes[#tree_nodes + 1] = make_group(section.name, section.label, section.files, create_nodes, git_root, section.default_collapsed)
  end
  return tree_nodes
end

return M
