local spec_path = debug.getinfo(1, "S").source:sub(2)
local plugin_root = vim.fn.fnamemodify(spec_path, ":p:h:h:h")
vim.opt.rtp:prepend(plugin_root)
package.path = package.path .. ";" .. plugin_root .. "/lua/?.lua;" .. plugin_root .. "/lua/?/init.lua"

local h = dofile("tests/helpers.lua")

h.ensure_plugin_loaded()
dofile(plugin_root .. "/plugin/codediff_review.lua")

local function open_review(repo, filename, command)
  filename = filename or "file1.txt"
  vim.fn.chdir(repo.dir)
  vim.cmd("edit " .. repo.path(filename))
  vim.cmd(command or "CodeReview")

  local lifecycle = require("codediff.ui.lifecycle")
  local tabpage
  local ready = vim.wait(10000, function()
    for _, tp in ipairs(vim.api.nvim_list_tabpages()) do
      local session = lifecycle.get_session(tp)
      if session and session.explorer and session.codediff_review_active then
        tabpage = tp
        return session.stored_diff_result ~= nil
      end
    end
    return false
  end, 100)

  assert.is_true(ready, "CodeReview should open a CodeDiff session")
  return tabpage
end

describe("codediff.review foundation", function()
  local repo
  local original_cwd

  before_each(function()
    require("codediff").setup({ diff = { layout = "inline" } })
    require("codediff.review").setup()
    original_cwd = vim.fn.getcwd()

    repo = h.create_temp_git_repo()
    repo.write_file("file1.txt", { "one", "two", "three" })
    repo.git("add file1.txt")
    repo.git('commit -m "initial"')
    repo.write_file("file1.txt", { "one changed", "two", "three" })
  end)

  after_each(function()
    pcall(function()
      vim.cmd("tabnew")
      vim.cmd("tabonly")
    end)
    pcall(vim.api.nvim_del_augroup_by_name, "codediff_review_test_markdown_wrap")
    vim.fn.chdir(original_cwd)
    vim.wait(150)
    if repo then
      repo.cleanup()
      repo = nil
    end
  end)

  it("opens review sessions and exports stored comments", function()
    open_review(repo)

    local store = require("codediff.review.store")
    local export = require("codediff.review.export")
    store.add("file1.txt", 1, "issue", "Needs work", nil, "new")

    local markdown = export.generate_markdown()
    assert.is_true(markdown:find("file1.txt:1", 1, true) ~= nil)
    assert.is_true(markdown:find("Needs work", 1, true) ~= nil)
  end)

  it("reports the active review session", function()
    local review = require("codediff.review")
    assert.is_false(review.is_active())

    local tabpage = open_review(repo)
    vim.api.nvim_set_current_tabpage(tabpage)
    local lifecycle, current_tabpage, session = review.current_session()

    assert.is_true(review.is_active())
    assert.is_not_nil(lifecycle)
    assert.equals(tabpage, current_tabpage)
    assert.is_not_nil(session)
  end)

  it("includes dirty files in merge-base working-tree reviews", function()
    repo.git("branch base")
    repo.write_file("file1.txt", { "committed branch change" })
    repo.git("add file1.txt")
    repo.git('commit -m "branch change"')
    repo.write_file("dirty.txt", { "untracked working-tree change" })

    vim.fn.chdir(repo.dir)
    vim.cmd("edit " .. repo.path("file1.txt"))
    require("codediff.review").open_merge_base("base", "WORKING")

    local lifecycle = require("codediff.ui.lifecycle")
    local tabpage
    local ready = vim.wait(10000, function()
      for _, candidate in ipairs(vim.api.nvim_list_tabpages()) do
        local session = lifecycle.get_session(candidate)
        if session and session.explorer and session.codediff_review_active and session.stored_diff_result then
          tabpage = candidate
          return true
        end
      end
      return false
    end, 50)
    assert.is_true(ready, "working-tree merge-base review should open")

    local session = lifecycle.get_session(tabpage)
    local files = require("codediff.ui.explorer.refresh").get_all_files(session.explorer.tree)
    local paths = vim.tbl_map(function(file)
      return file.data.path
    end, files)
    table.sort(paths)
    assert.same({ "dirty.txt", "file1.txt" }, paths)
  end)

  it("opens the first rendered file when the explorer uses tree view", function()
    repo.write_file("a-root.txt", { "original root" })
    repo.write_file("z-dir/nested.txt", { "original nested" })
    repo.git("add a-root.txt z-dir/nested.txt")
    repo.git('commit -m "add tree files"')
    repo.write_file("a-root.txt", { "changed root" })
    repo.write_file("z-dir/nested.txt", { "changed nested" })

    local config = require("codediff.config")
    local original_view_mode = config.options.explorer.view_mode
    config.options.explorer.view_mode = "tree"
    local tabpage = open_review(repo, "a-root.txt")
    config.options.explorer.view_mode = original_view_mode

    local session = require("codediff.ui.lifecycle").get_session(tabpage)
    local files = require("codediff.ui.explorer.refresh").get_all_files(session.explorer.tree)
    assert.equals("z-dir/nested.txt", files[1].data.path)
    assert.equals(files[1].data.path, session.explorer.current_file_path)
  end)

  it("preserves explorer keymaps when entering the file panel", function()
    local tabpage = open_review(repo)
    vim.api.nvim_set_current_tabpage(tabpage)
    local session = require("codediff.ui.lifecycle").get_session(tabpage)
    assert.is_not_nil(session)
    assert.is_not_nil(session.explorer)

    vim.api.nvim_set_current_win(session.explorer.winid)
    for key, expected_desc in pairs({
      i = "Toggle list/tree view",
      R = "Refresh explorer",
      S = "Stage all files",
    }) do
      local explorer_mapping = vim.fn.maparg(key, "n", false, true)
      assert.equals(expected_desc, explorer_mapping.desc)
    end

    vim.api.nvim_set_current_win(session.modified_win)
    local review_mapping = vim.fn.maparg("i", "n", false, true)
    assert.equals("Add comment (pick type)", review_mapping.desc)
  end)

  it("keeps same-file definitions inside the modified diff pane", function()
    repo.write_file("file1.txt", { "callNewFunction()", "", "function callNewFunction() {}" })
    repo.git("add file1.txt")
    repo.git('commit -m "add new function"')

    local tabpage = open_review(repo, "file1.txt", "Review commits HEAD^ HEAD")
    vim.api.nvim_set_current_tabpage(tabpage)
    local lifecycle = require("codediff.ui.lifecycle")
    local session = lifecycle.get_session(tabpage)
    vim.api.nvim_set_current_win(session.modified_win)
    vim.api.nvim_win_set_cursor(session.modified_win, { 1, 0 })

    local mapping = vim.fn.maparg("gd", "n", false, true)
    assert.equals("Goto Definition (review proxy)", mapping.desc)

    local get_clients = vim.lsp.get_clients
    local request_sync = vim.lsp.buf_request_sync
    vim.lsp.get_clients = function(opts)
      return opts and opts.bufnr == 0 and {} or { { id = 999, name = "test-lsp" } }
    end
    vim.lsp.buf_request_sync = function()
      return {
        [999] = {
          result = {
            uri = vim.uri_from_fname(repo.path("file1.txt")),
            range = { start = { line = 2, character = 9 }, ["end"] = { line = 2, character = 24 } },
          },
        },
      }
    end

    local ok, err = pcall(mapping.callback)
    vim.lsp.get_clients = get_clients
    vim.lsp.buf_request_sync = request_sync
    assert.is_true(ok, err)

    assert.equals(session.modified_bufnr, vim.api.nvim_win_get_buf(session.modified_win))
    assert.equals(session.modified_bufnr, vim.api.nvim_get_current_buf())
    assert.same({ 3, 9 }, vim.api.nvim_win_get_cursor(session.modified_win))
  end)

  it("routes definitions from working-tree diff buffers with an attached LSP", function()
    repo.write_file("file1.txt", { "callNewFunction()", "", "function callNewFunction() {}" })

    local tabpage = open_review(repo)
    vim.api.nvim_set_current_tabpage(tabpage)
    local session = require("codediff.ui.lifecycle").get_session(tabpage)
    vim.api.nvim_set_current_win(session.modified_win)
    vim.api.nvim_win_set_cursor(session.modified_win, { 1, 0 })

    local mapping = vim.fn.maparg("gd", "n", false, true)
    local get_clients = vim.lsp.get_clients
    local request_sync = vim.lsp.buf_request_sync
    vim.lsp.get_clients = function()
      return { { id = 999, name = "test-lsp" } }
    end
    vim.lsp.buf_request_sync = function()
      return {
        [999] = {
          result = {
            uri = vim.uri_from_fname(repo.path("file1.txt")),
            range = { start = { line = 2, character = 9 }, ["end"] = { line = 2, character = 24 } },
          },
        },
      }
    end

    local ok, err = pcall(mapping.callback)
    vim.lsp.get_clients = get_clients
    vim.lsp.buf_request_sync = request_sync
    assert.is_true(ok, err)

    assert.equals(session.modified_bufnr, vim.api.nvim_win_get_buf(session.modified_win))
    assert.same({ 3, 9 }, vim.api.nvim_win_get_cursor(session.modified_win))
  end)

  it("follows TypeScript import bindings to their source definition", function()
    repo.write_file("file1.ts", { "old call" })
    repo.write_file("file2.ts", { "old definition" })
    repo.git("add file1.ts file2.ts")
    repo.git('commit -m "add TypeScript files"')
    repo.write_file("file1.ts", { 'import { callNewFunction } from "./file2"', "callNewFunction()" })
    repo.write_file("file2.ts", { "one", "two", "function callNewFunction() {}" })
    repo.git("add file1.ts file2.ts")
    repo.git('commit -m "add imported function"')

    local tabpage = open_review(repo, "file1.ts", "Review commits HEAD^ HEAD")
    vim.api.nvim_set_current_tabpage(tabpage)
    local lifecycle = require("codediff.ui.lifecycle")
    local session = lifecycle.get_session(tabpage)
    vim.api.nvim_set_current_win(session.modified_win)
    vim.api.nvim_win_set_cursor(session.modified_win, { 2, 0 })

    local mapping = vim.fn.maparg("gd", "n", false, true)
    local get_clients = vim.lsp.get_clients
    local request_sync = vim.lsp.buf_request_sync
    local request_count = 0
    vim.lsp.get_clients = function(opts)
      return opts and opts.bufnr == 0 and {} or { { id = 999, name = "vtsls" } }
    end
    vim.lsp.buf_request_sync = function()
      request_count = request_count + 1
      local filename = request_count == 1 and "file1.ts" or "file2.ts"
      local line = request_count == 1 and 0 or 2
      return {
        [999] = {
          result = {
            targetUri = vim.uri_from_fname(repo.path(filename)),
            targetSelectionRange = {
              start = { line = line, character = 9 },
              ["end"] = { line = line, character = 24 },
            },
          },
        },
      }
    end

    local ok, err = pcall(mapping.callback)
    vim.lsp.get_clients = get_clients
    vim.lsp.buf_request_sync = request_sync
    assert.is_true(ok, err)

    local jumped = vim.wait(5000, function()
      session = lifecycle.get_session(tabpage)
      return session
        and session.explorer.current_file_path == "file2.ts"
        and session.modified_path == "file2.ts"
        and vim.deep_equal(vim.api.nvim_win_get_cursor(session.modified_win), { 3, 9 })
    end, 20)
    assert.is_true(jumped, "one gd should follow the import binding to file2.ts")
    assert.equals(2, request_count)
  end)

  it("routes cross-file definitions through the review explorer", function()
    repo.write_file("file2.txt", { "old definition" })
    repo.git("add file2.txt")
    repo.git('commit -m "add second file"')
    repo.write_file("file1.txt", { "callNewFunction()", "two", "three" })
    repo.write_file("file2.txt", { "one", "two", "function callNewFunction() {}" })
    repo.git("add file1.txt file2.txt")
    repo.git('commit -m "add cross-file function"')

    local tabpage = open_review(repo, "file1.txt", "Review commits HEAD^ HEAD")
    vim.api.nvim_set_current_tabpage(tabpage)
    local lifecycle = require("codediff.ui.lifecycle")
    local session = lifecycle.get_session(tabpage)
    assert.equals("file1.txt", session.explorer.current_file_path)
    vim.api.nvim_set_current_win(session.modified_win)
    vim.api.nvim_win_set_cursor(session.modified_win, { 1, 0 })

    local mapping = vim.fn.maparg("gd", "n", false, true)
    local get_clients = vim.lsp.get_clients
    local request_sync = vim.lsp.buf_request_sync
    vim.lsp.get_clients = function(opts)
      return opts and opts.bufnr == 0 and {} or { { id = 999, name = "test-lsp" } }
    end
    vim.lsp.buf_request_sync = function()
      return {
        [999] = {
          result = {
            uri = vim.uri_from_fname(repo.path("file2.txt")),
            range = { start = { line = 2, character = 9 }, ["end"] = { line = 2, character = 24 } },
          },
        },
      }
    end

    local ok, err = pcall(mapping.callback)
    vim.lsp.get_clients = get_clients
    vim.lsp.buf_request_sync = request_sync
    assert.is_true(ok, err)

    local jumped = vim.wait(5000, function()
      session = lifecycle.get_session(tabpage)
      if not session or session.explorer.current_file_path ~= "file2.txt" or session.modified_path ~= "file2.txt" then
        return false
      end
      return vim.api.nvim_win_get_buf(session.modified_win) == session.modified_bufnr and vim.deep_equal(vim.api.nvim_win_get_cursor(session.modified_win), { 3, 9 })
    end, 20)
    assert.is_true(jumped, "definition should render and jump to file2.txt inside the review")
    assert.equals(session.modified_bufnr, vim.api.nvim_get_current_buf())
  end)

  it("opens unchanged definitions outside the managed diff panes", function()
    repo.write_file("library.txt", { "one", "function libraryFunction() {}" })
    repo.git("add library.txt")
    repo.git('commit -m "add unchanged library"')
    repo.write_file("file1.txt", { "libraryFunction()", "two", "three" })
    repo.git("add file1.txt")
    repo.git('commit -m "call library function"')

    local tabpage = open_review(repo, "file1.txt", "Review commits HEAD^ HEAD")
    vim.api.nvim_set_current_tabpage(tabpage)
    local lifecycle = require("codediff.ui.lifecycle")
    local session = lifecycle.get_session(tabpage)
    vim.api.nvim_set_current_win(session.modified_win)
    vim.api.nvim_win_set_cursor(session.modified_win, { 1, 0 })

    local mapping = vim.fn.maparg("gd", "n", false, true)
    local get_clients = vim.lsp.get_clients
    local request_sync = vim.lsp.buf_request_sync
    vim.lsp.get_clients = function(opts)
      return opts and opts.bufnr == 0 and {} or { { id = 999, name = "test-lsp" } }
    end
    vim.lsp.buf_request_sync = function()
      return {
        [999] = {
          result = {
            uri = vim.uri_from_fname(repo.path("library.txt")),
            range = { start = { line = 1, character = 9 }, ["end"] = { line = 1, character = 24 } },
          },
        },
      }
    end

    local ok, err = pcall(mapping.callback)
    vim.lsp.get_clients = get_clients
    vim.lsp.buf_request_sync = request_sync
    assert.is_true(ok, err)

    assert.not_equals(tabpage, vim.api.nvim_get_current_tabpage())
    assert.equals(repo.path("library.txt"), vim.api.nvim_buf_get_name(0))
    assert.same({ 2, 9 }, vim.api.nvim_win_get_cursor(0))
    assert.equals(session.modified_bufnr, vim.api.nvim_win_get_buf(session.modified_win))
    assert.is_true(session.codediff_review_active)
  end)

  it("opens multiple-definition results outside the managed diff panes", function()
    repo.write_file("file1.txt", { "ambiguousFunction()", "", "function ambiguousFunction() {}" })
    repo.git("add file1.txt")
    repo.git('commit -m "add ambiguous function"')

    local tabpage = open_review(repo, "file1.txt", "Review commits HEAD^ HEAD")
    vim.api.nvim_set_current_tabpage(tabpage)
    local session = require("codediff.ui.lifecycle").get_session(tabpage)
    vim.api.nvim_set_current_win(session.modified_win)
    vim.api.nvim_win_set_cursor(session.modified_win, { 1, 0 })

    local mapping = vim.fn.maparg("gd", "n", false, true)
    local get_clients = vim.lsp.get_clients
    local request_sync = vim.lsp.buf_request_sync
    vim.lsp.get_clients = function(opts)
      return opts and opts.bufnr == 0 and {} or { { id = 999, name = "test-lsp" } }
    end
    vim.lsp.buf_request_sync = function()
      return {
        [999] = {
          result = {
            {
              uri = vim.uri_from_fname(repo.path("file1.txt")),
              range = { start = { line = 2, character = 9 }, ["end"] = { line = 2, character = 24 } },
            },
            {
              uri = vim.uri_from_fname(repo.path("file1.txt")),
              range = { start = { line = 0, character = 0 }, ["end"] = { line = 0, character = 17 } },
            },
          },
        },
      }
    end

    local ok, err = pcall(mapping.callback)
    vim.lsp.get_clients = get_clients
    vim.lsp.buf_request_sync = request_sync
    assert.is_true(ok, err)

    assert.not_equals(tabpage, vim.api.nvim_get_current_tabpage())
    assert.equals(2, #vim.fn.getqflist())
    assert.equals(session.modified_bufnr, vim.api.nvim_win_get_buf(session.modified_win))
  end)

  it("inherits markdown wrapping without overriding manual toggles", function()
    repo.git("restore file1.txt")
    repo.write_file("README.md", { "# Before", "", "A long paragraph before the change." })
    repo.git("add README.md")
    repo.git('commit -m "add markdown"')
    repo.write_file("README.md", { "# After", "", "A long paragraph after the change." })

    local group = vim.api.nvim_create_augroup("codediff_review_test_markdown_wrap", { clear = true })
    vim.api.nvim_create_autocmd("FileType", {
      group = group,
      pattern = "markdown",
      callback = function()
        vim.opt_local.wrap = true
        vim.opt_local.linebreak = true
        vim.opt_local.breakindent = true
      end,
    })

    assert.is_true(vim.filetype.get_option("markdown", "wrap"))

    local tabpage = open_review(repo, "README.md")
    vim.api.nvim_set_current_tabpage(tabpage)
    local session = require("codediff.ui.lifecycle").get_session(tabpage)
    assert.is_not_nil(session)
    vim.api.nvim_set_current_win(session.modified_win)

    local configured = vim.wait(1000, function()
      local ft = vim.b[session.modified_bufnr].codediff_filetype or vim.bo[session.modified_bufnr].filetype
      return ft == "markdown" and vim.wo[session.modified_win].wrap
    end, 20)
    assert.is_true(configured, "Markdown review pane should inherit its filetype wrap setting")
    assert.is_true(vim.wo[session.modified_win].linebreak)
    assert.is_true(vim.wo[session.modified_win].breakindent)

    vim.wo[session.modified_win].wrap = false
    vim.api.nvim_exec_autocmds("CursorMoved", {})
    assert.is_false(vim.wo[session.modified_win].wrap, "CursorMoved should preserve disabled wrapping")

    vim.wo[session.modified_win].wrap = true
    vim.api.nvim_exec_autocmds("CursorMoved", {})
    assert.is_true(vim.wo[session.modified_win].wrap, "CursorMoved should preserve enabled wrapping")

    vim.api.nvim_del_augroup_by_id(group)
  end)

  it("supports no-op close outside review sessions", function()
    local review = require("codediff.review")
    assert.is_false(review.close({ noop_if_inactive = true, preview = false }))
  end)

  it("exports to clipboard only when comments exist", function()
    local review = require("codediff.review")
    open_review(repo)

    assert.is_false(review.export_clipboard({ notify_empty = false }))

    local store = require("codediff.review.store")
    store.add("file1.txt", 1, "issue", "Needs work", nil, "new")
    assert.is_true(review.export_clipboard({ preview = false }))
  end)

  it("can clear comments while closing", function()
    local tabpage = open_review(repo)
    vim.api.nvim_set_current_tabpage(tabpage)
    local review = require("codediff.review")
    local store = require("codediff.review.store")
    store.add("file1.txt", 1, "issue", "Needs work", nil, "new")
    assert.equals(1, review.count())

    review.close({ clear = true, export = false, preview = false })

    assert.equals(0, review.count())
  end)

  it("restores buffer editability when a review session is cleaned up", function()
    local tabpage = open_review(repo)
    local lifecycle = require("codediff.ui.lifecycle")
    local session = lifecycle.get_session(tabpage)
    assert.is_not_nil(session)

    session.codediff_review_active = true
    require("codediff.review.hooks").on_session_created(tabpage)

    local modified_buf = session.modified_bufnr
    assert.is_true(vim.api.nvim_buf_is_valid(modified_buf))
    assert.is_false(vim.bo[modified_buf].modifiable)
    assert.is_true(vim.bo[modified_buf].readonly)

    lifecycle.cleanup(tabpage)

    assert.is_true(vim.api.nvim_buf_is_valid(modified_buf))
    assert.is_true(vim.bo[modified_buf].modifiable)
    assert.is_false(vim.bo[modified_buf].readonly)
  end)

  it("closes review cleanup without tabclose errors in the last tab", function()
    local tabpage = open_review(repo)
    vim.api.nvim_set_current_tabpage(tabpage)
    vim.cmd("tabonly")
    assert.equals(1, #vim.api.nvim_list_tabpages())

    local ok, err = pcall(function()
      require("codediff.review").close({ preview = false })
    end)

    assert.is_true(ok, err)
    assert.equals(1, #vim.api.nvim_list_tabpages())
    assert.is_nil(require("codediff.ui.lifecycle").get_session(vim.api.nvim_get_current_tabpage()))
  end)

  it("does not use a stale tab count after cleanup autocmds", function()
    local tabpage = open_review(repo)
    vim.api.nvim_set_current_tabpage(tabpage)
    vim.cmd("tabnew")
    vim.api.nvim_set_current_tabpage(tabpage)
    assert.is_true(#vim.api.nvim_list_tabpages() > 1)

    local group = vim.api.nvim_create_augroup("codediff_review_test_tabclose_race", { clear = true })
    vim.api.nvim_create_autocmd("User", {
      group = group,
      pattern = "CodeDiffClose",
      once = true,
      callback = function()
        vim.cmd("tabonly")
      end,
    })

    local ok, err = pcall(function()
      require("codediff.review").close({ preview = false })
    end)

    pcall(vim.api.nvim_del_augroup_by_id, group)
    assert.is_true(ok, err)
    assert.equals(1, #vim.api.nvim_list_tabpages())
  end)

  it("does not error when tabclose is blocked by unsaved changes", function()
    local tabpage = open_review(repo)
    vim.api.nvim_set_current_tabpage(tabpage)
    vim.cmd("tabnew")
    vim.api.nvim_set_current_tabpage(tabpage)

    local session = require("codediff.ui.lifecycle").get_session(tabpage)
    assert.is_not_nil(session)
    local modified_buf = session.modified_bufnr
    assert.is_true(vim.api.nvim_buf_is_valid(modified_buf))
    vim.api.nvim_set_option_value("modifiable", true, { buf = modified_buf })
    vim.api.nvim_set_option_value("readonly", false, { buf = modified_buf })
    vim.api.nvim_buf_set_lines(modified_buf, 0, 1, false, { "unsaved review edit" })
    vim.api.nvim_set_option_value("modified", true, { buf = modified_buf })

    local ok, err = pcall(function()
      require("codediff.review").close({ preview = false })
    end)

    assert.is_true(ok, err)
    assert.is_nil(require("codediff.ui.lifecycle").get_session(tabpage))
  end)
end)
