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

  return filter.split_generated(files, generated_patterns, git_root, use_gitattributes)
end

-- Split files whose diff is implementation-only (per seam classification)
-- into their own list, so they can live in a collapsed group.
local function split_impl_only(files, seam_results, group)
  if not seam_results then
    return files, {}
  end
  local regular = {}
  local impl_only = {}
  for _, file in ipairs(files) do
    local entry = seam_results[group .. ":" .. file.path]
    if file.status == "M" and entry and entry.result == "impl" then
      file.is_impl_only = true
      table.insert(impl_only, file)
    else
      table.insert(regular, file)
    end
  end
  return regular, impl_only
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

-- Create tree data structure from git status result
function M.create_tree_data(status_result, git_root, base_revision, is_dir_mode, visible_groups, seam_results)
  local explorer_config = config.options.explorer or {}
  local view_mode = explorer_config.view_mode or "list"
  visible_groups = visible_groups or explorer_config.visible_groups or {}
  if explorer_config.collapse_impl_only == false then
    seam_results = nil
  end

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

  local impl_unstaged
  local impl_staged
  unstaged, impl_unstaged = split_impl_only(unstaged, seam_results, "unstaged")
  staged, impl_staged = split_impl_only(staged, seam_results, "staged")

  if is_dir_mode or base_revision then
    -- Dir or revision mode: single group showing all changes, with generated files collapsed separately.
    local tree_nodes = {}
    tree_nodes[#tree_nodes + 1] = make_group("unstaged", "Changes", unstaged, create_nodes, git_root)
    if #impl_unstaged > 0 then
      tree_nodes[#tree_nodes + 1] = make_group("unstaged", "Implementation-only Changes", impl_unstaged, create_nodes, git_root, true)
    end
    if #generated_unstaged > 0 then
      tree_nodes[#tree_nodes + 1] = make_group("unstaged", "Generated files", generated_unstaged, create_nodes, git_root, true)
    end
    return tree_nodes
  else
    -- Status mode: separate conflicts/staged/unstaged groups
    local tree_nodes = {}

    -- Conflicts first (most important)
    if visible_groups.conflicts ~= false then
      if #conflicts > 0 then
        tree_nodes[#tree_nodes + 1] = make_group("conflicts", "Merge Changes", conflicts, create_nodes, git_root)
      end
      if #generated_conflicts > 0 then
        tree_nodes[#tree_nodes + 1] = make_group("conflicts", "Generated Merge Changes", generated_conflicts, create_nodes, git_root, true)
      end
    end

    -- Unstaged changes
    if visible_groups.unstaged ~= false then
      tree_nodes[#tree_nodes + 1] = make_group("unstaged", "Changes", unstaged, create_nodes, git_root)
      if #impl_unstaged > 0 then
        tree_nodes[#tree_nodes + 1] = make_group("unstaged", "Implementation-only Changes", impl_unstaged, create_nodes, git_root, true)
      end
      if #generated_unstaged > 0 then
        tree_nodes[#tree_nodes + 1] = make_group("unstaged", "Generated Changes", generated_unstaged, create_nodes, git_root, true)
      end
    end

    -- Staged changes
    if visible_groups.staged ~= false then
      tree_nodes[#tree_nodes + 1] = make_group("staged", "Staged Changes", staged, create_nodes, git_root)
      if #impl_staged > 0 then
        tree_nodes[#tree_nodes + 1] = make_group("staged", "Implementation-only Staged Changes", impl_staged, create_nodes, git_root, true)
      end
      if #generated_staged > 0 then
        tree_nodes[#tree_nodes + 1] = make_group("staged", "Generated Staged Changes", generated_staged, create_nodes, git_root, true)
      end
    end

    return tree_nodes
  end
end

return M
