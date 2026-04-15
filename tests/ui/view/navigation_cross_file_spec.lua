local spec_path = debug.getinfo(1, "S").source:sub(2)
local plugin_root = vim.fn.fnamemodify(spec_path, ":p:h:h:h:h")
vim.opt.rtp:prepend(plugin_root)
package.path = package.path .. ";" .. plugin_root .. "/lua/?.lua;" .. plugin_root .. "/lua/?/init.lua"

local h = dofile("tests/helpers.lua")

h.ensure_plugin_loaded()

local function setup_command()
  local commands = require("codediff.commands")
  vim.api.nvim_create_user_command("CodeDiff", function(opts)
    commands.vscode_diff(opts)
  end, {
    nargs = "*",
    bang = true,
    complete = function()
      return { "file", "install" }
    end,
  })
end

local function base_lines(prefix)
  local lines = {}
  for i = 1, 20 do
    table.insert(lines, string.format("%s line %02d", prefix, i))
  end
  return lines
end

local function changed_lines(prefix, indices)
  local lines = base_lines(prefix)
  for _, idx in ipairs(indices) do
    lines[idx] = string.format("%s CHANGED %02d", prefix, idx)
  end
  return lines
end

local function create_repo(file_specs)
  local repo = h.create_temp_git_repo()
  for _, spec in ipairs(file_specs) do
    repo.write_file(spec.name, base_lines(spec.prefix))
  end
  repo.git("add .")
  repo.git('commit -m "initial"')
  for _, spec in ipairs(file_specs) do
    repo.write_file(spec.name, changed_lines(spec.prefix, spec.hunks))
  end
  return repo
end

local function open_codediff_and_wait(repo, focus_file)
  vim.fn.chdir(repo.dir)
  vim.cmd("edit " .. repo.path(focus_file))
  vim.cmd("CodeDiff")

  local lifecycle = require("codediff.ui.lifecycle")
  local tabpage

  local ready = vim.wait(10000, function()
    for _, tp in ipairs(vim.api.nvim_list_tabpages()) do
      local sess = lifecycle.get_session(tp)
      if sess and sess.explorer then
        tabpage = tp
        if lifecycle.is_render_pending(tp) then
          return false
        end
        local orig_buf, mod_buf = lifecycle.get_buffers(tp)
        return orig_buf and mod_buf and vim.api.nvim_buf_is_valid(orig_buf) and vim.api.nvim_buf_is_valid(mod_buf)
      end
    end
    return false
  end, 50)

  assert.is_true(ready, "CodeDiff session should be ready")
  return tabpage, lifecycle.get_session(tabpage), lifecycle.get_explorer(tabpage)
end

local function focus_modified_window(tabpage)
  local lifecycle = require("codediff.ui.lifecycle")
  local session = lifecycle.get_session(tabpage)
  assert.is_not_nil(session, "Session should exist")
  assert.is_true(vim.api.nvim_win_is_valid(session.modified_win), "Modified window should be valid")
  vim.api.nvim_set_current_win(session.modified_win)
end

local function wait_for_file_and_hunk(tabpage, file_path, hunk_index)
  local lifecycle = require("codediff.ui.lifecycle")
  local ok = vim.wait(10000, function()
    if lifecycle.is_render_pending(tabpage) then
      return false
    end

    local explorer = lifecycle.get_explorer(tabpage)
    local session = lifecycle.get_session(tabpage)
    if not explorer or not session or explorer.current_file_path ~= file_path then
      return false
    end

    local changes = session.stored_diff_result and session.stored_diff_result.changes or nil
    if not changes or #changes < hunk_index then
      return false
    end

    local cursor = vim.api.nvim_win_get_cursor(session.modified_win)[1]
    return cursor == changes[hunk_index].modified.start_line
  end, 50)

  assert.is_true(ok, string.format("Expected %s hunk %d to be active", file_path, hunk_index))
end

describe("cross-file hunk navigation", function()
  local repo
  local original_cwd
  local original_get_file_content

  before_each(function()
    original_cwd = vim.fn.getcwd()
    require("codediff").setup({
      diff = {
        layout = "inline",
        jump_to_first_change = true,
      },
    })
    setup_command()

    local git = require("codediff.core.git")
    original_get_file_content = git.get_file_content
    git.get_file_content = function(revision, git_root, file_path, callback)
      vim.defer_fn(function()
        original_get_file_content(revision, git_root, file_path, callback)
      end, 80)
    end
  end)

  after_each(function()
    local git = require("codediff.core.git")
    git.get_file_content = original_get_file_content
    pcall(function()
      vim.cmd("tabnew")
      vim.cmd("tabonly")
    end)
    vim.fn.chdir(original_cwd)
    vim.wait(150)
    if repo then
      repo.cleanup()
      repo = nil
    end
  end)

  it("queues next hunk-or-file until the newly selected file finishes rendering", function()
    repo = create_repo({
      { name = "a.txt", prefix = "A", hunks = { 10 } },
      { name = "b.txt", prefix = "B", hunks = { 2, 10, 18 } },
    })

    local tabpage, _, explorer = open_codediff_and_wait(repo, "a.txt")
    local navigation = require("codediff.ui.view.navigation")

    assert.equals("a.txt", explorer.current_file_path)
    focus_modified_window(tabpage)

    navigation.next_file()
    navigation.next_hunk_or_file()

    wait_for_file_and_hunk(tabpage, "b.txt", 2)
  end)

  it("drops stale queued navigation and applies it only to the latest selected file", function()
    repo = create_repo({
      { name = "a.txt", prefix = "A", hunks = { 10 } },
      { name = "b.txt", prefix = "B", hunks = { 10 } },
      { name = "c.txt", prefix = "C", hunks = { 2, 10, 18 } },
    })

    local tabpage, _, explorer = open_codediff_and_wait(repo, "a.txt")
    local navigation = require("codediff.ui.view.navigation")

    assert.equals("a.txt", explorer.current_file_path)
    focus_modified_window(tabpage)

    navigation.next_file()
    navigation.next_file()
    navigation.next_hunk_or_file()

    wait_for_file_and_hunk(tabpage, "c.txt", 2)
  end)
end)
