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

function M.open_pr(number)
  require("codediff.review.pr").open(number)
end

function M.close(opts)
  if store.count() > 0 then
    export.to_clipboard(not opts or opts.preview ~= false)
  end

  local tabpage = vim.api.nvim_get_current_tabpage()
  local ok, lifecycle = pcall(require, "codediff.ui.lifecycle")
  if ok and lifecycle.get_session(tabpage) then
    lifecycle.cleanup(tabpage)
  end

  vim.cmd("tabclose")
  hooks.on_session_closed()
  storage.clear_revisions()
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
