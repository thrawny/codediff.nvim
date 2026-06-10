local M = {}

local store = require("codediff.review.store")

local function notify(msg, level)
  vim.notify(msg, level, { title = "codediff.review" })
end

local function format_location(comment)
  local is_old = (comment.side or "new") == "old"
  if comment.line == 0 then
    return comment.file
  end

  if is_old then
    if comment.line_end and comment.line_end ~= comment.line then
      return string.format("%s:~%d-~%d", comment.file, comment.line, comment.line_end)
    end
    return string.format("%s:~%d", comment.file, comment.line)
  end

  if comment.line_end and comment.line_end ~= comment.line then
    return string.format("%s:%d-%d", comment.file, comment.line, comment.line_end)
  end
  return string.format("%s:%d", comment.file, comment.line)
end

---@return string
function M.generate_markdown()
  local all_comments = store.get_all()
  if #all_comments == 0 then
    return "No comments yet."
  end

  local cfg = require("codediff.review.config").get()
  if cfg.export.format == "compact" then
    local lines = {
      "Review comments:",
      "",
    }
    for i, comment in ipairs(all_comments) do
      table.insert(lines, string.format("%d. `%s` - %s", i, format_location(comment), comment.text))
    end
    return table.concat(lines, "\n")
  end

  local lines = {
    "I reviewed your code and have the following comments. Please address them.",
    "",
    "Comment types: ISSUE (problems to fix), SUGGESTION (improvements), NOTE (observations), PRAISE (positive feedback)",
    "Lines prefixed with ~ refer to the old (left) side of the diff.",
    "",
  }

  for i, comment in ipairs(all_comments) do
    local type_name = string.upper(comment.type)
    local location = format_location(comment)
    table.insert(lines, string.format("%d. **[%s]** `%s` - %s", i, type_name, location, comment.text))
  end

  return table.concat(lines, "\n")
end

function M.to_clipboard(show_preview)
  local markdown = M.generate_markdown()
  local count = store.count()
  if count == 0 then
    notify("No comments to export", vim.log.levels.WARN)
    return
  end

  vim.fn.setreg("+", markdown)
  vim.fn.setreg("*", markdown)

  if show_preview ~= false then
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(markdown, "\n"))
    vim.api.nvim_set_option_value("filetype", "markdown", { buf = buf })
    vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
    vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = buf })

    local prev_win = vim.api.nvim_get_current_win()
    local line_count = #vim.split(markdown, "\n")
    local height = math.min(line_count + 1, 15)
    vim.cmd("botright " .. height .. "split")
    vim.api.nvim_win_set_buf(0, buf)

    vim.keymap.set("n", "q", function()
      vim.api.nvim_win_close(0, true)
      if vim.api.nvim_win_is_valid(prev_win) then
        vim.api.nvim_set_current_win(prev_win)
      end
    end, { buffer = buf, nowait = true })
  end

  notify(string.format("Exported %d comment(s) to clipboard", count), vim.log.levels.INFO)
end

function M.preview()
  local markdown = M.generate_markdown()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(markdown, "\n"))
  vim.api.nvim_set_option_value("filetype", "markdown", { buf = buf })
  vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
  vim.cmd("vsplit")
  vim.api.nvim_win_set_buf(0, buf)
end

function M.to_sidekick()
  local ok, sidekick_cli = pcall(require, "sidekick.cli")
  if not ok then
    notify("sidekick.nvim not installed", vim.log.levels.ERROR)
    return
  end

  local count = store.count()
  if count == 0 then
    notify("No comments to send", vim.log.levels.WARN)
    return
  end

  local markdown = M.generate_markdown()
  sidekick_cli.send({ msg = markdown })
  notify(string.format("Sent %d comment(s) to sidekick", count), vim.log.levels.INFO)
end

return M
