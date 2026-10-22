-- E2E Scenario: Validate history panel layout and content
return {
  setup = function(ctx, e2e)
    ctx.repo = e2e.create_temp_git_repo()
    ctx.repo.write_file("file.txt", { "version 1" })
    ctx.repo.git("add .")
    ctx.repo.git("commit -m 'first commit'")
    ctx.repo.write_file("file.txt", { "version 2" })
    ctx.repo.git("add .")
    ctx.repo.git("commit -m 'second commit'")
    ctx.repo.write_file("file.txt", { "version 3" })
    ctx.repo.git("add .")
    ctx.repo.git("commit -m 'third commit'")
    vim.cmd("edit " .. ctx.repo.path("file.txt"))
  end,

  run = function(ctx, e2e)
    e2e.exec("CodeDiff history")
    vim.wait(5000, function()
      return e2e.find_window_by_filetype("codediff-history") ~= nil
    end)

    -- Find history panel
    ctx.history_win, ctx.history_buf = e2e.find_window_by_filetype("codediff-history")
    if ctx.history_buf then
      ctx.history_content = e2e.get_buffer_content(ctx.history_buf)
      ctx.history_lines = e2e.get_buffer_lines(ctx.history_buf)
    end

    -- Check layout - history should be at bottom
    if ctx.history_win then
      local win_pos = vim.api.nvim_win_get_position(ctx.history_win)
      ctx.history_row = win_pos[1]
      ctx.history_col = win_pos[2]
    end

    ctx.all_windows = e2e.get_all_windows()
  end,

  validate = function(ctx, e2e)
    local ok = true

    -- History panel should exist
    ok = ok and e2e.assert_true(ctx.history_win ~= nil, "History window should exist")
    if not ctx.history_win then
      return false
    end

    -- History should have content with commit messages
    ok = ok and e2e.assert_true(#ctx.history_lines > 0, "History should have lines")
    ok = ok and e2e.assert_contains(ctx.history_content, "Commit History", "Should show Commit History title")

    -- History should be at the bottom (higher row than diff panes)
    for _, win_info in ipairs(ctx.all_windows) do
      if win_info.winid ~= ctx.history_win then
        local other_row = vim.api.nvim_win_get_position(win_info.winid)[1]
        ok = ok and e2e.assert_true(ctx.history_row >= other_row, "History should be at bottom (row " .. ctx.history_row .. " vs other " .. other_row .. ")")
      end
    end

    return ok
  end,

  cleanup = function(ctx, e2e)
    if ctx.repo then
      ctx.repo.cleanup()
    end
  end,
}
