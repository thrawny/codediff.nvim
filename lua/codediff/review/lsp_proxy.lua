local M = {}

local location_methods = {
  gd = { method = "textDocument/definition", title = "LSP definitions", desc = "Goto Definition (review proxy)" },
  gD = { method = "textDocument/declaration", title = "LSP declarations", desc = "Goto Declaration (review proxy)" },
  gI = {
    method = "textDocument/implementation",
    title = "LSP implementations",
    desc = "Goto Implementation (review proxy)",
  },
  gy = {
    method = "textDocument/typeDefinition",
    title = "LSP type definitions",
    desc = "Goto Type Definition (review proxy)",
  },
  gr = {
    method = "textDocument/references",
    title = "LSP references",
    desc = "References (review proxy)",
    context = { includeDeclaration = true },
  },
}

local function original_to_modified_line(session, line)
  local diff_result = session.stored_diff_result
  if not diff_result or not diff_result.changes then
    return line
  end

  local delta = 0
  for _, change in ipairs(diff_result.changes) do
    if line < change.original.start_line then
      break
    end

    local orig_count = change.original.end_line - change.original.start_line
    local mod_count = change.modified.end_line - change.modified.start_line

    if line < change.original.end_line then
      return math.max(1, change.modified.start_line + math.min(line - change.original.start_line, math.max(mod_count - 1, 0)))
    end

    delta = delta + mod_count - orig_count
  end

  return math.max(1, line + delta)
end

local function flatten_locations(results)
  local locations = {}

  for _, response in pairs(results or {}) do
    if response.result then
      local result = response.result
      if result.uri or result.targetUri then
        result = { result }
      end
      for _, loc in ipairs(result) do
        local uri = loc.uri or loc.targetUri
        local range = loc.range or loc.targetSelectionRange or loc.targetRange
        if uri and range then
          table.insert(locations, { uri = uri, range = range })
        end
      end
    end
  end

  return locations
end

local function qf_items_from_locations(locations)
  local items = {}

  for _, loc in ipairs(locations) do
    local filename = vim.uri_to_fname(loc.uri)
    local lnum = loc.range.start.line + 1
    table.insert(items, {
      filename = filename,
      lnum = lnum,
      col = loc.range.start.character + 1,
      text = vim.trim((vim.fn.getbufline(vim.fn.bufadd(filename), lnum)[1] or "")),
    })
  end

  return items
end

local typescript_extensions = {
  js = true,
  jsx = true,
  mjs = true,
  mts = true,
  ts = true,
  tsx = true,
}

local function is_typescript_import_location(loc)
  local filename = vim.uri_to_fname(loc.uri)
  local extension = vim.fn.fnamemodify(filename, ":e"):lower()
  if not typescript_extensions[extension] then
    return false
  end

  local line = vim.fn.getbufline(vim.fn.bufadd(filename), loc.range.start.line + 1)[1] or ""
  return line:match("^%s*import[%s{*]") ~= nil or line:match("^%s*export%s") ~= nil
end

local function follow_typescript_imports(real_buf, locations)
  local visited = {}
  for _ = 1, 4 do
    if #locations ~= 1 or not is_typescript_import_location(locations[1]) then
      break
    end

    local loc = locations[1]
    local key = string.format("%s:%d:%d", loc.uri, loc.range.start.line, loc.range.start.character)
    if visited[key] then
      break
    end
    visited[key] = true

    local results = vim.lsp.buf_request_sync(real_buf, "textDocument/definition", {
      textDocument = { uri = loc.uri },
      position = loc.range.start,
    }, 10000)
    local next_locations = flatten_locations(results)
    if #next_locations == 0 then
      break
    end

    local next_loc = next_locations[1]
    local next_key = string.format("%s:%d:%d", next_loc.uri, next_loc.range.start.line, next_loc.range.start.character)
    if #next_locations == 1 and next_key == key then
      break
    end
    locations = next_locations
  end
  return locations
end

local function absolute_session_path(session, path)
  if not path or path == "" then
    return nil
  end
  if vim.fn.isabsolutepath(path) == 1 then
    return vim.fs.normalize(path)
  end
  return vim.fs.normalize((session.git_root or vim.fn.getcwd()) .. "/" .. path)
end

local function jump_to_modified_location(session, loc)
  local target_path = vim.fs.normalize(vim.uri_to_fname(loc.uri))
  if target_path ~= absolute_session_path(session, session.modified_path) then
    return false
  end

  local winid = session.modified_win
  local bufnr = session.modified_bufnr
  if not (winid and bufnr and vim.api.nvim_win_is_valid(winid) and vim.api.nvim_buf_is_valid(bufnr)) then
    return false
  end

  if vim.api.nvim_win_get_buf(winid) ~= bufnr then
    vim.api.nvim_win_set_buf(winid, bufnr)
  end
  local line = math.min(loc.range.start.line + 1, vim.api.nvim_buf_line_count(bufnr))
  local line_text = vim.api.nvim_buf_get_lines(bufnr, line - 1, line, false)[1] or ""
  local column = math.min(loc.range.start.character, #line_text)
  vim.api.nvim_set_current_win(winid)
  vim.api.nvim_win_set_cursor(winid, { line, column })
  return true
end

local function relative_to_git_root(session, path)
  local root = session.git_root and vim.fs.normalize(session.git_root) or nil
  path = vim.fs.normalize(path)
  if not root or path:sub(1, #root + 1) ~= root .. "/" then
    return nil
  end
  return path:sub(#root + 2)
end

local function find_explorer_file(explorer, path)
  local function visit(node)
    if node.data and node.data.path == path then
      return node.data
    end
    for _, child_id in ipairs(node:get_child_ids()) do
      local child = explorer.tree:get_node(child_id)
      local found = child and visit(child) or nil
      if found then
        return found
      end
    end
  end

  for _, node in ipairs(explorer.tree:get_nodes()) do
    local found = visit(node)
    if found then
      return found
    end
  end
end

local function route_review_location(tabpage, session, loc)
  if jump_to_modified_location(session, loc) then
    return true
  end

  local target_path = vim.fs.normalize(vim.uri_to_fname(loc.uri))
  local relative_path = relative_to_git_root(session, target_path)
  local explorer = session.explorer
  local file_data = explorer and relative_path and find_explorer_file(explorer, relative_path) or nil
  if not file_data then
    return false
  end

  local group = vim.api.nvim_create_augroup("codediff_review_definition_" .. tabpage, { clear = true })
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "CodeDiffRender",
    callback = function(args)
      if not args.data or args.data.tabpage ~= tabpage then
        return
      end
      local current = require("codediff.ui.lifecycle").get_session(tabpage)
      if not current or not jump_to_modified_location(current, loc) then
        return
      end
      pcall(vim.api.nvim_del_augroup_by_id, group)
    end,
  })
  explorer.on_file_select(file_data)
  return true
end

local function focus_outside_review(tabpage)
  local tabs = vim.api.nvim_list_tabpages()
  local review_index
  for index, candidate in ipairs(tabs) do
    if candidate == tabpage then
      review_index = index
      break
    end
  end

  local target_tab = review_index and review_index > 1 and tabs[review_index - 1] or nil
  if target_tab and vim.api.nvim_tabpage_is_valid(target_tab) then
    vim.api.nvim_set_current_tabpage(target_tab)
    return target_tab
  end

  vim.cmd("tabnew")
  target_tab = vim.api.nvim_get_current_tabpage()
  vim.cmd("tabmove 0")
  return target_tab
end

local function open_location_outside_review(tabpage, loc)
  focus_outside_review(tabpage)
  local path = vim.uri_to_fname(loc.uri)
  vim.cmd.edit(vim.fn.fnameescape(path))
  local bufnr = vim.api.nvim_get_current_buf()
  local line = math.min(loc.range.start.line + 1, vim.api.nvim_buf_line_count(bufnr))
  local line_text = vim.api.nvim_buf_get_lines(bufnr, line - 1, line, false)[1] or ""
  local column = math.min(loc.range.start.character, #line_text)
  vim.api.nvim_win_set_cursor(0, { line, column })
end

local function open_locations(locations, title, jump_single, tabpage, session)
  if #locations == 0 then
    vim.notify("No " .. title:lower() .. " found", vim.log.levels.INFO)
    return
  end

  if jump_single and #locations == 1 then
    local loc = locations[1]
    if tabpage and session and route_review_location(tabpage, session, loc) then
      return
    end
    open_location_outside_review(tabpage, loc)
    return
  end

  focus_outside_review(tabpage)
  vim.fn.setqflist({}, " ", { title = title, items = qf_items_from_locations(locations) })

  local ok, fzf = pcall(require, "fzf-lua")
  if ok then
    fzf.quickfix({ winopts = { title = title } })
  else
    vim.cmd("copen")
  end
end

local function show_hover(result)
  local contents = result and result.contents
  if not contents then
    vim.notify("No hover found", vim.log.levels.INFO)
    return
  end

  local lines = vim.lsp.util.convert_input_to_markdown_lines(contents)
  lines = vim.split(table.concat(lines, "\n"), "\n", { trimempty = true })
  if vim.tbl_isempty(lines) then
    vim.notify("No hover found", vim.log.levels.INFO)
    return
  end

  vim.lsp.util.open_floating_preview(lines, "markdown", { border = "rounded", focusable = true })
end

local function session_file_path(session)
  local rel_path = session.modified_path ~= "" and session.modified_path or session.original_path
  if not rel_path or rel_path == "" then
    return nil
  end

  if rel_path:match("^/") then
    return rel_path
  end

  return (session.git_root or vim.fn.getcwd()) .. "/" .. rel_path
end

local function real_position(session, cursor, source_buf)
  local line = source_buf == session.original_bufnr and original_to_modified_line(session, cursor[1]) or cursor[1]
  return { line = line - 1, character = cursor[2] }
end

local function with_real_lsp(session, callback)
  local real_path = session_file_path(session)
  if not real_path then
    vim.notify("No review file path for LSP proxy", vim.log.levels.WARN)
    return
  end

  if vim.fn.filereadable(real_path) ~= 1 then
    vim.notify("No working-tree file for LSP proxy: " .. real_path, vim.log.levels.WARN)
    return
  end

  local real_buf = vim.fn.bufadd(real_path)
  vim.fn.bufload(real_buf)

  local attempts = 0
  local function wait_for_lsp()
    attempts = attempts + 1
    local clients = vim.lsp.get_clients({ bufnr = real_buf })
    if #clients > 0 then
      callback(real_buf, real_path)
    elseif attempts < 20 then
      vim.defer_fn(wait_for_lsp, 250)
    else
      vim.notify("No LSP client for LSP proxy: " .. real_path, vim.log.levels.WARN)
    end
  end

  wait_for_lsp()
end

local function proxy_location(tabpage, lhs)
  local ok, lifecycle = pcall(require, "codediff.ui.lifecycle")
  local session = ok and lifecycle.get_session(tabpage)
  local spec = location_methods[lhs]
  if not session or not spec then
    vim.notify("No review session for LSP proxy", vim.log.levels.WARN)
    return
  end

  local cursor = vim.api.nvim_win_get_cursor(0)
  local source_buf = vim.api.nvim_get_current_buf()
  with_real_lsp(session, function(real_buf, real_path)
    local params = {
      textDocument = { uri = vim.uri_from_fname(real_path) },
      position = real_position(session, cursor, source_buf),
    }
    if spec.context then
      params.context = spec.context
    end

    local results = vim.lsp.buf_request_sync(real_buf, spec.method, params, 10000)
    local locations = flatten_locations(results)
    if lhs == "gd" then
      locations = follow_typescript_imports(real_buf, locations)
    end
    open_locations(locations, spec.title, lhs ~= "gr", tabpage, session)
  end)
end

local function proxy_hover(tabpage)
  if #vim.lsp.get_clients({ bufnr = 0 }) > 0 then
    vim.lsp.buf.hover()
    return
  end

  local ok, lifecycle = pcall(require, "codediff.ui.lifecycle")
  local session = ok and lifecycle.get_session(tabpage)
  if not session then
    vim.notify("No review session for hover", vim.log.levels.WARN)
    return
  end

  local cursor = vim.api.nvim_win_get_cursor(0)
  local source_buf = vim.api.nvim_get_current_buf()
  with_real_lsp(session, function(real_buf, real_path)
    local results = vim.lsp.buf_request_sync(real_buf, "textDocument/hover", {
      textDocument = { uri = vim.uri_from_fname(real_path) },
      position = real_position(session, cursor, source_buf),
    }, 10000)

    for _, response in pairs(results or {}) do
      if response.result then
        show_hover(response.result)
        return
      end
    end
    vim.notify("No hover found", vim.log.levels.INFO)
  end)
end

function M.apply_to_buffer(tabpage, bufnr, mapped)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  local ok, lifecycle = pcall(require, "codediff.ui.lifecycle")
  local session = ok and lifecycle.get_session(tabpage)
  if not session or (bufnr ~= session.original_bufnr and bufnr ~= session.modified_bufnr) then
    return
  end

  for lhs, spec in pairs(location_methods) do
    vim.keymap.set("n", lhs, function()
      proxy_location(tabpage, lhs)
    end, { buffer = bufnr, desc = spec.desc, silent = true })
    if mapped then
      table.insert(mapped, { "n", lhs })
    end
  end

  vim.keymap.set("n", "K", function()
    proxy_hover(tabpage)
  end, { buffer = bufnr, desc = "Hover (review proxy)", silent = true })
  if mapped then
    table.insert(mapped, { "n", "K" })
  end
end

function M.apply(tabpage)
  local ok, lifecycle = pcall(require, "codediff.ui.lifecycle")
  local session = ok and lifecycle.get_session(tabpage)
  if not session then
    return
  end

  M.apply_to_buffer(tabpage, session.original_bufnr)
  M.apply_to_buffer(tabpage, session.modified_bufnr)
end

M._test = {
  original_to_modified_line = original_to_modified_line,
  flatten_locations = flatten_locations,
  qf_items_from_locations = qf_items_from_locations,
  session_file_path = session_file_path,
  real_position = real_position,
}

return M
