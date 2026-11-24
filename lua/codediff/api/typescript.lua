-- The API view for TypeScript: what a module exports. Functions and methods
-- show their signatures with ` ...` for a body, and classes their non-private
-- members. Interfaces, type aliases, enums and other declarations show as
-- written, with any function in them cut at its body.
--
-- A module is one file. A file that its directory's index.ts re-exports from
-- belongs to the barrel's view instead: index.ts's own API, with each
-- re-export followed by the definitions it pulls in from the directory's other
-- files.
local M = {}

M.filetype = "typescript"
-- The filetypes whose language servers can answer for TypeScript sources.
M.filetypes = { "typescript", "typescriptreact" }
-- gd asks any language server that handles TypeScript, such as ts_ls or
-- vtsls, so there is no fixed name.
M.lsp = nil

-- Whether the view keeps comments, and non-exported declarations and private
-- members. extract sets them for the length of one call.
local include_comments = true
local include_private = false

-- Per parser: the comment query, parsed on first use, so that loading this
-- file needs no TypeScript parser.
local comment_queries = {}
local pattern_queries = {}

-- The extensions a sibling module's file can have, in the order an import
-- specifier without one resolves to them.
local EXTENSIONS = { ".ts", ".tsx", ".d.ts", ".mts", ".cts" }

local CLASSES = { class_declaration = true, abstract_class_declaration = true, class = true }

-- Nodes with a body that the view cuts off.
local FUNCTIONS = {
  function_declaration = true,
  generator_function_declaration = true,
  function_expression = true,
  ["function"] = true,
  generator_function = true,
  arrow_function = true,
  method_definition = true,
  class = true,
}

local DECLARATIONS = {
  function_declaration = true,
  generator_function_declaration = true,
  function_signature = true,
  class_declaration = true,
  abstract_class_declaration = true,
  interface_declaration = true,
  type_alias_declaration = true,
  enum_declaration = true,
  internal_module = true,
  module = true,
  lexical_declaration = true,
  variable_declaration = true,
  ambient_declaration = true,
}

local function text_of(node, src)
  return vim.treesitter.get_node_text(node, src)
end

local function basename(path)
  return vim.fn.fnamemodify(path, ":t")
end

local function dirname(path)
  return vim.fn.fnamemodify(path, ":h")
end

local function is_barrel(path)
  return basename(path):match("^index%.tsx?$") ~= nil
end

local function child_of_type(node, kind)
  for child in node:iter_children() do
    if child:type() == kind then
      return child
    end
  end
end

-- A parsed source: its path, text, lines, tree, the names it exports with an
-- export clause such as `export { a, b as c }`, and per row the byte ranges of
-- its comments.
local function parse(source)
  local lang = source.path:match("%.tsx$") and "tsx" or "typescript"
  local root = vim.treesitter.get_string_parser(source.text, lang):parse()[1]:root()
  comment_queries[lang] = comment_queries[lang] or vim.treesitter.query.parse(lang, "(comment) @comment")
  local lines = vim.split(source.text, "\n")
  local comments = {}
  for _, node in comment_queries[lang]:iter_captures(root, source.text) do
    local first, first_col, last, last_col = node:range()
    for row = first, last do
      comments[row] = comments[row] or {}
      table.insert(comments[row], { row == first and first_col or 0, row == last and last_col or #(lines[row + 1] or "") })
    end
  end
  local exports = {}
  for node in root:iter_children() do
    local clause = node:type() == "export_statement" and not node:field("source")[1] and child_of_type(node, "export_clause")
    for spec in clause and clause:iter_children() or function() end do
      if spec:type() == "export_specifier" then
        exports[text_of(spec:field("name")[1], source.text)] = true
      end
    end
  end
  return { path = source.path, src = source.text, lang = lang, lines = lines, root = root, comments = comments, exports = exports }
end

-- Source rows first to last (0-based) as view lines, the last cut before byte
-- last_col. With comments hidden, comments are cut out, and lines that leaves
-- blank are dropped.
local function copy(mod, first, last, last_col)
  local out = {}
  for row = first, last do
    local line = mod.lines[row + 1] or ""
    if row == last and last_col then
      line = line:sub(1, last_col)
    end
    local ranges = not include_comments and mod.comments[row]
    if ranges then
      local kept, pos = nil, 1
      -- The code around each comment, joined with the indentation kept and
      -- one space where the comment was between code.
      local function keep(piece)
        if not kept then
          kept = piece
        elseif kept:match("^%s*$") then
          kept = kept .. piece:gsub("^%s+", "")
        else
          kept = kept:gsub("%s+$", "") .. piece
        end
      end
      for _, range in ipairs(ranges) do
        if range[1] >= #line then
          break
        end
        keep(line:sub(pos, range[1]))
        pos = range[2] + 1
      end
      keep(line:sub(pos))
      line = kept:gsub("%s+$", "")
      if line:match("^%s*$") then
        line = nil
      end
    end
    if line then
      out[#out + 1] = { text = line, file = mod.path, row = row }
    end
  end
  return out
end

-- The run of comments right above a node, at its column, such as a JSDoc
-- block.
local function leading_comments(mod, node)
  if not include_comments then
    return {}
  end
  local row, col = node:start()
  local first
  local prev = node:prev_sibling()
  while prev and prev:type() == "comment" and prev:end_() == row - 1 and select(2, prev:start()) == col do
    first = prev
    row = prev:start()
    prev = prev:prev_sibling()
  end
  return first and copy(mod, first:start(), node:start() - 1) or {}
end

-- Whether two entries in a row are apart in the source: a blank line between
-- them, such as between two methods. Groups, entries from different files and
-- entries out of source order are always apart.
local function apart(a, b)
  if a.group or b.group or a.mod ~= b.mod or b.first <= a.last then
    return true
  end
  for row = a.last + 1, b.first - 1 do
    if (a.mod.lines[row + 1] or ""):match("^%s*$") then
      return true
    end
  end
  return false
end

-- Join entries into view lines, after out's lines if given, with a blank line
-- between two entries that are apart in the source.
local function join(entries, out)
  out = out or {}
  local prev
  for _, entry in ipairs(entries) do
    if prev and apart(prev, entry) then
      out[#out + 1] = { text = "" }
    end
    vim.list_extend(out, entry.lines)
    prev = entry
  end
  return out
end

-- The first node with a body in node, node included, in source order.
local function first_function(node)
  if FUNCTIONS[node:type()] and node:field("body")[1] then
    return node
  end
  for child in node:iter_children() do
    local found = first_function(child)
    if found then
      return found
    end
  end
end

-- Lines up to row, col, ending in ` ...`.
local function cut(mod, outer, row, col)
  local lines = copy(mod, outer:start(), row, col)
  while #lines > 1 and lines[#lines].text:match("^%s*$") do
    lines[#lines] = nil
  end
  lines[#lines].text = lines[#lines].text:gsub("%s+$", "") .. " ..."
  return lines
end

-- A statement or member as written, with the first function in it cut at its
-- body.
local function plain(mod, outer, inner)
  local fn = first_function(inner)
  if not fn then
    return copy(mod, outer:start(), (outer:end_()))
  end
  local row, col = fn:field("body")[1]:start()
  return cut(mod, outer, row, col)
end

-- A class or namespace: its header, its members, and its closing brace. One
-- without members shows its header and ` ...`. One on one line shows as
-- written if all its members show.
local function block(mod, outer, body, members)
  local row, col = body:start()
  local last, last_col = body:end_()
  if row == last and #members > 0 then
    local count = 0
    for child in body:iter_children() do
      count = count + ((child:named() and child:type() ~= "comment") and 1 or 0)
    end
    if count == #members then
      return plain(mod, outer, body)
    end
  end
  if #members == 0 or row == last then
    return cut(mod, outer, row, col)
  end
  local lines = copy(mod, outer:start(), row, col + 1)
  join(members, lines)
  vim.list_extend(lines, copy(mod, last, last, last_col))
  return lines
end

local function name_of(mod, node)
  local name = node:field("name")[1]
  return name and text_of(name, mod.src)
end

-- The names a declaration binds.
local function declared_names(mod, node)
  local kind = node:type()
  if kind == "export_statement" then
    local declaration = node:field("declaration")[1]
    return declaration and declared_names(mod, declaration) or {}
  elseif kind == "ambient_declaration" then
    local inner = node:named_child(0)
    return inner and inner:type() ~= "statement_block" and declared_names(mod, inner) or {}
  elseif kind == "lexical_declaration" or kind == "variable_declaration" then
    local names = {}
    for declarator in node:iter_children() do
      local name = declarator:type() == "variable_declarator" and declarator:field("name")[1]
      if name and name:type() == "identifier" then
        names[#names + 1] = text_of(name, mod.src)
      elseif name then
        -- A destructuring pattern binds each of its identifiers.
        local lang = mod.lang
        pattern_queries[lang] = pattern_queries[lang] or vim.treesitter.query.parse(lang, "[(identifier) (shorthand_property_identifier_pattern)] @name")
        for _, match in pattern_queries[lang]:iter_captures(name, mod.src) do
          names[#names + 1] = text_of(match, mod.src)
        end
      end
    end
    return names
  elseif DECLARATIONS[kind] then
    return { name_of(mod, node) }
  end
  return {}
end

-- A private class member: marked private, or with a #name.
local function private_member(mod, node)
  local modifier = child_of_type(node, "accessibility_modifier")
  if modifier and text_of(modifier, mod.src) == "private" then
    return true
  end
  local name = node:field("name")[1]
  return name ~= nil and name:type() == "private_property_identifier"
end

-- An entry: a node's lines after its leading comments, its module, and the
-- source rows it spans.
local function make_entry(mod, node, lines)
  local all = leading_comments(mod, node)
  vim.list_extend(all, lines)
  return { lines = all, mod = mod, first = all[1].row, last = (node:end_()) }
end

-- Whether node is the implementation of an overloaded function or method,
-- which follows its signatures and is not part of its API. Records in
-- signatures the names of the signatures it passes.
local function overload_implementation(mod, node, signatures)
  local decl = node:type() == "export_statement" and node:field("declaration")[1] or node
  local kind = decl and decl:type()
  local signature = kind == "function_signature" or kind == "method_signature"
  local name = (signature or kind == "function_declaration" or kind == "method_definition") and name_of(mod, decl)
  if not name then
    return false
  end
  if signature then
    signatures[name] = true
    return false
  end
  return signatures[name] == true
end

local render

local function class_members(mod, body)
  local entries, signatures = {}, {}
  for child in body:iter_children() do
    local kind = child:type()
    if child:named() and kind ~= "comment" and kind ~= "class_static_block" and (include_private or not private_member(mod, child)) then
      if not overload_implementation(mod, child, signatures) then
        entries[#entries + 1] = make_entry(mod, child, render(mod, child))
      end
    end
  end
  return entries
end

-- The entries of a namespace's statements: the exported ones, or all of them
-- in a declare block, where everything is exported.
local function namespace_members(mod, body, ambient)
  local entries, signatures = {}, {}
  for child in body:iter_children() do
    local shown = child:type() == "export_statement" or ((ambient or include_private) and DECLARATIONS[child:type()])
    if shown and not overload_implementation(mod, child, signatures) then
      entries[#entries + 1] = make_entry(mod, child, render(mod, child, nil, ambient))
    end
  end
  return entries
end

-- The view lines of a statement or member, outer, whose declaration is inner:
-- the declaration an export statement wraps, or outer itself.
function render(mod, outer, inner, ambient)
  inner = inner or outer
  local kind = inner:type()
  if kind == "export_statement" then
    local declaration = inner:field("declaration")[1] or inner:field("value")[1]
    return declaration and render(mod, outer, declaration, ambient) or plain(mod, outer, outer)
  elseif CLASSES[kind] then
    local body = inner:field("body")[1]
    return block(mod, outer, body, class_members(mod, body))
  elseif kind == "internal_module" or kind == "module" then
    local body = inner:field("body")[1]
    return body and block(mod, outer, body, namespace_members(mod, body, ambient)) or plain(mod, outer, inner)
  elseif kind == "ambient_declaration" then
    local child = inner:named_child(0)
    if child and child:type() == "statement_block" then
      -- declare global { ... }
      return block(mod, outer, child, namespace_members(mod, child, true))
    end
    return child and render(mod, outer, child, true) or plain(mod, outer, inner)
  end
  return plain(mod, outer, inner)
end

-- The entry for a top-level statement, or nil if the module does not export
-- it: an export statement, a declare statement, or a declaration an export
-- clause names. Non-exported declarations show too when the view keeps them.
local function top_entry(mod, node, signatures)
  local kind = node:type()
  local shown = kind == "export_statement" or kind == "ambient_declaration"
  if not shown and DECLARATIONS[kind] then
    shown = include_private
    for _, name in ipairs(declared_names(mod, node)) do
      shown = shown or mod.exports[name] == true
    end
  end
  if not shown or overload_implementation(mod, node, signatures) then
    return nil
  end
  return make_entry(mod, node, render(mod, node))
end

local function is_default_export(node)
  return node:type() == "export_statement" and child_of_type(node, "default") ~= nil
end

-- The entries of a module's own top-level statements, without its default
-- export if asked.
local function module_entries(mod, skip_default)
  local entries, signatures = {}, {}
  for node in mod.root:iter_children() do
    if not (skip_default and is_default_export(node)) then
      entries[#entries + 1] = top_entry(mod, node, signatures)
    end
  end
  return entries
end

-- The name of the module in the same directory that a statement imports or
-- re-exports from, such as server in `from "./server"` or `from "./server.js"`,
-- or nil.
local function sibling_of(mod, node)
  local source = node:field("source")[1]
  local name = source and text_of(source, mod.src):sub(2, -2):match("^%./([^/]+)$")
  return name and (name:gsub("%.[mc]?[jt]sx?$", ""))
end

local function specifiers(mod, clause, kind)
  local out = {}
  for spec in clause:iter_children() do
    if spec:type() == kind then
      local name, alias = spec:field("name")[1], spec:field("alias")[1]
      local original = text_of(name, mod.src)
      out[#out + 1] = { original = original, bound = alias and text_of(alias, mod.src) or original }
    end
  end
  return out
end

-- Per name a module imports from a module in its directory: that module and
-- the name there, "default" for a default import.
local function imports_of(mod)
  local imports = {}
  for node in mod.root:iter_children() do
    local sibling = node:type() == "import_statement" and sibling_of(mod, node)
    local clause = sibling and child_of_type(node, "import_clause")
    for child in clause and clause:iter_children() or function() end do
      if child:type() == "identifier" then
        imports[text_of(child, mod.src)] = { module = sibling, name = "default" }
      elseif child:type() == "named_imports" then
        for _, spec in ipairs(specifiers(mod, child, "import_specifier")) do
          imports[spec.bound] = { module = sibling, name = spec.original }
        end
      end
    end
  end
  return imports
end

-- The definitions of what the module modname exports as name, following its
-- imports and re-exports from other modules of the directory.
local function resolve(load, modname, name, visited)
  local mod = load(modname)
  if not mod or visited[mod.path] then
    return {}
  end
  visited[mod.path] = true

  local local_name = name
  for node in mod.root:iter_children() do
    if name == "default" and is_default_export(node) then
      return { make_entry(mod, node, render(mod, node)) }
    end
    local clause = node:type() == "export_statement" and not node:field("source")[1] and child_of_type(node, "export_clause")
    for _, spec in ipairs(clause and specifiers(mod, clause, "export_specifier") or {}) do
      if spec.bound == name then
        local_name = spec.original
      end
    end
  end

  local found, signatures = {}, {}
  for node in mod.root:iter_children() do
    if vim.tbl_contains(declared_names(mod, node), local_name) and not overload_implementation(mod, node, signatures) then
      found[#found + 1] = make_entry(mod, node, render(mod, node))
    end
  end
  if #found > 0 then
    return found
  end

  local imported = imports_of(mod)[local_name]
  if imported then
    return resolve(load, imported.module, imported.name, visited)
  end
  for node in mod.root:iter_children() do
    local sibling = node:type() == "export_statement" and sibling_of(mod, node)
    if sibling then
      local clause = child_of_type(node, "export_clause")
      if not clause and not child_of_type(node, "namespace_export") then
        -- export * from "./x"
        found = resolve(load, sibling, name, visited)
        if #found > 0 then
          return found
        end
      end
      for _, spec in ipairs(clause and specifiers(mod, clause, "export_specifier") or {}) do
        if spec.bound == name then
          return resolve(load, sibling, spec.original, visited)
        end
      end
    end
  end
  return {}
end

-- The barrel's API, from its index.ts: its own entries, and each re-export
-- from another module of the directory followed by the definitions it pulls
-- in.
local function barrel_entries(barrel, load)
  local entries, signatures = {}, {}
  local imports = imports_of(barrel)
  for node in barrel.root:iter_children() do
    local definitions = {}
    if node:type() == "export_statement" and not node:field("declaration")[1] and not node:field("value")[1] then
      local sibling = sibling_of(barrel, node)
      local clause = child_of_type(node, "export_clause")
      if clause then
        for _, spec in ipairs(specifiers(barrel, clause, "export_specifier")) do
          if sibling then
            vim.list_extend(definitions, resolve(load, sibling, spec.original, {}))
          elseif imports[spec.original] then
            -- import { X } from "./x"; export { X }
            local imported = imports[spec.original]
            vim.list_extend(definitions, resolve(load, imported.module, imported.name, {}))
          end
        end
      elseif sibling and load(sibling) then
        -- export * from "./x", or export * as x from "./x"
        definitions = module_entries(load(sibling), true)
      end
    end
    if #definitions > 0 then
      local lines = leading_comments(barrel, node)
      vim.list_extend(lines, copy(barrel, node:start(), (node:end_())))
      entries[#entries + 1] = { lines = join(definitions, lines), group = true }
    else
      entries[#entries + 1] = top_entry(barrel, node, signatures)
    end
  end
  return entries
end

local function barrel_of(sources)
  local found
  for _, source in ipairs(sources) do
    if is_barrel(source.path) and (not found or source.path:match("%.ts$")) then
      found = source
    end
  end
  return found
end

-- The view's lines and their source positions, and how many entries it has.
local function view(sources)
  local barrel = barrel_of(sources)
  local entries
  if barrel then
    local parsed = {}
    local function load(modname)
      if parsed[modname] == nil then
        parsed[modname] = false
        for _, ext in ipairs(EXTENSIONS) do
          for _, source in ipairs(sources) do
            if not parsed[modname] and dirname(source.path) == dirname(barrel.path) and basename(source.path) == modname .. ext then
              parsed[modname] = parse(source)
            end
          end
        end
      end
      return parsed[modname] or nil
    end
    entries = barrel_entries(parse(barrel), load)
  else
    entries = module_entries(parse(sources[1]))
  end
  local lines, targets = {}, {}
  for i, line in ipairs(join(entries)) do
    lines[i] = line.text
    if line.row then
      targets[i] = { file = line.file, line = line.row + 1 }
    end
  end
  return lines, targets, #entries
end

-- Whether path is a test file: *.test.ts, *.spec.ts and their .tsx, .mts and
-- .cts forms, or any TypeScript file under a __tests__, test or tests
-- directory.
function M.is_test(path)
  local name = basename(path)
  if not M.in_package(name) then
    return false
  end
  return name:match("%.test%.[mc]?tsx?$") ~= nil or name:match("%.spec%.[mc]?tsx?$") ~= nil or ("/" .. path):match("/__tests__/") ~= nil or ("/" .. path):match("/tests?/") ~= nil
end

-- Whether a file name is part of a module's directory: a TypeScript file.
function M.in_package(name)
  return name:match("%.[mc]?ts$") ~= nil or name:match("%.tsx$") ~= nil
end

-- The paths of sources that the barrel's view shows anything from, as a
-- set, or nil if sources have no index.ts. sources are one directory's.
function M.covered(sources)
  local barrel = barrel_of(sources)
  if not barrel then
    return nil
  end
  local covered = { [barrel.path] = true }
  -- What the default view shows decides it.
  local comments, private = include_comments, include_private
  include_comments, include_private = false, false
  local _, targets = view(sources)
  include_comments, include_private = comments, private
  for _, target in pairs(targets) do
    covered[target.file] = true
  end
  return covered
end

-- The sources the view of path's module covers, out of its directory's
-- sources: the whole directory if path is its index.ts or index.ts re-exports
-- from it, else path alone. Empty if path is not among them.
function M.select(sources, path)
  local covered = M.covered(sources)
  if covered and covered[path] then
    return sources
  end
  for _, source in ipairs(sources) do
    if source.path == path then
      return { source }
    end
  end
  return {}
end

-- The files that make up the view of path's module, and the view's name: the
-- directory for a barrel view, else path.
function M.files(path)
  path = vim.fn.fnamemodify(path, ":p")
  local dir = dirname(path)
  local sources = {}
  local function add(file)
    if vim.fn.filereadable(file) == 1 then
      sources[#sources + 1] = { path = file, text = table.concat(vim.fn.readfile(file), "\n") }
    end
  end
  add(path)
  if not is_barrel(path) then
    add(dir .. "/index.ts")
    add(dir .. "/index.tsx")
  end
  -- Read the directory's other modules only when the barrel pulls from them.
  local barrel = barrel_of(sources)
  if barrel and barrel.text:find("from", 1, true) then
    for _, file in ipairs(vim.fn.glob(dir .. "/*", false, true)) do
      if M.in_package(file) and file ~= path and not is_barrel(file) then
        add(file)
      end
    end
  end
  local selected = M.select(sources, path)
  local files = vim.tbl_map(function(source)
    return source.path
  end, selected)
  return files, #selected == 1 and path or dir
end

-- The API view of a module's sources, given as { { path, text }, ... }: the
-- barrel view if they include an index.ts, else the first source's.
-- opts.comments = false leaves out comments, and opts.private = true adds
-- non-exported declarations and private members. Returns the view's lines,
-- and per line the source position it came from, as { [line] = { file, line } }.
-- Returns nil if the module exports nothing.
function M.extract(sources, opts)
  include_comments = not opts or opts.comments ~= false
  include_private = opts ~= nil and opts.private == true
  if #sources == 0 then
    return nil
  end
  local lines, targets, count = view(sources)
  if count == 0 then
    return nil
  end
  return lines, targets
end

return M
