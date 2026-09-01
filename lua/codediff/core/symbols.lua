-- Treesitter-based symbol extraction for structural diff features.
-- Maps buffer/string content to a tree of function/method/class-like symbols,
-- diff hunk ranges to the symbols that enclose them, and changed ranges to a
-- seam-vs-implementation classification.
local M = {}

-- Per-language node type sets:
--   callable:       function/method-like nodes whose body is "implementation"
--   container:      class/impl-like nodes whose body holds more declarations
--   imports:        import/use statements (excluded from seam classification)
--   value_callable: declarations that become callables when bound to a
--                   function expression (const Foo = () => {}, class props)
--   data:           type-like declarations shown in full by focused seam view
-- Languages not listed fall back to pattern matching on the node type.
local lang_defs = {
  lua = {
    callable = { function_declaration = true, function_definition = true },
  },
  go = {
    callable = { function_declaration = true, method_declaration = true },
    imports = { import_declaration = true },
    data = { type_declaration = true },
  },
  python = {
    callable = { function_definition = true },
    container = { class_definition = true },
    imports = { import_statement = true, import_from_statement = true },
  },
  javascript = {
    callable = { function_declaration = true, method_definition = true },
    container = { class_declaration = true },
    imports = { import_statement = true },
    value_callable = { variable_declarator = true, field_definition = true },
  },
  typescript = {
    callable = { function_declaration = true, method_definition = true },
    container = { class_declaration = true },
    imports = { import_statement = true },
    value_callable = { variable_declarator = true, public_field_definition = true },
    data = { interface_declaration = true, type_alias_declaration = true, enum_declaration = true },
  },
  tsx = {
    callable = { function_declaration = true, method_definition = true },
    container = { class_declaration = true },
    imports = { import_statement = true },
    value_callable = { variable_declarator = true, public_field_definition = true },
    data = { interface_declaration = true, type_alias_declaration = true, enum_declaration = true },
  },
  rust = {
    callable = { function_item = true },
    container = { impl_item = true, trait_item = true },
    imports = { use_declaration = true },
    data = { struct_item = true, enum_item = true, union_item = true, type_item = true, trait_item = true },
  },
  c = {
    callable = { function_definition = true },
    imports = { preproc_include = true },
    data = { struct_specifier = true, union_specifier = true, enum_specifier = true, type_definition = true },
  },
  cpp = {
    callable = { function_definition = true },
    imports = { preproc_include = true },
    data = { struct_specifier = true, union_specifier = true, enum_specifier = true, type_definition = true },
  },
  java = {
    callable = { method_declaration = true, constructor_declaration = true },
    container = { class_declaration = true, interface_declaration = true },
    imports = { import_declaration = true },
    data = { interface_declaration = true, enum_declaration = true, record_declaration = true, annotation_type_declaration = true },
  },
}

local fallback_callable_patterns = { "function_declaration", "function_definition", "method_" }
local fallback_container_patterns = { "class_" }

-- Function expressions that can be bound to a declaration name
local function_expression_types = {
  arrow_function = true,
  function_expression = true,
  ["function"] = true, -- older javascript grammars
}

local function match_patterns(node_type, patterns)
  for _, pattern in ipairs(patterns) do
    if node_type:find(pattern, 1, true) then
      return true
    end
  end
  return false
end

local function classify_node(node_type, defs)
  if defs then
    if defs.callable and defs.callable[node_type] then
      return "callable"
    end
    if defs.container and defs.container[node_type] then
      return "container"
    end
    if defs.imports and defs.imports[node_type] then
      return "import"
    end
    return nil
  end
  if match_patterns(node_type, fallback_container_patterns) then
    return "container"
  end
  if match_patterns(node_type, fallback_callable_patterns) then
    return "callable"
  end
  return nil
end

---The function expression a declaration is bound to, or nil.
---Covers `const Foo = () => {}` and one level of higher-order wrapper call
---(`React.memo(...)`, `forwardRef(...)`, `observer(...)`); a wrapper taking
---more than one function argument is ambiguous and left alone.
local function bound_function(node, defs)
  if not (defs and defs.value_callable and defs.value_callable[node:type()]) then
    return nil
  end
  local value = node:field("value")[1]
  if not value then
    return nil
  end
  if function_expression_types[value:type()] then
    return value
  end
  if value:type() ~= "call_expression" then
    return nil
  end
  local args = value:field("arguments")[1]
  if not args then
    return nil
  end
  local found
  for child in args:iter_children() do
    if function_expression_types[child:type()] then
      if found then
        return nil
      end
      found = child
    end
  end
  return found
end

local function node_name(node, source)
  local name_node = node:field("name")[1]
  if name_node then
    local ok, text = pcall(vim.treesitter.get_node_text, name_node, source)
    if ok then
      return text
    end
  end
  return nil
end

---@class codediff.Symbol
---@field name string|nil
---@field kind string Treesitter node type
---@field container boolean Class/impl-like: body holds declarations, not implementation
---@field start_line number 1-based, inclusive
---@field end_line number 1-based, inclusive
---@field fold_start number First body line to hide when folding (start_line < fold_start)
---@field children codediff.Symbol[]

---First line to hide when folding this symbol's body.
---Brace-style bodies (`) {` at the end of the signature) start folding on the
---next line so multi-line signatures stay fully visible; indented bodies
---(python, lua) fold from the body's own first line.
local function compute_fold_start(node, start_row, lines)
  local body = node:field("body")[1]
  if body then
    local brow, bcol = body:range()
    local line = lines[brow + 1] or ""
    if line:sub(1, bcol):match("^%s*$") then
      return math.max(start_row + 2, brow + 1)
    end
    return math.max(start_row + 2, brow + 2)
  end
  return start_row + 2
end

local function node_end_line(node)
  local start_row, _, end_row, end_col = node:range()
  return (end_col == 0 and end_row > start_row) and end_row or end_row + 1
end

---Collect symbol nodes below `node` into `result`, nesting children.
---Import statements and top-level data declarations are collected flat.
local function collect(node, ctx, result, imports, data, inside_symbol, inside_data)
  for child in node:iter_children() do
    local child_type = child:type()
    local class = classify_node(child_type, ctx.defs)
    local is_data = not inside_symbol and not inside_data and ctx.defs and ctx.defs.data and ctx.defs.data[child_type]
    if is_data then
      local start_row = child:range()
      table.insert(data, { first = start_row + 1, last = node_end_line(child) })
    end

    if class == "import" then
      local start_row = child:range()
      table.insert(imports, { first = start_row + 1, last = node_end_line(child) })
    elseif class == "callable" or class == "container" then
      local start_row = child:range()
      local symbol = {
        name = node_name(child, ctx.source),
        kind = child_type,
        container = class == "container",
        start_line = start_row + 1,
        end_line = node_end_line(child),
        fold_start = compute_fold_start(child, start_row, ctx.lines),
        children = {},
      }
      collect(child, ctx, symbol.children, imports, data, true, inside_data or is_data)
      table.insert(result, symbol)
    else
      -- `const Foo = () => {}`: the declaration names the symbol, the bound
      -- function expression provides the body to fold.
      local fn = bound_function(child, ctx.defs)
      if fn then
        local start_row = child:range()
        local symbol = {
          name = node_name(child, ctx.source),
          kind = child_type,
          container = false,
          start_line = start_row + 1,
          end_line = node_end_line(fn),
          fold_start = compute_fold_start(fn, start_row, ctx.lines),
          children = {},
        }
        collect(fn, ctx, symbol.children, imports, data, true, inside_data or is_data)
        table.insert(result, symbol)
      else
        collect(child, ctx, result, imports, data, inside_symbol, inside_data or is_data)
      end
    end
  end
end

-- Parser names for filetypes core does not map on its own. nvim-treesitter
-- registers these, but codediff must work without it.
local ft_lang_aliases = {
  typescriptreact = "tsx",
  javascriptreact = "javascript",
}

-- Resolved filetype → language cache (false = no parser available).
-- `language.add` cannot be probed portably: on 0.12 it reports failure by
-- return value, on 0.10 by raising — building a throwaway parser is the one
-- check that behaves the same on both.
local lang_cache = {}

local function has_parser(lang)
  return pcall(vim.treesitter.get_string_parser, "", lang)
end

---Resolve a filetype to a treesitter language that has a loadable parser.
---@param ft string|nil
---@return string|nil
local function resolve_lang(ft)
  if not ft or ft == "" then
    return nil
  end
  local cached = lang_cache[ft]
  if cached ~= nil then
    return cached or nil
  end

  local resolved = false
  for _, lang in ipairs({ vim.treesitter.language.get_lang(ft) or ft, ft_lang_aliases[ft] }) do
    if lang and has_parser(lang) then
      resolved = lang
      break
    end
  end

  lang_cache[ft] = resolved
  return resolved or nil
end

---Resolve the treesitter language for a buffer, honoring the filetype
---codediff records on virtual buffers.
---@param bufnr number
---@return string|nil
function M.get_buf_lang(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return nil
  end
  local lang = resolve_lang(vim.b[bufnr].codediff_filetype or vim.bo[bufnr].filetype)
  if lang then
    return lang
  end
  -- Fall back to the path for buffers whose filetype was never detected
  local name = vim.api.nvim_buf_get_name(bufnr)
  return name ~= "" and M.get_path_lang(name) or nil
end

---Resolve the treesitter language for a file path, or nil when unknown.
---@param path string
---@return string|nil
function M.get_path_lang(path)
  return resolve_lang(vim.filetype.match({ filename = path }))
end

---@class codediff.Structure
---@field symbols codediff.Symbol[]
---@field imports { first: number, last: number }[]
---@field data { first: number, last: number }[] Top-level type-like declarations

local function structure_from_root(root, source, lines, lang)
  local result, imports, data = {}, {}, {}
  collect(root, { source = source, lines = lines, defs = lang_defs[lang] }, result, imports, data, false, false)
  return { symbols = result, imports = imports, data = data }
end

---Extract the symbol structure for a buffer.
---Returns nil when no parser is available.
---@param bufnr number
---@return codediff.Structure|nil
function M.get_structure(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return nil
  end

  local lang = M.get_buf_lang(bufnr)
  if not lang then
    return nil
  end

  local ok, parser = pcall(vim.treesitter.get_parser, bufnr, lang)
  if not ok or not parser then
    return nil
  end

  local trees = parser:parse()
  if not trees or not trees[1] then
    return nil
  end

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  return structure_from_root(trees[1]:root(), bufnr, lines, lang)
end

---Extract the symbol structure from string content.
---Returns nil when no parser is available for `lang`.
---@param content string
---@param lang string
---@return codediff.Structure|nil
function M.get_structure_string(content, lang)
  local ok, parser = pcall(vim.treesitter.get_string_parser, content, lang)
  if not ok or not parser then
    return nil
  end

  local trees = parser:parse()
  if not trees or not trees[1] then
    return nil
  end

  local lines = vim.split(content, "\n", { plain = true })
  return structure_from_root(trees[1]:root(), content, lines, lang)
end

---Extract the symbol tree for a buffer (empty list when no parser).
---@param bufnr number
---@return codediff.Symbol[]
function M.get_symbols(bufnr)
  local structure = M.get_structure(bufnr)
  return structure and structure.symbols or {}
end

-- ============================================================================
-- Hunk → symbol mapping
-- ============================================================================

---Check whether a symbol intersects any hunk range on one diff side.
---Ranges use the lines_diff convention: 1-based start, exclusive end.
---An empty range (pure insertion/deletion on the other side) counts as
---touching its anchor line.
---@param symbol codediff.Symbol
---@param ranges { start_line: number, end_line: number }[]
---@return boolean
function M.symbol_intersects(symbol, ranges)
  for _, range in ipairs(ranges) do
    local range_last = range.end_line - 1
    if range.start_line == range.end_line then
      range_last = range.start_line
    end
    if range.start_line <= symbol.end_line and range_last >= symbol.start_line then
      return true
    end
  end
  return false
end

---Flatten the symbols that intersect the given hunk ranges.
---Recurses into children so the innermost enclosing symbols are included.
---@param symbols codediff.Symbol[]
---@param ranges { start_line: number, end_line: number }[]
---@return codediff.Symbol[]
function M.changed_symbols(symbols, ranges)
  local result = {}
  local function visit(list)
    for _, symbol in ipairs(list) do
      if M.symbol_intersects(symbol, ranges) then
        table.insert(result, symbol)
        visit(symbol.children)
      end
    end
  end
  visit(symbols)
  return result
end

-- ============================================================================
-- Seam classification
-- ============================================================================

---Implementation interiors: the body ranges of outermost callables.
---Container bodies are not implementation — they hold more declarations —
---so containers are recursed into instead.
---@param symbols codediff.Symbol[]
---@return { first: number, last: number }[]
function M.impl_ranges(symbols)
  local ranges = {}
  local function visit(list)
    for _, symbol in ipairs(list) do
      if symbol.container then
        visit(symbol.children)
      elseif symbol.end_line >= symbol.fold_start then
        table.insert(ranges, { first = symbol.fold_start, last = symbol.end_line })
      end
    end
  end
  visit(symbols)
  return ranges
end

---Check that sorted, non-overlapping-ish intervals fully cover [first, last].
local function intervals_cover(intervals, first, last)
  local pos = first
  for _, interval in ipairs(intervals) do
    if interval.last >= pos then
      if interval.first > pos then
        return false
      end
      pos = interval.last + 1
      if pos > last then
        return true
      end
    end
  end
  return pos > last
end

---Does any changed line fall outside implementation interiors and imports?
---Changed lines in imports are neither seam nor implementation — they are
---ignored so import churn alone does not count as a seam change.
---@param structure codediff.Structure
---@param changed { first: number, last: number }[] 1-based inclusive ranges
---@return boolean
function M.has_seam_changes(structure, changed)
  local blocked = {}
  vim.list_extend(blocked, M.impl_ranges(structure.symbols))
  vim.list_extend(blocked, structure.imports)
  table.sort(blocked, function(a, b)
    return a.first < b.first
  end)

  for _, range in ipairs(changed) do
    if not intervals_cover(blocked, range.first, range.last) then
      return true
    end
  end
  return false
end

---Classify a file's change as "seam", "impl", or "unsupported".
---old/new content may be nil for pure additions/deletions of the whole file
---(those are always seams). Ranges come from vim.diff indices.
---@param lang string|nil
---@param old_content string|nil
---@param new_content string|nil
---@return "seam"|"impl"|"unsupported"
function M.classify_file(lang, old_content, new_content)
  if not lang then
    return "unsupported"
  end
  if not old_content or not new_content then
    return "seam"
  end

  local hunks = vim.diff(old_content, new_content, { result_type = "indices" })
  if type(hunks) ~= "table" then
    return "unsupported"
  end
  if #hunks == 0 then
    return "impl"
  end

  local old_changed, new_changed = {}, {}
  for _, hunk in ipairs(hunks) do
    local start_a, count_a, start_b, count_b = hunk[1], hunk[2], hunk[3], hunk[4]
    if count_a > 0 then
      table.insert(old_changed, { first = start_a, last = start_a + count_a - 1 })
    end
    if count_b > 0 then
      table.insert(new_changed, { first = start_b, last = start_b + count_b - 1 })
    end
  end

  local new_structure = M.get_structure_string(new_content, lang)
  if not new_structure then
    return "unsupported"
  end
  if #new_changed > 0 and M.has_seam_changes(new_structure, new_changed) then
    return "seam"
  end

  if #old_changed > 0 then
    local old_structure = M.get_structure_string(old_content, lang)
    if not old_structure then
      return "unsupported"
    end
    if M.has_seam_changes(old_structure, old_changed) then
      return "seam"
    end
  end

  return "impl"
end

return M
