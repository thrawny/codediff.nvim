local M = {}

function M.setup()
  local links = {
    ReviewPickerHash = "Identifier",
    ReviewPickerMeta = "Comment",
    ReviewPickerSelected = "String",
    ReviewContextPr = "Identifier",
    ReviewContextJira = "Constant",
  }

  for group, link in pairs(links) do
    vim.api.nvim_set_hl(0, group, { link = link, default = true })
  end
end

return M
