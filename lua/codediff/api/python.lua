-- The API view for Python: what a module exports, like a stub file. Functions
-- and methods show their signatures and docstrings, with `...` for a body
-- without a docstring. Classes show their public attributes, methods and
-- nested classes. Module-level assignments and type aliases show as written.
--
-- A module is one file. A file that its directory's __init__.py re-exports
-- from belongs to the package's view instead: __init__.py's own API, with each
-- re-exporting import followed by the definitions it pulls in from the
-- package's other files.
local M = {}

M.filetype = "python"
-- gd asks any language server that handles Python, such as basedpyright,
-- pyright or pylsp, so there is no fixed name.
M.lsp = nil

-- Whether the view keeps comments and docstrings, and private names. extract
-- sets them for the length of one call.
local include_comments = true
local include_private = false

-- Parsed on first use, so that loading this file needs no Python parser.
local comment_query

local function text_of(node, src)
  return vim.treesitter.get_node_text(node, src)
end

local function basename(path)
  return vim.fn.fnamemodify(path, ":t")
end

local function dirname(path)
  return vim.fn.fnamemodify(path, ":h")
end

-- A public name: no leading underscore, or a dunder such as __init__.
local function public(name)
  return not name:match("^_") or name:match("^__.+__$") ~= nil
end

local function member_shown(name)
  return include_private or public(name)
end

-- The names in a module's __all__, as a set, or nil without one.
local function all_names(root, src)
  local names
  for node in root:iter_children() do
    local statement = node:type() == "expression_statement" and node:named_child(0)
    if statement and (statement:type() == "assignment" or statement:type() == "augmented_assignment") then
      local left, right = statement:field("left")[1], statement:field("right")[1]
      if left and text_of(left, src) == "__all__" and right then
        names = names or {}
        for item in right:iter_children() do
          if item:type() == "string" then
            local content = text_of(item, src):match("^[%a]*['\"]+(.-)['\"]+$")
            if content then
              names[content] = true
            end
          end
        end
      end
    end
  end
  return names
end

-- A parsed source: its path, text, lines, tree, __all__, and per row the
-- column a comment starts at. A Python comment runs to the end of its line.
local function parse(source)
  local root = vim.treesitter.get_string_parser(source.text, "python"):parse()[1]:root()
  comment_query = comment_query or vim.treesitter.query.parse("python", "(comment) @comment")
  local comment_col = {}
  for _, node in comment_query:iter_captures(root, source.text) do
    local row, col = node:start()
    comment_col[row] = col
  end
  return {
    path = source.path,
    src = source.text,
    lines = vim.split(source.text, "\n"),
    root = root,
    comment_col = comment_col,
    all = all_names(root, source.text),
  }
end

-- Source rows first to last (0-based) as view lines, the last cut after byte
-- last_col. With comments hidden, comments are cut out, and lines that leaves
-- blank are dropped.
local function copy(mod, first, last, last_col)
  local out = {}
  for row = first, last do
    local line = mod.lines[row + 1] or ""
    if row == last and last_col then
      line = line:sub(1, last_col)
    end
    local col = not include_comments and mod.comment_col[row]
    if col and col < #line then
      line = (line:sub(1, col):gsub("%s+$", ""))
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

-- The statement before a node: its previous sibling, or for the first
-- statement of a block, what comes before the block, such as a comment after
-- a class's colon.
local function before(node)
  local prev = node:prev_sibling()
  if not prev and node:parent() and node:parent():type() == "block" then
    prev = node:parent():prev_sibling()
  end
  return prev
end

-- The run of comments right above a node, at its column.
local function leading_comments(mod, node)
  if not include_comments then
    return {}
  end
  local row, col = node:start()
  local first
  local prev = before(node)
  while prev and prev:type() == "comment" and prev:end_() == row - 1 and select(2, prev:start()) == col do
    first = prev
    row = prev:start()
    prev = before(prev)
  end
  return first and copy(mod, first:start(), node:start() - 1) or {}
end

local function is_string_statement(node)
  if not node or node:type() ~= "expression_statement" or node:named_child_count() ~= 1 then
    return false
  end
  local kind = node:named_child(0):type()
  return kind == "string" or kind == "concatenated_string"
end

-- The first statement of a block, past any comments.
local function first_statement(block)
  for child in block:iter_children() do
    if child:named() and child:type() ~= "comment" then
      return child
    end
  end
end

-- A def's or class's lines up to its colon, decorators included, then its
-- docstring if comments show. Returns the lines, and whether a docstring is in
-- them.
local function header(mod, node, def)
  local body = def:field("body")[1]
  local colon
  for child in def:iter_children() do
    if body and child:id() == body:id() then
      break
    end
    if child:type() == ":" then
      colon = child
    end
  end
  local row, col = colon:end_()
  local lines = copy(mod, node:start(), row, col)
  local doc = include_comments and body and first_statement(body)
  if not is_string_statement(doc) then
    return lines, false
  end
  if doc:start() > row then
    vim.list_extend(lines, copy(mod, doc:start(), doc:end_()))
  else
    -- A docstring on the def's own line.
    lines[#lines].text = lines[#lines].text .. " " .. text_of(doc, mod.src)
  end
  return lines, true
end

local function import_names(mod, node)
  -- Per imported name: the name it binds and the name it has in its module.
  local names = {}
  for _, name in ipairs(node:field("name")) do
    if name:type() == "aliased_import" then
      names[#names + 1] = { bound = text_of(name:field("alias")[1], mod.src), original = text_of(name:field("name")[1], mod.src) }
    else
      local text = text_of(name, mod.src)
      -- `import a.b` binds a, `from m import b` binds b.
      names[#names + 1] = { bound = text:match("^[%w_]+"), original = text }
    end
  end
  return names
end

-- The names a top-level or class-level statement defines.
local function names_of(mod, node)
  local kind = node:type()
  if kind == "decorated_definition" then
    return names_of(mod, node:field("definition")[1])
  elseif kind == "function_definition" or kind == "class_definition" then
    return { text_of(node:field("name")[1], mod.src) }
  elseif kind == "type_alias_statement" then
    local name = node:named_child(0)
    return { name and text_of(name, mod.src):match("^[%w_]+") }
  elseif kind == "expression_statement" then
    local assignment = node:named_child(0)
    if not assignment or assignment:type() ~= "assignment" then
      return {}
    end
    local left = assignment:field("left")[1]
    if left:type() == "identifier" then
      return { text_of(left, mod.src) }
    end
    local names = {}
    for child in left:iter_children() do
      if child:type() == "identifier" then
        names[#names + 1] = text_of(child, mod.src)
      end
    end
    return names
  end
  return {}
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

-- Join entries into view lines, after prev if given, with a blank line between
-- two entries that are apart in the source.
local function join(entries, out, prev)
  out = out or {}
  for _, entry in ipairs(entries) do
    if prev and apart(prev, entry) then
      out[#out + 1] = { text = "" }
    end
    vim.list_extend(out, entry.lines)
    prev = entry
  end
  return out
end

local entry

-- The entries of a class body's statements.
local function members(mod, block)
  local entries = {}
  for child in block:iter_children() do
    local member = entry(mod, child, member_shown)
    if member then
      entries[#entries + 1] = member
    end
  end
  return entries
end

-- The entry for one statement, or nil if it defines no shown name: its lines,
-- its module, and the source rows it spans, leading comments included.
function entry(mod, node, shown)
  local names = names_of(mod, node)
  local any = false
  for _, name in ipairs(names) do
    any = any or shown(name)
  end
  if not any then
    return nil
  end

  local lines = leading_comments(mod, node)
  local def = node:type() == "decorated_definition" and node:field("definition")[1] or node
  if def:type() == "function_definition" or def:type() == "class_definition" then
    local head, documented = header(mod, node, def)
    local body = def:type() == "class_definition" and members(mod, def:field("body")[1]) or {}
    if not documented and #body == 0 then
      head[#head].text = head[#head].text .. " ..."
    end
    vim.list_extend(lines, head)
    -- The first member follows the header, or its docstring as in the source.
    join(body, lines, documented and { mod = mod, last = head[#head].row } or nil)
  else
    vim.list_extend(lines, copy(mod, node:start(), (node:end_())))
    -- An attribute docstring: a string right below an assignment.
    local next = node:next_named_sibling()
    if include_comments and is_string_statement(next) and next:start() == node:end_() + 1 then
      vim.list_extend(lines, copy(mod, next:start(), (next:end_())))
    end
  end
  return { lines = lines, mod = mod, first = lines[1].row, last = (node:end_()) }
end

-- Whether a top-level name is in a module's API: in __all__ if it has one,
-- else public. __all__ itself is not.
local function module_shown(mod)
  return function(name)
    if name == "__all__" then
      return false
    end
    if include_private then
      return true
    end
    if mod.all then
      return mod.all[name] == true
    end
    return public(name)
  end
end

-- The name of the package-local module an import pulls from, such as server in
-- `from .server import X`, `from shop.server import X` or
-- `from app.shop.server import X` within shop, or nil.
local function sibling_module(mod, node)
  local module_name = node:field("module_name")[1]
  if not module_name then
    return nil
  end
  local text = text_of(module_name, mod.src)
  local package = vim.pesc(basename(dirname(mod.path)))
  return text:match("^%.([%w_]+)$") or text:match("^" .. package .. "%.([%w_]+)$") or text:match("%." .. package .. "%.([%w_]+)$")
end

-- An import's entry if it binds a name in the module's __all__, else nil.
local function import_entry(mod, node)
  for _, name in ipairs(import_names(mod, node)) do
    if mod.all and mod.all[name.bound] then
      return { lines = copy(mod, node:start(), (node:end_())), mod = mod, first = node:start(), last = (node:end_()) }
    end
  end
end

local function module_docstring(mod)
  local first = first_statement(mod.root)
  if include_comments and is_string_statement(first) then
    return { lines = copy(mod, first:start(), (first:end_())), group = true }
  end
end

-- The entries of a module's own top-level statements. Imports show when
-- __all__ lists a name they bind.
local function module_entries(mod)
  local entries, shown = {}, module_shown(mod)
  for node in mod.root:iter_children() do
    local kind = node:type()
    if kind == "import_statement" or kind == "import_from_statement" then
      entries[#entries + 1] = import_entry(mod, node)
    else
      entries[#entries + 1] = entry(mod, node, shown)
    end
  end
  return entries
end

-- The definitions of name in the package module modname, following its own
-- imports from other modules of the package.
local function resolve(load, modname, name, visited)
  local mod = load(modname)
  if not mod or visited[modname] then
    return {}
  end
  visited[modname] = true
  local found = {}
  local function is_name(n)
    return n == name
  end
  for node in mod.root:iter_children() do
    found[#found + 1] = entry(mod, node, is_name)
  end
  if #found > 0 then
    return found
  end
  for node in mod.root:iter_children() do
    local sibling = node:type() == "import_from_statement" and sibling_module(mod, node)
    if sibling then
      for _, imported in ipairs(import_names(mod, node)) do
        if imported.bound == name then
          return resolve(load, sibling, imported.original, visited)
        end
      end
    end
  end
  return {}
end

-- The package's API, from its __init__.py: its own entries, and each import
-- from another module of the package followed by the definitions it
-- re-exports.
local function package_entries(init, load)
  local entries, shown = {}, module_shown(init)
  for node in init.root:iter_children() do
    local sibling = node:type() == "import_from_statement" and sibling_module(init, node)
    if sibling then
      local definitions = {}
      local wildcard = false
      for child in node:iter_children() do
        wildcard = wildcard or child:type() == "wildcard_import"
      end
      if wildcard then
        local mod = load(sibling)
        definitions = mod and module_entries(mod) or {}
      else
        for _, imported in ipairs(import_names(init, node)) do
          if shown(imported.bound) then
            vim.list_extend(definitions, resolve(load, sibling, imported.original, {}))
          end
        end
      end
      if #definitions > 0 then
        local lines = copy(init, node:start(), (node:end_()))
        entries[#entries + 1] = { lines = join(definitions, lines), group = true }
      else
        entries[#entries + 1] = import_entry(init, node)
      end
    elseif node:type() == "import_statement" or node:type() == "import_from_statement" then
      -- A re-export from outside the package shows as its import.
      entries[#entries + 1] = import_entry(init, node)
    else
      entries[#entries + 1] = entry(init, node, shown)
    end
  end
  return entries
end

local function init_of(sources)
  for _, source in ipairs(sources) do
    if basename(source.path) == "__init__.py" then
      return source
    end
  end
end

-- The view's lines and their source positions, and how many entries it has.
local function view(sources)
  local init = init_of(sources)
  local mod, entries
  if init then
    local parsed = {}
    local function load(modname)
      if parsed[modname] == nil then
        parsed[modname] = false
        for _, source in ipairs(sources) do
          if dirname(source.path) == dirname(init.path) and basename(source.path) == modname .. ".py" then
            parsed[modname] = parse(source)
          end
        end
      end
      return parsed[modname] or nil
    end
    mod = parse(init)
    entries = package_entries(mod, load)
  else
    mod = parse(sources[1])
    entries = module_entries(mod)
  end
  local count = #entries
  local doc = module_docstring(mod)
  if doc then
    table.insert(entries, 1, doc)
  end
  local lines, targets = {}, {}
  for i, line in ipairs(join(entries)) do
    lines[i] = line.text
    if line.row then
      targets[i] = { file = line.file, line = line.row + 1 }
    end
  end
  return lines, targets, count
end

-- Whether path is a test file, as pytest finds them: test_*.py, *_test.py,
-- conftest.py, or any Python file under a test or tests directory.
function M.is_test(path)
  local name = basename(path)
  return name:match("^test_.*%.py$") ~= nil or name:match("_test%.py$") ~= nil or name == "conftest.py" or (("/" .. path):match("/tests?/") ~= nil and name:match("%.py$") ~= nil)
end

-- Whether a file name is part of a package: a Python file.
function M.in_package(name)
  return name:match("%.py$") ~= nil
end

-- The paths of sources that the package's view shows anything from, as a
-- set, or nil if sources have no __init__.py. sources are one directory's.
function M.covered(sources)
  local init = init_of(sources)
  if not init then
    return nil
  end
  local covered = { [init.path] = true }
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
-- sources: the whole package if path is its __init__.py or __init__.py
-- re-exports from it, else path alone. Empty if path is not among them.
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
-- package directory for a package view, else path.
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
  if basename(path) ~= "__init__.py" and vim.fn.filereadable(dir .. "/__init__.py") == 1 then
    add(dir .. "/__init__.py")
  end
  -- Read the package's other modules only when __init__.py imports from them.
  local init = init_of(sources)
  if init and init.text:find("import", 1, true) then
    for _, file in ipairs(vim.fn.glob(dir .. "/*.py", false, true)) do
      if file ~= path and file ~= init.path then
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
-- package view if they include an __init__.py, else the first source's.
-- opts.comments = false leaves out comments and docstrings, and opts.private =
-- true adds private names. Returns the view's lines, and per line the source
-- position it came from, as { [line] = { file, line } }. Returns nil if the
-- module exports nothing.
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
