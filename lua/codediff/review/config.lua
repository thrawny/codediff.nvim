local M = {}

---@class CodeDiffReviewConfig
---@field keymaps CodeDiffReviewKeymaps
---@field codediff CodeDiffReviewCodeDiffConfig
---@field github CodeDiffReviewGithubConfig
---@field jira CodeDiffReviewJiraConfig

---@class CodeDiffReviewKeymaps
---@field close string|false
---@field toggle_readonly string|false
---@field next_file string|false
---@field prev_file string|false
---@field toggle_file_panel string|false
---@field show_help string|false

---@class CodeDiffReviewCodeDiffConfig
---@field readonly boolean
---@field focus_modified_pane boolean

---@class CodeDiffReviewGithubConfig
---@field remote string
---@field pr_limit number

---@class CodeDiffReviewJiraConfig
---@field enabled boolean Show the Jira ticket in the review context group
---@field cmd string Jira CLI executable

---@type CodeDiffReviewConfig
M.defaults = {
  keymaps = {
    next_file = "<Tab>",
    prev_file = "<S-Tab>",
    toggle_file_panel = "f",
    close = "q",
    toggle_readonly = "R",
    show_help = "?",
  },
  codediff = {
    readonly = true,
    focus_modified_pane = true,
  },
  github = {
    remote = "origin",
    pr_limit = 100,
  },
  jira = {
    enabled = true,
    cmd = "jira",
  },
}

---@type CodeDiffReviewConfig
M.config = vim.deepcopy(M.defaults)

---@param opts? CodeDiffReviewConfig
function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", M.defaults, opts or {})
end

---@return CodeDiffReviewConfig
function M.get()
  return M.config
end

return M
