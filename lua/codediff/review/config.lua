local M = {}

---@class CodeDiffReviewConfig
---@field storage_dir string?
---@field comment_types table<string, CodeDiffReviewCommentType>
---@field keymaps CodeDiffReviewKeymaps
---@field codediff CodeDiffReviewCodeDiffConfig
---@field popup CodeDiffReviewPopupConfig
---@field export CodeDiffReviewExportConfig
---@field github CodeDiffReviewGithubConfig

---@class CodeDiffReviewCommentType
---@field key string
---@field name string
---@field icon string
---@field hl string
---@field line_hl string

---@class CodeDiffReviewKeymaps
---@field add_comment string|false
---@field add_note string|false
---@field add_suggestion string|false
---@field add_issue string|false
---@field add_praise string|false
---@field delete_comment string|false
---@field edit_comment string|false
---@field next_comment string|false
---@field prev_comment string|false
---@field list_comments string|false
---@field export_clipboard string|false
---@field send_sidekick string|false
---@field clear_comments string|false
---@field close string|false
---@field toggle_readonly string|false
---@field next_file string|false
---@field prev_file string|false
---@field toggle_file_panel string|false
---@field readonly_add string|false
---@field readonly_delete string|false
---@field readonly_edit string|false
---@field readonly_add_file string|false
---@field add_file_comment string|false
---@field popup_submit string|false
---@field popup_cancel string|false
---@field show_help string|false
---@field popup_cycle_type string|false

---@class CodeDiffReviewCodeDiffConfig
---@field readonly boolean
---@field focus_modified_pane boolean

---@class CodeDiffReviewPopupConfig
---@field show_type_selector boolean

---@class CodeDiffReviewExportConfig
---@field format "compact"|"detailed"

---@class CodeDiffReviewGithubConfig
---@field remote string
---@field pr_limit number

---@type CodeDiffReviewConfig
M.defaults = {
  storage_dir = nil,
  comment_types = {
    note = { key = "n", name = "Note", icon = "📝", hl = "ReviewNote", line_hl = "ReviewNoteLine" },
    suggestion = {
      key = "s",
      name = "Suggestion",
      icon = "💡",
      hl = "ReviewSuggestion",
      line_hl = "ReviewSuggestionLine",
    },
    issue = { key = "i", name = "Issue", icon = "⚠️", hl = "ReviewIssue", line_hl = "ReviewIssueLine" },
    praise = { key = "p", name = "Praise", icon = "✨", hl = "ReviewPraise", line_hl = "ReviewPraiseLine" },
  },
  keymaps = {
    add_comment = "<localleader>cc",
    add_note = "<localleader>cn",
    add_suggestion = "<localleader>cs",
    add_issue = "<localleader>ci",
    add_praise = "<localleader>cp",
    add_file_comment = "<localleader>cf",
    delete_comment = "<localleader>cd",
    edit_comment = "<localleader>ce",
    next_comment = "]n",
    prev_comment = "[n",
    next_file = "<Tab>",
    prev_file = "<S-Tab>",
    toggle_file_panel = "f",
    list_comments = "c",
    export_clipboard = "C",
    send_sidekick = "S",
    clear_comments = "<C-r>",
    close = "q",
    toggle_readonly = "R",
    readonly_add = "i",
    readonly_delete = "d",
    readonly_edit = "e",
    readonly_add_file = "F",
    show_help = "?",
    popup_submit = "<C-s>",
    popup_cancel = "q",
    popup_cycle_type = "<Tab>",
  },
  codediff = {
    readonly = true,
    focus_modified_pane = true,
  },
  popup = {
    show_type_selector = true,
  },
  export = {
    format = "detailed",
  },
  github = {
    remote = "origin",
    pr_limit = 100,
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
