-- Test explorer staging/unstaging workflow with virtual files
-- This tests buffer management during file switching in explorer mode

local h = dofile('tests/helpers.lua')

-- Ensure plugin is loaded (needed for PlenaryBustedFile subprocess)
h.ensure_plugin_loaded()

describe("Explorer Buffer Management", function()
  local repo

  before_each(function()
    -- Create a temp git repo using helper
    repo = h.create_temp_git_repo()
    
    -- Create initial file and commit
    repo.write_file('test.txt', {'line 1', 'line 2', 'line 3'})
    repo.git('add test.txt')
    repo.git('commit -m initial')
  end)

  after_each(function()
    -- Close all extra tabs before cleanup
    h.close_extra_tabs()
    
    -- Cleanup temp directory
    if repo then
      repo.cleanup()
    end
  end)

  it("should parse virtual file URLs correctly", function()
    local virtual_file = require('codediff.core.virtual_file')

    -- Use the actual repo.dir for cross-platform compatibility
    local normalized_dir = h.normalize_path(repo.dir)

    -- Test HEAD revision
    local url1 = virtual_file.create_url(repo.dir, "HEAD", "file.txt")
    local g1, c1, f1 = virtual_file.parse_url(url1)
    assert.equals(normalized_dir, g1)
    assert.equals("HEAD", c1)
    assert.equals("file.txt", f1)

    -- Test :0 (staged) revision
    local url2 = virtual_file.create_url(repo.dir, ":0", "file.txt")
    local g2, c2, f2 = virtual_file.parse_url(url2)
    assert.equals(normalized_dir, g2)
    assert.equals(":0", c2)
    assert.equals("file.txt", f2)

    -- Test SHA hash
    local url3 = virtual_file.create_url(repo.dir, "abc123def456", "file.txt")
    local g3, c3, f3 = virtual_file.parse_url(url3)
    assert.equals(normalized_dir, g3)
    assert.equals("abc123def456", c3)
    assert.equals("file.txt", f3)
  end)

  it("should load virtual file content via BufReadCmd", function()
    local virtual_file = require('codediff.core.virtual_file')

    -- Listen for the loaded event
    local event_fired = false
    local event_buf = nil
    vim.api.nvim_create_autocmd('User', {
      pattern = 'CodeDiffVirtualFileLoaded',
      callback = function(args)
        event_fired = true
        event_buf = args.data and args.data.buf
      end
    })

    -- Create and edit a virtual file URL
    local url = virtual_file.create_url(repo.dir, ':0', 'test.txt')
    vim.cmd('edit! ' .. vim.fn.fnameescape(url))
    local buf = vim.api.nvim_get_current_buf()

    -- Wait for async loading to complete
    local ok = vim.wait(5000, function() return event_fired end, 50)

    assert.is_true(ok, "Event should fire within timeout")
    assert.is_true(event_fired, "CodeDiffVirtualFileLoaded should fire")
    assert.equals(buf, event_buf, "Event should report correct buffer")

    -- Verify buffer content matches git content
    local content = h.get_buffer_content(buf)
    assert.is_not_nil(content, "Buffer should have content")
    h.assert_contains(content, "line 1", "Should contain file content")
  end)

  it("should refresh staged content when index changes", function()
    -- This tests the full staging workflow:
    -- 1. Make change A -> validate in Changes
    -- 2. Stage change A -> validate in Staged Changes  
    -- 3. Make change B -> validate Changes has B, Staged has A
    -- 4. Stage change B -> validate Staged has A+B
    -- 5. Unstage file -> validate Changes has A+B
    
    local view = require('codediff.ui.view')
    local lifecycle = require('codediff.ui.lifecycle')

    -- Step 1: Make change A
    repo.write_file('test.txt', {'line 1', 'line 2', 'line 3', 'change A'})

    -- Create diff view for unstaged changes (index vs working)
    local config_changes = {
      mode = "standalone",
      git_root = repo.dir,
      original_path = 'test.txt',
      modified_path = repo.path('test.txt'),
      original_revision = ":0",
      modified_revision = "WORKING",
    }

    local result = view.create(config_changes, "text")
    assert.is_not_nil(result, "Should create diff view")

    local tabpage = vim.api.nvim_get_current_tabpage()

    -- Wait for session to be ready
    local ready = h.wait_for_session_ready(tabpage)
    assert.is_true(ready, "Diff session should be ready")

    -- Validate: Changes should show "change A" in modified buffer
    local _, modified_buf = lifecycle.get_buffers(tabpage)
    assert.is_not_nil(modified_buf, "Modified buffer should exist")
    local content = h.get_buffer_content(modified_buf)
    assert.is_not_nil(content, "Content should not be nil")
    h.assert_contains(content, "change A", "Changes should show change A")

    -- Step 2: Stage change A
    repo.git("add test.txt")

    -- Switch to staged view (HEAD vs index)
    local config_staged = {
      mode = "standalone",
      git_root = repo.dir,
      original_path = 'test.txt',
      modified_path = 'test.txt',
      original_revision = "HEAD",
      modified_revision = ":0",
    }

    view.update(tabpage, config_staged, false)
    ready = h.wait_for_session_ready(tabpage)
    assert.is_true(ready, "Session should be ready after update")

    -- Validate: Staged should show "change A"
    _, modified_buf = lifecycle.get_buffers(tabpage)
    content = h.get_buffer_content(modified_buf)
    h.assert_contains(content, "change A", "Staged should show change A after staging")

    -- Step 3: Make change B (while A is staged)
    repo.write_file('test.txt', {'line 1', 'line 2', 'line 3', 'change A', 'change B'})

    -- Switch back to Changes view (index vs working)
    view.update(tabpage, config_changes, false)
    ready = h.wait_for_session_ready(tabpage)

    -- Validate: Changes should show "change B" (the new unstaged change)
    _, modified_buf = lifecycle.get_buffers(tabpage)
    content = h.get_buffer_content(modified_buf)
    assert.is_not_nil(content, "Step 3 content should not be nil")
    h.assert_contains(content, "change B", "Changes should show change B")

    -- Switch to Staged view - should still show only "change A"
    view.update(tabpage, config_staged, false)
    ready = h.wait_for_session_ready(tabpage)
    assert.is_true(ready, "Session should be ready after switching to staged view")

    _, modified_buf = lifecycle.get_buffers(tabpage)
    -- Wait for buffer content to actually contain expected text
    local content_ready = h.wait_for_buffer_content(modified_buf, "change A", 5000)
    assert.is_true(content_ready, "Staged buffer should contain 'change A'")
    content = h.get_buffer_content(modified_buf)
    h.assert_contains(content, "change A", "Staged should still show change A")

    -- Step 4: Stage change B
    repo.git("add test.txt")

    -- Refresh staged view
    view.update(tabpage, config_staged, false)
    ready = h.wait_for_session_ready(tabpage)
    assert.is_true(ready, "Session should be ready after step 4 update")

    _, modified_buf = lifecycle.get_buffers(tabpage)
    content = h.get_buffer_content(modified_buf)
    h.assert_contains(content, "change A", "Staged should show change A after staging B")
    h.assert_contains(content, "change B", "Staged should show change B after staging B")

    -- Step 5: Unstage file
    repo.git("reset HEAD test.txt")

    -- Switch to Changes view - should now show both A and B
    view.update(tabpage, config_changes, false)
    ready = h.wait_for_session_ready(tabpage)

    _, modified_buf = lifecycle.get_buffers(tabpage)
    content = h.get_buffer_content(modified_buf)
    h.assert_contains(content, "change A", "Changes should show change A after unstage")
    h.assert_contains(content, "change B", "Changes should show change B after unstage")
  end)
end)
