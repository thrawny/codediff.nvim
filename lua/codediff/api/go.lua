-- The API view for Go: what a package exports, without any bodies. Exported
-- types show their exported fields and methods. Exported functions, consts and
-- vars show as declarations.
local M = {}

M.filetype = "go"
M.lsp = "gopls"

local function is_exported(name)
  return name ~= nil and name:match("^%u") ~= nil
end

local function text_of(node, src)
  return vim.treesitter.get_node_text(node, src)
end

local function field_name(node, field, src)
  local child = node:field(field)[1]
  return child and text_of(child, src)
end

local function first_child_of_type(node, type)
  for child in node:iter_children() do
    if child:type() == type then
      return child
    end
  end
end

-- The text of a function or method up to its body.
local function signature(node, src)
  local text = text_of(node, src)
  local body = node:field("body")[1]
  if body then
    text = text:sub(1, #text - #text_of(body, src))
  end
  return vim.trim(text)
end

-- The type name a method's receiver points at, such as Server in (s *Server[T]).
local function receiver_type(node, src)
  local receiver = field_name(node, "receiver", src) or ""
  return receiver:gsub("%[.*%]", ""):match("([%w_]+)%s*%)$")
end

-- An embedded field's name is the last identifier of its type, such as Mutex in sync.Mutex.
local function struct_field_exported(field, src)
  local names = field:field("name")
  if #names == 0 then
    local type_text = text_of(field:field("type")[1] or field, src)
    return is_exported(type_text:match("([%w_]+)$"))
  end
  for _, name in ipairs(names) do
    if is_exported(text_of(name, src)) then
      return true
    end
  end
  return false
end

local function member_exported(member, src)
  if member:type() == "method_elem" or member:type() == "method_spec" then
    return is_exported(field_name(member, "name", src))
  end
  return true
end

-- The source line of each line of a node's text.
local function node_lines(node, text)
  local start = node:start() + 1
  local lines = {}
  for i = 1, #vim.split(text, "\n") do
    lines[i] = start + i - 1
  end
  return lines
end

-- Whether the view keeps comments. extract sets it for the length of one call.
local include_comments = true

-- The doc comment right above a node: the run of comments that ends on the line
-- before it, at the node's column. Returns its lines and their source lines, or
-- empty lists.
local function doc_comment(node, src)
  local comments = {}
  local row, col = node:start()
  local prev = node:prev_sibling()
  while prev and prev:type() == "comment" and prev:end_() == row - 1 and select(2, prev:start()) == col do
    table.insert(comments, 1, prev)
    row = prev:start()
    prev = prev:prev_sibling()
  end
  local texts, lines = {}, {}
  for _, comment in ipairs(comments) do
    local text = text_of(comment, src):gsub("\n$", "")
    vim.list_extend(texts, vim.split(text, "\n"))
    vim.list_extend(lines, node_lines(comment, text))
  end
  return texts, lines
end

-- A comment after a node on its last line, such as a struct field's comment.
local function trailing_comment(node, src)
  if not include_comments then
    return ""
  end
  local next = node:next_sibling()
  if next and next:type() == "comment" and next:start() == node:end_() then
    return " " .. text_of(next, src)
  end
  return ""
end

-- Prepend a node's doc comment to text and lines, indented by indent.
local function with_doc(node, src, text, lines, indent)
  if not include_comments then
    return text, lines
  end
  local doc, doc_lines = doc_comment(node, src)
  if #doc == 0 then
    return text, lines
  end
  for i, line in ipairs(doc) do
    doc[i] = indent .. line
  end
  return table.concat(doc, "\n") .. "\n" .. text, vim.list_extend(doc_lines, lines)
end

-- A type spec's text, with unexported struct fields and interface methods left
-- out, and the source line of each of its lines.
local function type_text(spec, src)
  local text = "type " .. text_of(spec, src)
  local type_node = spec:field("type")[1]
  if not type_node then
    return text, node_lines(spec, text)
  end

  local list, keep
  if type_node:type() == "struct_type" then
    list = first_child_of_type(type_node, "field_declaration_list")
    keep = function(member)
      return member:type() == "field_declaration" and struct_field_exported(member, src)
    end
  elseif type_node:type() == "interface_type" then
    list = type_node
    keep = function(member)
      return member:named() and member:type() ~= "comment" and member_exported(member, src)
    end
  else
    return text, node_lines(spec, text)
  end

  local members, lines = {}, {}
  for member in list:iter_children() do
    if keep(member) then
      local member_text = text_of(member, src)
      local text_with_doc, member_lines = with_doc(member, src, "\t" .. member_text .. trailing_comment(member, src), node_lines(member, member_text), "\t")
      members[#members + 1] = text_with_doc
      vim.list_extend(lines, member_lines)
    end
  end

  local list_text = text_of(list, src)
  if type_node:type() == "interface_type" then
    list_text = list_text:match("{.*}$") or list_text
  end
  local header = text:sub(1, #text - #list_text)
  local header_lines = node_lines(spec, header)
  if #members == 0 then
    return header .. "{}", header_lines
  end
  table.insert(lines, 1, header_lines[#header_lines])
  for i = #header_lines - 1, 1, -1 do
    table.insert(lines, 1, header_lines[i])
  end
  lines[#lines + 1] = list:end_() + 1
  return header .. "{\n" .. table.concat(members, "\n") .. "\n}", lines
end

local function collect(sources)
  local api = { values = {}, funcs = {}, types = {}, methods = {}, package = nil }

  for _, source in ipairs(sources) do
    local file, src = source.path, source.text
    local root = vim.treesitter.get_string_parser(src, "go"):parse()[1]:root()

    local function entry(text, lines)
      return { text = text, file = file, line = lines[1], lines = lines }
    end

    for node in root:iter_children() do
      local kind = node:type()
      if kind == "package_clause" then
        api.package = api.package or text_of(node, src)
      elseif kind == "function_declaration" then
        if is_exported(field_name(node, "name", src)) then
          local text = signature(node, src)
          api.funcs[#api.funcs + 1] = entry(with_doc(node, src, text, node_lines(node, text), ""))
        end
      elseif kind == "method_declaration" then
        local owner = receiver_type(node, src)
        if is_exported(field_name(node, "name", src)) and is_exported(owner) then
          api.methods[owner] = api.methods[owner] or {}
          local text = signature(node, src)
          table.insert(api.methods[owner], entry(with_doc(node, src, text, node_lines(node, text), "")))
        end
      elseif kind == "type_declaration" then
        for spec in node:iter_children() do
          if (spec:type() == "type_spec" or spec:type() == "type_alias") and is_exported(field_name(spec, "name", src)) then
            local text, lines = type_text(spec, src)
            -- A grouped type's comment is above its spec, a single type's above the declaration.
            local doc_node = spec:prev_sibling() and spec:prev_sibling():type() == "comment" and spec or node
            local item = entry(with_doc(doc_node, src, text, lines, ""))
            item.name = field_name(spec, "name", src)
            api.types[#api.types + 1] = item
          end
        end
      elseif kind == "const_declaration" or kind == "var_declaration" then
        local keyword = kind == "const_declaration" and "const" or "var"
        local spec_type = keyword .. "_spec"
        local specs, grouped = {}, false
        for child in node:iter_children() do
          if child:type() == spec_type then
            specs[#specs + 1] = child
          elseif child:type() == spec_type .. "_list" then
            grouped = true
            for inner in child:iter_children() do
              if inner:type() == spec_type then
                specs[#specs + 1] = inner
              end
            end
          end
        end
        grouped = grouped or text_of(node, src):match("^%w+%s*%(") ~= nil
        local kept, lines = {}, {}
        for _, spec in ipairs(specs) do
          if is_exported(field_name(spec, "name", src)) then
            local spec_text = text_of(spec, src)
            local spec_lines = node_lines(spec, spec_text)
            if grouped then
              spec_text, spec_lines = with_doc(spec, src, "\t" .. spec_text .. trailing_comment(spec, src), spec_lines, "\t")
            end
            kept[#kept + 1] = spec_text
            vim.list_extend(lines, spec_lines)
          end
        end
        if #kept > 0 then
          local text = keyword .. " " .. kept[1]
          if grouped then
            text = keyword .. " (\n" .. table.concat(kept, "\n") .. "\n)"
            table.insert(lines, 1, node:start() + 1)
            lines[#lines + 1] = node:end_() + 1
          end
          api.values[#api.values + 1] = entry(with_doc(node, src, text, lines, ""))
        end
      end
    end
  end

  table.sort(api.types, function(a, b)
    return a.name < b.name
  end)
  return api
end

-- Each item is preceded by a marker comment, so that after gofmt every line
-- can still be traced to its source.
-- The space after // keeps gofmt from taking it for a directive, such as
-- //go:generate, which it would move below the doc comment.
local MARKER = "// codediff-api:"

local function render(api)
  local lines, items = {}, {}

  local group = 0

  local function add(item)
    item.group = group
    items[#items + 1] = item
    lines[#lines + 1] = MARKER .. #items
    vim.list_extend(lines, vim.split(item.text, "\n"))
  end

  local function blank()
    group = group + 1
    if #lines > 0 and lines[#lines] ~= "" then
      lines[#lines + 1] = ""
    end
  end

  if api.package then
    lines[#lines + 1] = api.package
  end
  for _, section in ipairs({ api.values, api.funcs }) do
    blank()
    for _, item in ipairs(section) do
      add(item)
    end
  end
  local type_names = {}
  for _, item in ipairs(api.types) do
    type_names[item.name] = true
    blank()
    add(item)
    for _, method in ipairs(api.methods[item.name] or {}) do
      add(method)
    end
  end
  -- Methods whose type is in a file the view does not cover, such as when the
  -- view covers one file of a package.
  local owners = vim.tbl_filter(function(owner)
    return not type_names[owner]
  end, vim.tbl_keys(api.methods))
  table.sort(owners)
  for _, owner in ipairs(owners) do
    blank()
    for _, method in ipairs(api.methods[owner]) do
      add(method)
    end
  end
  return lines, items
end

-- gofmt aligns struct fields again after unexported ones are left out. The
-- unformatted lines are kept if gofmt fails.
local function gofmt(lines)
  if vim.fn.executable("gofmt") == 0 then
    return lines
  end
  local result = vim.system({ "gofmt" }, { stdin = table.concat(lines, "\n") .. "\n" }):wait()
  if result.code ~= 0 then
    return lines
  end
  return vim.split(result.stdout:gsub("\n$", ""), "\n")
end

-- Drop the marker comments, and map each remaining line to its item's source.
-- gofmt puts a blank line before each marker. Drop it between items of one group,
-- such as a type and its methods, unless either item has a doc comment.
local function strip_markers(lines, items)
  local out, targets, current, offset, pending_blank = {}, {}, nil, 0, false
  local current_documented = false
  for _, line in ipairs(lines) do
    local index = line:match("^" .. vim.pesc(MARKER) .. "(%d+)$")
    if index then
      local item = items[tonumber(index)]
      local documented = item.text:match("^%s*//") ~= nil
      local same_group = current and current.group == item.group
      if pending_blank and (documented or current_documented or not same_group) then
        out[#out + 1] = ""
      end
      pending_blank, current, offset, current_documented = false, item, 0, documented
    elseif line == "" then
      pending_blank = true
    else
      if pending_blank then
        out[#out + 1] = ""
        pending_blank, current = false, nil
      end
      out[#out + 1] = line
      if current then
        offset = offset + 1
        targets[#out] = { file = current.file, line = current.lines[offset] or current.line }
      end
    end
  end
  return out, targets
end

-- The files that make up the view of path's package, and the view's name: the
-- package's non-test files and its directory. Returns nil for a test file,
-- which belongs to no view.
function M.files(path)
  if path:match("_test%.go$") then
    return nil
  end
  local dir = vim.fn.fnamemodify(path, ":p:h")
  local files = vim.tbl_filter(function(file)
    return not file:match("_test%.go$")
  end, vim.fn.glob(dir .. "/*.go", false, true))
  return files, dir
end

-- The API view of a package's sources, given as { { path, text }, ... }.
-- opts.comments = false leaves out doc comments and trailing comments.
-- Returns the view's lines, and per line the source position it came from,
-- as { [line] = { file, line } }. Returns nil if the package exports nothing.
function M.extract(sources, opts)
  include_comments = not opts or opts.comments ~= false
  local lines, items = render(collect(sources))
  if #items == 0 then
    return nil
  end
  return strip_markers(gofmt(lines), items)
end

return M
