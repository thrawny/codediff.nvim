local spec_path = debug.getinfo(1, "S").source:sub(2)
local plugin_root = vim.fn.fnamemodify(spec_path, ":p:h:h:h")
vim.opt.rtp:prepend(plugin_root)
package.path = package.path .. ";" .. plugin_root .. "/lua/?.lua;" .. plugin_root .. "/lua/?/init.lua"

local h = dofile("tests/helpers.lua")

h.ensure_plugin_loaded()
dofile(plugin_root .. "/plugin/codediff_review.lua")

local function open_review(repo)
  vim.fn.chdir(repo.dir)
  vim.cmd("edit " .. repo.path("file1.txt"))
  vim.cmd("CodeReview")

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
