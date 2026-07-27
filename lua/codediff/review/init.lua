local M = {}

local config = require("codediff.review.config")
local highlights = require("codediff.review.highlights")
local hooks = require("codediff.review.hooks")
local keymaps = require("codediff.review.keymaps")
local storage = require("codediff.review.storage")
local store = require("codediff.review.store")
local export = require("codediff.review.export")
local comments = require("codediff.review.comments")

local initialized = false
local augroup = nil

---@param opts? CodeDiffReviewConfig
function M.setup(opts)
  config.setup(opts)
  if initialized then
    return
  end

  highlights.setup()
  augroup = vim.api.nvim_create_augroup("codediff_review", { clear = true })

  vim.api.nvim_create_autocmd("TabEnter", {
    group = augroup,
    callback = function()
      vim.defer_fn(function()
        M._check_codediff_session()
      end, 100)
    end,
  })

  vim.api.nvim_create_autocmd("TabClosed", {
    group = augroup,
    callback = function()
      hooks.on_session_closed()
    end,
  })

  vim.api.nvim_create_autocmd("User", {
    group = augroup,
    pattern = { "CodeDiffOpen", "CodeDiffRender" },
    callback = function()
      vim.defer_fn(function()
        M._check_codediff_session()
      end, 100)
    end,
  })

  vim.api.nvim_create_autocmd("User", {
    group = augroup,
    pattern = "CodeDiffClose",
    callback = function()
      hooks.on_session_closed()
    end,
  })

  initialized = true
end

function M._check_codediff_session()
  local ok, lifecycle = pcall(require, "codediff.ui.lifecycle")
  if not ok then
    return
  end

  local tabpage = vim.api.nvim_get_current_tabpage()
  local sess = lifecycle.get_session(tabpage)
  if not sess or not sess.codediff_review_active then
    return
  end

  hooks.on_session_created(tabpage)
  keymaps.setup_keymaps(tabpage)
end

local function mark_review_session(tabpage)
  local ok, lifecycle = pcall(require, "codediff.ui.lifecycle")
  if not ok then
    return false
  end
  local sess = lifecycle.get_session(tabpage)
  if not sess then
    return false
  end
  sess.codediff_review_active = true
  return true
end

local function open_codediff_with_revisions(rev1, rev2)
  local ok = pcall(require, "codediff")
  if not ok then
    vim.notify("codediff.nvim is required", vim.log.levels.ERROR, { title = "codediff.review" })
    return
  end

  if rev1 and rev2 then
    storage.set_revisions(rev1, rev2)
  else
    storage.clear_revisions()
  end

  store.reset()
  store.load()

  if rev1 and rev2 then
    vim.cmd("CodeDiff " .. rev1 .. " " .. rev2)
  else
    vim.cmd("CodeDiff")
  end

  local attempts = 0
  local max_attempts = 10
  local function try_setup()
    attempts = attempts + 1
    local tabpage = vim.api.nvim_get_current_tabpage()
    if mark_review_session(tabpage) then
      M._check_codediff_session()
      return
    end
    if attempts < max_attempts then
      vim.defer_fn(try_setup, 100)
    end
  end
  vim.defer_fn(try_setup, 200)
end

function M.open()
  open_codediff_with_revisions(nil, nil)
end

function M.open_commits(rev1, rev2)
  if rev1 then
    open_codediff_with_revisions(rev2 and rev1 or (rev1 .. "^"), rev2 or rev1)
    return
  end
  local picker = require("codediff.review.picker")
  picker.open(function(r1, r2)
    open_codediff_with_revisions(r1, r2)
  end)
end

function M.open_merge_base(base_revision, target_revision)
  if not base_revision or base_revision == "" then
    vim.notify("A base revision is required", vim.log.levels.ERROR, { title = "codediff.review" })
    return false
  end

  target_revision = target_revision or "HEAD"
  local current_buf = vim.api.nvim_get_current_buf()
  local current_path = vim.api.nvim_buf_get_name(current_buf)
  if current_path == "" or vim.bo[current_buf].buftype ~= "" then
    current_path = vim.fn.getcwd()
  end

  local git = require("codediff.core.git")
  git.get_git_root(current_path, function(root_err, git_root)
    if root_err then
      vim.schedule(function()
        vim.notify(root_err, vim.log.levels.ERROR, { title = "codediff.review" })
      end)
      return
    end

    git.get_merge_base(base_revision, target_revision, git_root, function(merge_err, merge_base)
      if merge_err then
        vim.schedule(function()
          vim.notify(merge_err, vim.log.levels.ERROR, { title = "codediff.review" })
        end)
        return
      end
      vim.schedule(function()
        open_codediff_with_revisions(merge_base, target_revision)
      end)
    end)
  end)
  return true
end

function M.open_pr(number)
  require("codediff.review.pr").open(number)
end

function M.current_session()
  local ok, lifecycle = pcall(require, "codediff.ui.lifecycle")
  if not ok then
    return nil, nil, nil
  end

  local tabpage = vim.api.nvim_get_current_tabpage()
  local session = lifecycle.get_session(tabpage)
  if not session or not session.codediff_review_active then
    return nil, nil, nil
  end

  return lifecycle, tabpage, session
end

function M.is_active()
  return M.current_session() ~= nil
end

function M.export_clipboard(opts)
  opts = opts or {}
  if store.count() == 0 then
    if opts.notify_empty ~= false then
      vim.notify("No comments to export", vim.log.levels.WARN, { title = "codediff.review" })
    end
    return false
  end

  export.to_clipboard(opts.preview ~= false)
  return true
end

function M.close(opts)
  opts = opts or {}
  local lifecycle, tabpage = M.current_session()
  if opts.noop_if_inactive and not lifecycle then
    return false
  end

  if opts.export ~= false and store.count() > 0 then
    export.to_clipboard(opts.preview ~= false)
  end

  if lifecycle and lifecycle.get_session(tabpage) then
    lifecycle.cleanup(tabpage)
  end

  if opts.clear then
    store.clear()
    require("codediff.review.marks").clear_all()
  end

  if #vim.api.nvim_list_tabpages() > 1 then
    local close_ok, close_err = pcall(vim.cmd, "tabclose")
    local close_err_msg = tostring(close_err)
    local nonfatal_close_error = close_err_msg:find("E784", 1, true) or close_err_msg:find("E445", 1, true)
    if not close_ok and not nonfatal_close_error then
      error(close_err)
    end
  end
  hooks.on_session_closed()
  storage.clear_revisions()
  return true
end

function M.toggle(opts)
  if M.is_active() then
    return M.close(opts)
  end
  M.open()
  return true
end

function M.export(opts)
  export.to_clipboard(not opts or opts.preview ~= false)
end

function M.preview()
  export.preview()
end

function M.clear()
  store.clear()
  require("codediff.review.marks").clear_all()
  vim.notify("All comments cleared", vim.log.levels.INFO, { title = "codediff.review" })
end

function M.count()
  return store.count()
end

function M.add_note()
  comments.add_at_cursor("note")
end

function M.add_suggestion()
  comments.add_at_cursor("suggestion")
end

function M.add_issue()
  comments.add_at_cursor("issue")
end

function M.add_praise()
  comments.add_at_cursor("praise")
end

function M.list()
  comments.list()
end

function M.toggle_readonly()
  local cfg = config.get()
  cfg.codediff.readonly = not cfg.codediff.readonly

  local ok, lifecycle = pcall(require, "codediff.ui.lifecycle")
  if not ok then
    return
  end

  local tabpage = hooks.get_current_tabpage()
  if not tabpage then
    return
  end

  local orig_buf, mod_buf = lifecycle.get_buffers(tabpage)
  if orig_buf and vim.api.nvim_buf_is_valid(orig_buf) then
    vim.api.nvim_set_option_value("modifiable", not cfg.codediff.readonly, { buf = orig_buf })
    vim.api.nvim_set_option_value("readonly", cfg.codediff.readonly, { buf = orig_buf })
  end
  if mod_buf and vim.api.nvim_buf_is_valid(mod_buf) then
    vim.api.nvim_set_option_value("modifiable", not cfg.codediff.readonly, { buf = mod_buf })
    vim.api.nvim_set_option_value("readonly", cfg.codediff.readonly, { buf = mod_buf })
  end

  keymaps.clear_keymaps()
  keymaps.setup_keymaps(tabpage)
  local mode = cfg.codediff.readonly and "readonly" or "edit"
  vim.notify("Switched to " .. mode .. " mode", vim.log.levels.INFO, { title = "codediff.review" })
end

return M
