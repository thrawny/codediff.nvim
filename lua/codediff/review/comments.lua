local M = {}

local store = require("codediff.review.store")
local hooks = require("codediff.review.hooks")
local popup = require("codediff.review.popup")
local marks = require("codediff.review.marks")

local function notify(msg, level)
  vim.notify(msg, level, { title = "codediff.review" })
end

function M.add_at_cursor(initial_type)
  local file, line, side = hooks.get_cursor_position()
  if not file or not line then
    notify("Could not determine cursor position", vim.log.levels.WARN)
    return
  end

  local existing = store.get_at_line(file, line, side)
  if existing then
    notify("Comment already exists at this line. Use edit instead.", vim.log.levels.WARN)
    return
  end

  popup.open(initial_type or "note", nil, function(comment_type, text)
    if comment_type and text then
      store.add(file, line, comment_type, text, nil, side)
      vim.schedule(function()
        marks.refresh()
      end)
      notify(string.format("Added %s comment", comment_type), vim.log.levels.INFO)
    end
  end)
end

function M.add_with_menu()
  M.add_at_cursor()
end

function M.file_comment(initial_type)
  local file = hooks.get_cursor_position()
  if not file then
    notify("Could not determine file", vim.log.levels.WARN)
    return
  end

  local existing = store.get_file_comment(file)
  if existing then
    popup.open(existing.type, existing.text, function(new_type, text)
      if new_type and text then
        store.update(existing.id, text, new_type)
        vim.schedule(function()
          marks.refresh()
        end)
        notify("File comment updated", vim.log.levels.INFO)
      end
    end)
  else
    popup.open(initial_type or "note", nil, function(comment_type, text)
      if comment_type and text then
        store.add(file, 0, comment_type, text)
        vim.schedule(function()
          marks.refresh()
        end)
        notify(string.format("Added %s file comment", comment_type), vim.log.levels.INFO)
      end
    end)
  end
end

function M.add_for_range(initial_type)
  local file, start_line, end_line, side = hooks.get_visual_range()
  if not file or not start_line or not end_line then
    notify("Could not determine visual selection", vim.log.levels.WARN)
    return
  end

  local existing = store.get_overlapping(file, start_line, end_line, side)
  if existing then
    notify("Comment already exists in this range. Use edit instead.", vim.log.levels.WARN)
    return
  end

  popup.open(initial_type or "note", nil, function(comment_type, text)
    if comment_type and text then
      store.add(file, start_line, comment_type, text, end_line, side)
      vim.schedule(function()
        marks.refresh()
      end)
      notify(string.format("Added %s comment", comment_type), vim.log.levels.INFO)
    end
  end)
end

function M.edit_at_cursor()
  local file, line, side = hooks.get_cursor_position()
  if not file or not line then
    notify("Could not determine cursor position", vim.log.levels.WARN)
    return
  end

  local comment = store.get_at_line(file, line, side)
  if not comment and line == 1 then
    comment = store.get_file_comment(file)
  end
  if not comment then
    notify("No comment at cursor position", vim.log.levels.WARN)
    return
  end

  popup.open(comment.type, comment.text, function(new_type, text)
    if new_type and text then
      store.update(comment.id, text, new_type)
      vim.schedule(function()
        marks.refresh()
      end)
      notify("Comment updated", vim.log.levels.INFO)
    end
  end)
end

function M.delete_at_cursor()
  local file, line, side = hooks.get_cursor_position()
  if not file or not line then
    notify("Could not determine cursor position", vim.log.levels.WARN)
    return
  end

  local comment = store.get_at_line(file, line, side)
  if not comment and line == 1 then
    comment = store.get_file_comment(file)
  end
  if not comment then
    notify("No comment at cursor position", vim.log.levels.WARN)
    return
  end

  vim.ui.select({ "Yes", "No" }, { prompt = "Delete this comment?" }, function(choice)
    if choice == "Yes" then
      store.delete(comment.id)
      vim.schedule(function()
        marks.refresh()
      end)
      notify("Comment deleted", vim.log.levels.INFO)
    end
  end)
end

function M.goto_next()
  local file, line, side = hooks.get_cursor_position()
  if not file then
    return
  end

  local comments = store.get_for_file(file, side)
  for _, comment in ipairs(comments) do
    if comment.line > line then
      vim.api.nvim_win_set_cursor(0, { comment.line, 0 })
      return
    end
  end

  notify("No more comments in this file", vim.log.levels.INFO)
end

function M.goto_prev()
  local file, line, side = hooks.get_cursor_position()
  if not file then
    return
  end

  local comments = store.get_for_file(file, side)
  for i = #comments, 1, -1 do
    local comment = comments[i]
    if comment.line < line then
      vim.api.nvim_win_set_cursor(0, { comment.line, 0 })
      return
    end
  end

  notify("No previous comments in this file", vim.log.levels.INFO)
end

function M.list()
  local cfg = require("codediff.review.config").get()
  local all_comments = store.get_all()
  if #all_comments == 0 then
    notify("No comments yet", vim.log.levels.INFO)
    return
  end

  local items = {}
  for _, comment in ipairs(all_comments) do
    local type_info = cfg.comment_types[comment.type]
    local icon = type_info and type_info.icon or "●"
    local name = type_info and type_info.name or comment.type
    local location
    local is_old = (comment.side or "new") == "old"
    if comment.line == 0 then
      location = comment.file
    elseif is_old then
      if comment.line_end and comment.line_end ~= comment.line then
        location = string.format("%s:~%d-~%d", comment.file, comment.line, comment.line_end)
      else
        location = string.format("%s:~%d", comment.file, comment.line)
      end
    elseif comment.line_end and comment.line_end ~= comment.line then
      location = string.format("%s:%d-%d", comment.file, comment.line, comment.line_end)
    else
      location = string.format("%s:%d", comment.file, comment.line)
    end
    table.insert(items, {
      display = string.format("%s %s [%s] %s", icon, location, name, comment.text),
      comment = comment,
    })
  end

  vim.ui.select(items, {
    prompt = "Comments:",
    format_item = function(item)
      return item.display
    end,
  }, function(choice)
    if not choice then
      return
    end

    local comment = choice.comment
    local ok, lifecycle = pcall(require, "codediff.ui.lifecycle")
    if ok then
      local tabpage = hooks.get_current_tabpage()
      if tabpage then
        local explorer = lifecycle.get_explorer(tabpage)
        if explorer then
          local file_data = vim.deepcopy(explorer.current_selection) or {}
          file_data.path = comment.file
          file_data.group = file_data.group or explorer.current_file_group or "unstaged"
          explorer.on_file_select(file_data, { force = true })
        end
      end
    end

    vim.defer_fn(function()
      local target_line = comment.line == 0 and 1 or comment.line
      pcall(vim.api.nvim_win_set_cursor, 0, { target_line, 0 })
    end, 100)
  end)
end

return M
