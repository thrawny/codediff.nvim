local M = {}

local storage = require("codediff.review.storage")

---@class CodeDiffReviewComment
---@field id string
---@field file string
---@field line number
---@field line_end? number
---@field side? "old"|"new"
---@field type string
---@field text string
---@field created_at number

---@type table<string, CodeDiffReviewComment[]>
M.comments = {}

local id_counter = 0
local loaded = false

---@return string
local function generate_id()
  id_counter = id_counter + 1
  return string.format("comment_%d_%d", os.time(), id_counter)
end

local function persist()
  storage.save(M.comments)
end

function M.reset()
  M.comments = {}
  id_counter = 0
  loaded = false
end

function M.load()
  if loaded then
    return
  end
  M.comments = storage.load()
  for _, comments in pairs(M.comments) do
    for _, comment in ipairs(comments) do
      local num = tonumber(comment.id:match("comment_%d+_(%d+)"))
      if num and num > id_counter then
        id_counter = num
      end
    end
  end
  loaded = true
end

---@param file string
---@param line number
---@param type string
---@param text string
---@param line_end? number
---@param side? "old"|"new"
---@return CodeDiffReviewComment
function M.add(file, line, type, text, line_end, side)
  if not M.comments[file] then
    M.comments[file] = {}
  end

  local comment = {
    id = generate_id(),
    file = file,
    line = line,
    line_end = (line_end and line_end ~= line) and line_end or nil,
    side = side or "new",
    type = type,
    text = text,
    created_at = os.time(),
  }

  table.insert(M.comments[file], comment)
  persist()
  return comment
end

---@param file string
---@return CodeDiffReviewComment|nil
function M.get_file_comment(file)
  for _, comment in ipairs(M.comments[file] or {}) do
    if comment.line == 0 then
      return comment
    end
  end
  return nil
end

---@param file string
---@param side? "old"|"new"
---@return CodeDiffReviewComment[]
function M.get_for_file(file, side)
  local comments = M.comments[file] or {}
  if not side then
    return comments
  end

  local filtered = {}
  for _, comment in ipairs(comments) do
    if comment.line == 0 or (comment.side or "new") == side then
      table.insert(filtered, comment)
    end
  end
  return filtered
end

---@param file string
---@param line number
---@param side? "old"|"new"
---@return CodeDiffReviewComment|nil
function M.get_at_line(file, line, side)
  for _, comment in ipairs(M.comments[file] or {}) do
    local line_end = comment.line_end or comment.line
    if line >= comment.line and line <= line_end then
      if not side or (comment.side or "new") == side then
        return comment
      end
    end
  end
  return nil
end

---@param file string
---@param start_line number
---@param end_line number
---@param side? "old"|"new"
---@return CodeDiffReviewComment|nil
function M.get_overlapping(file, start_line, end_line, side)
  for _, comment in ipairs(M.comments[file] or {}) do
    local comment_end = comment.line_end or comment.line
    if comment.line <= end_line and comment_end >= start_line then
      if not side or (comment.side or "new") == side then
        return comment
      end
    end
  end
  return nil
end

---@param id string
---@param text string
---@param new_type? string
---@return boolean
function M.update(id, text, new_type)
  for _, comments in pairs(M.comments) do
    for _, comment in ipairs(comments) do
      if comment.id == id then
        comment.text = text
        if new_type then
          comment.type = new_type
        end
        persist()
        return true
      end
    end
  end
  return false
end

---@param id string
---@return boolean
function M.delete(id)
  for file, comments in pairs(M.comments) do
    for idx, comment in ipairs(comments) do
      if comment.id == id then
        table.remove(comments, idx)
        if #comments == 0 then
          M.comments[file] = nil
        end
        persist()
        return true
      end
    end
  end
  return false
end

---@return CodeDiffReviewComment[]
function M.get_all()
  local all = {}
  for _, comments in pairs(M.comments) do
    for _, comment in ipairs(comments) do
      table.insert(all, comment)
    end
  end

  table.sort(all, function(a, b)
    if a.file ~= b.file then
      return a.file < b.file
    end
    return a.line < b.line
  end)

  return all
end

---@return number
function M.count()
  local count = 0
  for _, comments in pairs(M.comments) do
    count = count + #comments
  end
  return count
end

function M.clear()
  M.reset()
  storage.clear()
  storage.clear_revisions()
end

return M
