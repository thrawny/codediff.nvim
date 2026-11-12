-- Tests: the TypeScript API view

local typescript = require("codediff.api.typescript")
local api = require("codediff.api")

local SERVER = table.concat({
  'import { Base } from "./base";',
  "",
  "export const LIMIT = 10; // max clients",
  "const cache = new Map<string, number>();",
  "",
  "/** Server serves one shop. */",
  "@injectable()",
  "export class Server extends Base {",
  "  /** The server's name. */",
  "  name: string;",
  "  protected port = 80;",
  '  private secret = "";',
  "  #token = 1;",
  "",
  "  constructor(name: string) {",
  "    super();",
  "    this.name = name;",
  "  }",
  "",
  "  get url(): string {",
  '    return "x";',
  "  }",
  "",
  "  private stop(): void {}",
  "}",
  "",
  "export function start(port: number, // the port",
  "                      host?: string): Server {",
  "  return new Server(host);",
  "}",
  "",
  "export function parse(x: string): number;",
  "export function parse(x: number): number;",
  "export function parse(x: any): number {",
  "  return 0;",
  "}",
  "",
  "export const stop = async (server: Server): Promise<void> => {",
  "  await server.close();",
  "};",
  "",
  "export interface Options {",
  "  port: number;",
  "  /* The host. */ host?: string;",
  "}",
  "",
  "export type Id = string | number;",
  "",
  "function helper() {}",
}, "\n")

local function source(path, lines)
  return { path = path, text = table.concat(lines, "\n") }
end

local function write(dir, files)
  vim.fn.mkdir(dir, "p")
  for name, lines in pairs(files) do
    vim.fn.writefile(lines, dir .. "/" .. name)
  end
end

local function target_of(lines, targets, text)
  for i, line in ipairs(lines) do
    if line == text then
      return targets[i]
    end
  end
end

describe("TypeScript API view", function()
  it("shows exported declarations with their signatures and comments", function()
    local lines = typescript.extract({ { path = "/p/server.ts", text = SERVER } })
    assert.are.same({
      "export const LIMIT = 10; // max clients",
      "",
      "/** Server serves one shop. */",
      "@injectable()",
      "export class Server extends Base {",
      "  /** The server's name. */",
      "  name: string;",
      "  protected port = 80;",
      "",
      "  constructor(name: string) ...",
      "",
      "  get url(): string ...",
      "}",
      "",
      "export function start(port: number, // the port",
      "                      host?: string): Server ...",
      "",
      "export function parse(x: string): number;",
      "export function parse(x: number): number;",
      "",
      "export const stop = async (server: Server): Promise<void> => ...",
      "",
      "export interface Options {",
      "  port: number;",
      "  /* The host. */ host?: string;",
      "}",
      "",
      "export type Id = string | number;",
    }, lines)
  end)

  it("maps each line to its source line", function()
    local lines, targets = typescript.extract({ { path = "/p/server.ts", text = SERVER } })
    assert.are.same({ file = "/p/server.ts", line = 11 }, target_of(lines, targets, "  protected port = 80;"))
    assert.are.same({ file = "/p/server.ts", line = 20 }, target_of(lines, targets, "  get url(): string ..."))
    assert.are.same({ file = "/p/server.ts", line = 28 }, target_of(lines, targets, "                      host?: string): Server ..."))
  end)

  it("leaves comments out when asked", function()
    local lines = typescript.extract({ { path = "/p/server.ts", text = SERVER } }, { comments = false })
    assert.are.equal("export const LIMIT = 10;", lines[1])
    assert.are.equal("@injectable()", lines[3])
    assert.is_true(vim.tbl_contains(lines, "export function start(port: number,"))
    assert.is_true(vim.tbl_contains(lines, "  host?: string;"))
    assert.are.equal(0, #vim.fn.filter(vim.deepcopy(lines), "v:val =~# '/\\*\\|//'"))
  end)

  it("adds non-exported declarations and private members when asked", function()
    local lines = typescript.extract({ { path = "/p/server.ts", text = SERVER } }, { comments = false, private = true })
    for _, expected in ipairs({
      "const cache = new Map<string, number>();",
      '  private secret = "";',
      "  #token = 1;",
      "  private stop(): void ...",
      "function helper() ...",
    }) do
      assert.is_true(vim.tbl_contains(lines, expected), "missing: " .. expected)
    end
  end)

  it("shows declarations an export clause names, and default exports", function()
    local lines = typescript.extract({
      source("/p/m.ts", {
        "function run() {}",
        "function hidden() {}",
        "export { run as start };",
        "export default class App {",
        "  render() { return null; }",
        "}",
      }),
    })
    assert.are.same({
      "function run() ...",
      "export { run as start };",
      "export default class App {",
      "  render() ...",
      "}",
    }, lines)
  end)

  it("shows a one-line block as written, and cuts functions in values", function()
    local lines = typescript.extract({
      source("/p/m.ts", {
        "declare global { interface Window { app: App } }",
        "export const Button = forwardRef<HTMLButtonElement, Props>((props, ref) => {",
        "  return null;",
        "});",
        "export namespace Shapes {",
        "  export const unit = 1;",
        "  const scale = 2;",
        "}",
      }),
    })
    assert.are.same({
      "declare global { interface Window { app: App } }",
      "export const Button = forwardRef<HTMLButtonElement, Props>((props, ref) => ...",
      "export namespace Shapes {",
      "  export const unit = 1;",
      "}",
    }, lines)
  end)

  it("returns nil for a module that exports nothing", function()
    assert.is_nil(typescript.extract({ source("/p/main.ts", { 'import { start } from "./server";', "function main() {}", "main();" }) }))
  end)

  it("shows a barrel's re-exports from index.ts", function()
    local sources = {
      source("/p/shop/index.ts", {
        "/** The shop. */",
        'export { Server, start as begin } from "./server";',
        'export * from "./util.js";',
        'export { default as Cart } from "./cart";',
        'import { Price } from "./models";',
        "export { Price };",
        'export * from "./nested/deep";',
        "",
        'export const VERSION = "1.0";',
      }),
      source("/p/shop/server.ts", { "export class Server {}", "", "export function start() {}", "", "export function other() {}" }),
      source("/p/shop/util.ts", { "export function total() {}", "function hidden() {}", "export default 1;" }),
      source("/p/shop/cart.tsx", { "export default function Cart() {", "  return <div />;", "}" }),
      -- models re-exports Price from its own module of the directory.
      source("/p/shop/models.ts", { 'export { Price } from "./price";' }),
      source("/p/shop/price.ts", { "export class Price {", "  amount(): number { return 0; }", "}" }),
    }
    local lines, targets = typescript.extract(sources, { comments = false })
    assert.are.same({
      'export { Server, start as begin } from "./server";',
      "export class Server ...",
      "",
      "export function start() ...",
      "",
      'export * from "./util.js";',
      "export function total() ...",
      "",
      'export { default as Cart } from "./cart";',
      "export default function Cart() ...",
      "",
      "export { Price };",
      "export class Price {",
      "  amount(): number ...",
      "}",
      "",
      'export * from "./nested/deep";',
      "",
      'export const VERSION = "1.0";',
    }, lines)
    assert.are.same({ file = "/p/shop/server.ts", line = 3 }, target_of(lines, targets, "export function start() ..."))
    assert.are.same({ file = "/p/shop/price.ts", line = 2 }, target_of(lines, targets, "  amount(): number ..."))
    assert.are.same({ file = "/p/shop/cart.tsx", line = 1 }, target_of(lines, targets, "export default function Cart() ..."))
  end)

  it("views a re-exported file as its barrel, and any other file alone", function()
    local dir = vim.fn.resolve(vim.fn.tempname())
    write(dir, {
      ["index.ts"] = { 'export { Server } from "./server";' },
      ["server.ts"] = { "export class Server {}" },
      ["util.ts"] = { "export function fmt() {}" },
    })
    local files, name = typescript.files(dir .. "/server.ts")
    table.sort(files)
    assert.are.same({ dir .. "/index.ts", dir .. "/server.ts", dir .. "/util.ts" }, files)
    assert.are.equal(dir, name)
    files, name = typescript.files(dir .. "/util.ts")
    assert.are.same({ dir .. "/util.ts" }, files)
    assert.are.equal(dir .. "/util.ts", name)
    vim.fn.delete(dir, "rf")
  end)

  it("reads TSX files", function()
    local lines = typescript.extract({
      source("/p/button.tsx", {
        "export function Button({ label }: Props) {",
        "  return <button>{label}</button>;",
        "}",
        "export const Icon = () => (",
        "  <svg />",
        ");",
      }),
    })
    assert.are.same({ "export function Button({ label }: Props) ...", "export const Icon = () => ..." }, lines)
    assert.are.equal(typescript, api.language_for_filetype("typescriptreact"))
  end)
end)

describe("TypeScript API browse mode", function()
  local dir

  before_each(function()
    dir = vim.fn.resolve(vim.fn.tempname())
    write(dir, { ["server.ts"] = vim.split(SERVER, "\n") })
    vim.cmd("silent! %bwipeout!")
  end)

  after_each(function()
    if api.is_enabled() then
      api.toggle()
    end
    vim.fn.delete(dir, "rf")
  end)

  it("shows the module's API view for an opened TypeScript file, and <CR> opens the source", function()
    api.toggle()
    vim.cmd("edit " .. dir .. "/server.ts")
    vim.api.nvim_win_set_cursor(0, { 21, 0 })
    vim.wait(1000, function()
      return vim.api.nvim_buf_get_name(0):match("^codediff%-api://") ~= nil
    end)
    assert.are.equal("codediff-api://" .. dir .. "/server.ts", vim.api.nvim_buf_get_name(0))
    assert.are.equal("typescript", vim.bo.filetype)
    -- Line 21 is in url's body, so the cursor lands on url.
    assert.are.equal("  get url(): string ...", vim.api.nvim_get_current_line())

    vim.cmd("/^  protected port")
    vim.api.nvim_feedkeys(vim.keycode("<CR>"), "x", false)
    vim.wait(100)
    assert.are.equal(dir .. "/server.ts", vim.api.nvim_buf_get_name(0))
    assert.are.equal(11, vim.api.nvim_win_get_cursor(0)[1])
  end)
end)

describe("TypeScript API module sources", function()
  it("reads a barrel at a commit and on disk", function()
    local root = vim.fn.resolve(vim.fn.tempname())
    local function git(args)
      vim.fn.system(vim.list_extend({ "git", "-C", root }, args))
    end
    write(root .. "/shop", {
      ["index.ts"] = { 'export { start } from "./server";' },
      ["server.ts"] = { "export function start() {}" },
      ["util.ts"] = { "export function fmt() {}" },
    })
    git({ "init", "-q" })
    git({ "add", "." })
    git({ "-c", "user.name=t", "-c", "user.email=t@example.com", "commit", "-q", "-m", "base" })
    vim.fn.writefile({ "export function start(port: number) {}" }, root .. "/shop/server.ts")

    local function apis(revision, path)
      return typescript.extract(api.module_sources(root, revision, path, typescript), { comments = false })
    end
    assert.are.same({ 'export { start } from "./server";', "export function start() ..." }, apis("HEAD", "shop/server.ts"))
    assert.are.same({ 'export { start } from "./server";', "export function start(port: number) ..." }, apis(nil, "shop/server.ts"))
    -- index.ts does not re-export from util, so util is a module of its own.
    assert.are.same({ "export function fmt() ..." }, apis("HEAD", "shop/util.ts"))
    vim.fn.delete(root, "rf")
  end)
end)
