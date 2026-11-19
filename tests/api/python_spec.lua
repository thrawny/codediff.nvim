-- Tests: the Python API view

local python = require("codediff.api.python")
local api = require("codediff.api")

local SERVER = table.concat({
  '"""Serves the shop."""',
  "import os",
  "",
  "LIMIT: int = 10  # max clients",
  "_cache = {}",
  "",
  "",
  "# Server serves one shop.",
  "@dataclass",
  "class Server(Base):",
  '    """A server."""',
  "",
  "    name: str",
  "    port: int = 80",
  '    _secret: str = ""',
  "",
  "    def __init__(self, name):",
  "        self.name = name",
  "",
  "    @property",
  "    def url(self) -> str:  # cached",
  '        return "x"',
  "",
  "    def _stop(self):",
  "        pass",
  "",
  "",
  "async def start(port: int,  # the port",
  "                host=None) -> Server:",
  '    """Start a server."""',
  "    return Server()",
  "",
  "",
  "def _helper():",
  "    pass",
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

describe("Python API view", function()
  it("shows public declarations as stubs, with docstrings and comments", function()
    local lines = python.extract({ { path = "/p/server.py", text = SERVER } })
    assert.are.same({
      '"""Serves the shop."""',
      "",
      "LIMIT: int = 10  # max clients",
      "",
      "# Server serves one shop.",
      "@dataclass",
      "class Server(Base):",
      '    """A server."""',
      "",
      "    name: str",
      "    port: int = 80",
      "",
      "    def __init__(self, name): ...",
      "",
      "    @property",
      "    def url(self) -> str: ...",
      "",
      "async def start(port: int,  # the port",
      "                host=None) -> Server:",
      '    """Start a server."""',
    }, lines)
  end)

  it("maps each line to its source line", function()
    local lines, targets = python.extract({ { path = "/p/server.py", text = SERVER } })
    assert.are.same({ file = "/p/server.py", line = 14 }, target_of(lines, targets, "    port: int = 80"))
    assert.are.same({ file = "/p/server.py", line = 21 }, target_of(lines, targets, "    def url(self) -> str: ..."))
    assert.are.same({ file = "/p/server.py", line = 29 }, target_of(lines, targets, "                host=None) -> Server:"))
  end)

  it("leaves comments and docstrings out when asked", function()
    local lines = python.extract({ { path = "/p/server.py", text = SERVER } }, { comments = false })
    assert.are.same({
      "LIMIT: int = 10",
      "",
      "@dataclass",
      "class Server(Base):",
      "    name: str",
      "    port: int = 80",
      "",
      "    def __init__(self, name): ...",
      "",
      "    @property",
      "    def url(self) -> str: ...",
      "",
      "async def start(port: int,",
      "                host=None) -> Server: ...",
    }, lines)
  end)

  it("adds private names when asked", function()
    local lines = python.extract({ { path = "/p/server.py", text = SERVER } }, { comments = false, private = true })
    for _, expected in ipairs({ "_cache = {}", '    _secret: str = ""', "    def _stop(self): ...", "def _helper(): ..." }) do
      assert.is_true(vim.tbl_contains(lines, expected), "missing: " .. expected)
    end
  end)

  it("follows __all__, and shows the imports it lists", function()
    local lines = python.extract({
      source("/p/m.py", {
        "from os.path import join",
        "import sys",
        '__all__ = ["run", "join"]',
        "",
        "def run(): pass",
        "",
        "def stop(): pass",
      }),
    })
    assert.are.same({ "from os.path import join", "", "def run(): ..." }, lines)
  end)

  it("returns nil for a module that exports nothing", function()
    assert.is_nil(python.extract({ source("/p/main.py", { "def _main(): pass", "", 'if __name__ == "__main__":', "    _main()" }) }))
  end)

  it("shows a package's re-exports from __init__.py", function()
    local sources = {
      source("/p/shop/__init__.py", {
        '"""The shop."""',
        "from .server import Server, start as begin",
        "from ._impl import *",
        "from .models import Cart",
        "from . import util",
        "",
        'VERSION = "1.0"',
      }),
      source("/p/shop/server.py", { "class Server: pass", "", "def start(): pass", "", "def other(): pass" }),
      source("/p/shop/_impl.py", { "def total(): pass", "def _private(): pass" }),
      -- models re-exports Cart from its own module of the package.
      source("/p/shop/models.py", { "from .cart import Cart" }),
      source("/p/shop/cart.py", { "class Cart:", "    def add(self, item): pass" }),
      source("/p/shop/util.py", { "def fmt(): pass" }),
    }
    local lines, targets = python.extract(sources, { comments = false })
    assert.are.same({
      "from .server import Server, start as begin",
      "class Server: ...",
      "",
      "def start(): ...",
      "",
      "from ._impl import *",
      "def total(): ...",
      "",
      "from .models import Cart",
      "class Cart:",
      "    def add(self, item): ...",
      "",
      'VERSION = "1.0"',
    }, lines)
    assert.are.same({ file = "/p/shop/server.py", line = 3 }, target_of(lines, targets, "def start(): ..."))
    assert.are.same({ file = "/p/shop/cart.py", line = 2 }, target_of(lines, targets, "    def add(self, item): ..."))
  end)

  it("follows a package's fully qualified imports, and shows re-exports from outside it", function()
    local lines = python.extract({
      source("/p/src/app/shop/__init__.py", {
        "from app.shop.server import Server",
        "from os.path import join",
        '__all__ = ["Server", "join"]',
      }),
      source("/p/src/app/shop/server.py", { "class Server: pass" }),
    }, { comments = false })
    assert.are.same({
      "from app.shop.server import Server",
      "class Server: ...",
      "",
      "from os.path import join",
    }, lines)
  end)

  it("views a re-exported file as its package, and any other file alone", function()
    local dir = vim.fn.resolve(vim.fn.tempname())
    write(dir, {
      ["__init__.py"] = { "from .server import Server" },
      ["server.py"] = { "class Server: pass" },
      ["util.py"] = { "def fmt(): pass" },
    })
    local files, name = python.files(dir .. "/server.py")
    table.sort(files)
    assert.are.same({ dir .. "/__init__.py", dir .. "/server.py", dir .. "/util.py" }, files)
    assert.are.equal(dir, name)
    files, name = python.files(dir .. "/util.py")
    assert.are.same({ dir .. "/util.py" }, files)
    assert.are.equal(dir .. "/util.py", name)
    vim.fn.delete(dir, "rf")
  end)
end)

describe("Python API browse mode", function()
  local dir

  before_each(function()
    dir = vim.fn.resolve(vim.fn.tempname())
    write(dir, { ["server.py"] = vim.split(SERVER, "\n") })
    vim.cmd("silent! %bwipeout!")
  end)

  after_each(function()
    if api.is_enabled() then
      api.toggle()
    end
    vim.fn.delete(dir, "rf")
  end)

  it("shows the module's API view for an opened Python file, and <CR> opens the source", function()
    api.toggle()
    vim.cmd("edit " .. dir .. "/server.py")
    vim.api.nvim_win_set_cursor(0, { 22, 0 })
    vim.wait(1000, function()
      return vim.api.nvim_buf_get_name(0):match("^codediff%-api://") ~= nil
    end)
    assert.are.equal("codediff-api://" .. dir .. "/server.py", vim.api.nvim_buf_get_name(0))
    assert.are.equal("python", vim.bo.filetype)
    -- Line 22 is in url's body, so the cursor lands on url.
    assert.are.equal("    def url(self) -> str: ...", vim.api.nvim_get_current_line())

    vim.cmd("/^    port")
    vim.api.nvim_feedkeys(vim.keycode("<CR>"), "x", false)
    vim.wait(100)
    assert.are.equal(dir .. "/server.py", vim.api.nvim_buf_get_name(0))
    assert.are.equal(14, vim.api.nvim_win_get_cursor(0)[1])
  end)
end)

describe("Python API view toggles", function()
  it("C hides docstrings with the cursor on a blank line", function()
    local dir = vim.fn.resolve(vim.fn.tempname())
    write(dir, { ["server.py"] = vim.split(SERVER, "\n") })
    api.open(dir .. "/server.py")
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    assert.are.equal("", vim.api.nvim_get_current_line())
    vim.api.nvim_feedkeys("C", "x", false)
    local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    assert.are.equal("LIMIT: int = 10", lines[1])
    assert.are.equal(0, #vim.fn.filter(lines, 'v:val =~# \'"""\''))
    vim.api.nvim_feedkeys("C", "x", false)
    assert.are.equal('"""Serves the shop."""', vim.api.nvim_buf_get_lines(0, 0, 1, false)[1])
    vim.cmd("close")
    vim.fn.delete(dir, "rf")
  end)
end)

describe("Python API module sources", function()
  it("reads a package at a commit and on disk", function()
    local root = vim.fn.resolve(vim.fn.tempname())
    local function git(args)
      vim.fn.system(vim.list_extend({ "git", "-C", root }, args))
    end
    write(root .. "/shop", {
      ["__init__.py"] = { "from .server import start" },
      ["server.py"] = { "def start(): pass" },
      ["util.py"] = { "def fmt(): pass" },
    })
    git({ "init", "-q" })
    git({ "add", "." })
    git({ "-c", "user.name=t", "-c", "user.email=t@example.com", "commit", "-q", "-m", "base" })
    vim.fn.writefile({ "def start(port): pass" }, root .. "/shop/server.py")

    local function apis(revision, path)
      return python.extract(api.module_sources(root, revision, path, python), { comments = false })
    end
    assert.are.same({ "from .server import start", "def start(): ..." }, apis("HEAD", "shop/server.py"))
    assert.are.same({ "from .server import start", "def start(port): ..." }, apis(nil, "shop/server.py"))
    -- __init__.py does not re-export from util, so util is a module of its own.
    assert.are.same({ "def fmt(): ..." }, apis("HEAD", "shop/util.py"))
    vim.fn.delete(root, "rf")
  end)
end)
