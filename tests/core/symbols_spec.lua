-- Tests for treesitter symbol extraction (codediff.core.symbols)
local symbols_mod = require("codediff.core.symbols")

local function make_lua_buffer(lines)
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].filetype = "lua"
  return bufnr
end

describe("core.symbols", function()
  local bufnr

  after_each(function()
    if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end
    bufnr = nil
  end)

  it("extracts top-level functions with names and ranges", function()
    bufnr = make_lua_buffer({
      "local M = {}",
      "",
      "function M.alpha()",
      "  local x = 1",
      "  return x",
      "end",
      "",
      "function M.beta()",
      "  return 2",
      "end",
      "",
      "return M",
    })

    local symbols = symbols_mod.get_symbols(bufnr)
    assert.equals(2, #symbols)

    assert.equals("M.alpha", symbols[1].name)
    assert.equals(3, symbols[1].start_line)
    assert.equals(6, symbols[1].end_line)

    assert.equals("M.beta", symbols[2].name)
    assert.equals(8, symbols[2].start_line)
    assert.equals(10, symbols[2].end_line)
  end)

  it("nests inner functions as children", function()
    bufnr = make_lua_buffer({
      "function outer()",
      "  local function inner()",
      "    return 1",
      "  end",
      "  return inner()",
      "end",
    })

    local symbols = symbols_mod.get_symbols(bufnr)
    assert.equals(1, #symbols)
    assert.equals("outer", symbols[1].name)
    assert.equals(1, #symbols[1].children)
    assert.equals("inner", symbols[1].children[1].name)
    assert.equals(2, symbols[1].children[1].start_line)
    assert.equals(4, symbols[1].children[1].end_line)
  end)

  it("returns empty list without a parser", function()
    bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "plain text" })
    assert.same({}, symbols_mod.get_symbols(bufnr))
  end)

  it("maps hunk ranges to intersecting symbols", function()
    bufnr = make_lua_buffer({
      "function M.alpha()",
      "  return 1",
      "end",
      "",
      "function M.beta()",
      "  return 2",
      "end",
    })

    local symbols = symbols_mod.get_symbols(bufnr)

    -- Hunk touching only beta's body (end exclusive)
    local changed = symbols_mod.changed_symbols(symbols, { { start_line = 6, end_line = 7 } })
    assert.equals(1, #changed)
    assert.equals("M.beta", changed[1].name)

    -- Empty range (insertion anchor) at line 2 touches alpha
    changed = symbols_mod.changed_symbols(symbols, { { start_line = 2, end_line = 2 } })
    assert.equals(1, #changed)
    assert.equals("M.alpha", changed[1].name)

    -- Range in the gap between functions touches neither
    changed = symbols_mod.changed_symbols(symbols, { { start_line = 4, end_line = 5 } })
    assert.equals(0, #changed)
  end)
end)

describe("core.symbols data declarations", function()
  it("collects top-level data types but not local ones", function()
    local source = table.concat({
      "struct User {",
      "  int id;",
      "  const char *name;",
      "};",
      "",
      "void update(void) {",
      "  struct Local {",
      "    int value;",
      "  };",
      "}",
    }, "\n")

    local structure = symbols_mod.get_structure_string(source, "c")
    assert.is_not_nil(structure)
    assert.same({ { first = 1, last = 4 } }, structure.data)
  end)
end)

describe("core.symbols language resolution", function()
  it("maps react filetypes to their parsers without nvim-treesitter", function()
    assert.equals("tsx", symbols_mod.get_path_lang("src/App.tsx"))
    assert.equals("javascript", symbols_mod.get_path_lang("src/App.jsx"))
    assert.equals("typescript", symbols_mod.get_path_lang("src/api.ts"))
  end)

  it("returns nil when no parser exists for the filetype", function()
    assert.is_nil(symbols_mod.get_path_lang("notes.zzzz"))
  end)
end)

describe("core.symbols tsx components", function()
  local tsx = table.concat({
    'import React from "react";',
    "",
    "interface Props {",
    "  label: string;",
    "}",
    "",
    "export const Badge = ({ label }: Props) => {",
    "  const upper = label.toUpperCase();",
    "  return <span>{upper}</span>;",
    "};",
    "",
    "export function Panel({ label }: Props) {",
    "  return <div>{label}</div>;",
    "}",
    "",
    "export const Memoed = React.memo(({ label }: Props) => {",
    "  return <b>{label}</b>;",
    "});",
    "",
    "const settings = { retries: 3 };",
    "",
    "export const Multi = ({",
    "  label,",
    "}: Props) => {",
    "  return <i>{label}</i>;",
    "};",
  }, "\n")

  it("extracts arrow-function and wrapped components alongside declarations", function()
    local structure = symbols_mod.get_structure_string(tsx, "tsx")
    assert.is_not_nil(structure)

    local names = {}
    for _, symbol in ipairs(structure.symbols) do
      table.insert(names, symbol.name)
    end
    assert.same({ "Badge", "Panel", "Memoed", "Multi" }, names)
  end)

  it("folds below the signature, including multi-line ones", function()
    local structure = symbols_mod.get_structure_string(tsx, "tsx")
    local by_name = {}
    for _, symbol in ipairs(structure.symbols) do
      by_name[symbol.name] = symbol
    end

    -- Badge: signature on line 7, body folds from 8 through the closing brace
    assert.equals(7, by_name.Badge.start_line)
    assert.equals(8, by_name.Badge.fold_start)
    assert.equals(10, by_name.Badge.end_line)

    -- Multi's signature spans lines 22-24, so folding starts after it
    assert.equals(22, by_name.Multi.start_line)
    assert.equals(25, by_name.Multi.fold_start)
  end)

  it("ignores non-function consts", function()
    local structure = symbols_mod.get_structure_string(tsx, "tsx")
    for _, symbol in ipairs(structure.symbols) do
      assert.are_not.equal("settings", symbol.name)
    end
  end)

  it("classifies component body edits as impl and prop changes as seam", function()
    local body_edit = tsx:gsub("label%.toUpperCase%(%)", "label.trim().toUpperCase()")
    assert.equals("impl", symbols_mod.classify_file("tsx", tsx, body_edit))

    local prop_edit = tsx:gsub("export const Badge = %({ label }: Props%)", "export const Badge = ({ label, size }: Props)")
    assert.equals("seam", symbols_mod.classify_file("tsx", tsx, prop_edit))

    local interface_edit = tsx:gsub("  label: string;", "  label: string;\n  size?: number;")
    assert.equals("seam", symbols_mod.classify_file("tsx", tsx, interface_edit))
  end)
end)

describe("core.symbols.classify_file", function()
  local base = table.concat({
    "local M = {}",
    "",
    "function M.alpha(a, b)",
    "  local x = a + b",
    "  return x",
    "end",
    "",
    "function M.beta()",
    "  return 2",
    "end",
    "",
    "return M",
  }, "\n")

  it("classifies body-only edits as impl", function()
    local edited = base:gsub("a %+ b", "a * b")
    assert.equals("impl", symbols_mod.classify_file("lua", base, edited))
  end)

  it("classifies signature changes as seam", function()
    local edited = base:gsub("M%.alpha%(a, b%)", "M.alpha(a, b, c)")
    assert.equals("seam", symbols_mod.classify_file("lua", base, edited))
  end)

  it("classifies added functions as seam", function()
    local edited = base:gsub("return M", "function M.gamma()\n  return 3\nend\n\nreturn M")
    assert.equals("seam", symbols_mod.classify_file("lua", base, edited))
  end)

  it("classifies deleted functions as seam", function()
    local edited = base:gsub("function M%.beta%(%)\n  return 2\nend\n\n", "")
    assert.equals("seam", symbols_mod.classify_file("lua", base, edited))
  end)

  it("classifies top-level edits as seam", function()
    local edited = base:gsub("local M = {}", "local M = { version = 2 }")
    assert.equals("seam", symbols_mod.classify_file("lua", base, edited))
  end)

  it("returns unsupported without a lang or parser", function()
    assert.equals("unsupported", symbols_mod.classify_file(nil, base, base))
    assert.equals("unsupported", symbols_mod.classify_file("nosuchlang", base, base .. "\nx = 1"))
  end)

  it("treats missing content (new/deleted files) as seam", function()
    assert.equals("seam", symbols_mod.classify_file("lua", nil, base))
    assert.equals("seam", symbols_mod.classify_file("lua", base, nil))
  end)
end)
