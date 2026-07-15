local M = {}

---Return the real buffer line that visually anchors a hunk range.
---Empty ranges at EOF start one line past the buffer and must be clamped to
---the final real line where their virtual deletion lines are rendered.
---@param range { start_line: number, end_line: number }
---@param line_count number
---@return number
function M.target_line(range, line_count)
  return math.max(1, math.min(range.start_line, line_count))
end

---@param range { start_line: number, end_line: number }
---@param line number
---@param line_count number
---@return boolean
function M.contains_line(range, line, line_count)
  if range.start_line == range.end_line then
    return line == M.target_line(range, line_count)
  end
  return line >= range.start_line and line < range.end_line
end

return M
