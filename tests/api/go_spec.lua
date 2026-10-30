-- Tests: the Go API view and browse mode

local go = require("codediff.api.go")
local api = require("codediff.api")

local SERVER = table.concat({
  "package shop",
  "",
  "const (",
  "\tLimit = 10",
  "\tlimit = 5",
  ")",
  "",
  "var errClosed = 1",
  "",
  "type Server struct {",
  "\tName string",
  "\tport int",
  "\tsync.Mutex",
  "}",
  "",
  "func (s *Server) Start() error {",
  "\treturn nil",
  "}",
  "",
  "func (s *Server) stop() {}",
  "",
  "type cache struct{}",
  "",
  "func (c *cache) Get() {}",
  "",
  "func New(name string) *Server {",
  "\treturn &Server{Name: name}",
  "}",
  "",
  "func helper() {}",
}, "\n")

local STORE = table.concat({
  "package shop",
  "",
  "type Store interface {",
  "\tSave(id string) error",
  "\tload()",
  "}",
}, "\n")

local function write_package(dir)
  vim.fn.mkdir(dir, "p")
  vim.fn.writefile(vim.split(SERVER, "\n"), dir .. "/server.go")
  vim.fn.writefile(vim.split(STORE, "\n"), dir .. "/store.go")
  vim.fn.writefile({ "package shop", "", "func TestX() {}" }, dir .. "/server_test.go")
end

describe("Go API view", function()
  it("shows only exported declarations, without bodies", function()
    local lines = go.extract({
      { path = "/p/server.go", text = SERVER },
      { path = "/p/store.go", text = STORE },
    })
    assert.are.same({
      "package shop",
      "",
      "const (",
      "\tLimit = 10",
      ")",
      "",
      "func New(name string) *Server",
      "",
      "type Server struct {",
      "\tName string",
      "\tsync.Mutex",
      "}",
      "func (s *Server) Start() error",
      "",
      "type Store interface {",
      "\tSave(id string) error",
      "}",
    }, lines)
  end)

  it("maps each line to its source line", function()
    local lines, targets = go.extract({ { path = "/p/server.go", text = SERVER } })
    local function target_of(text)
      for i, line in ipairs(lines) do
        if line == text then
          return targets[i]
        end
      end
    end
    assert.are.same({ file = "/p/server.go", line = 4 }, target_of("\tLimit = 10"))
    assert.are.same({ file = "/p/server.go", line = 11 }, target_of("\tName string"))
    assert.are.same({ file = "/p/server.go", line = 16 }, target_of("func (s *Server) Start() error"))
  end)

  it("returns nil for a package that exports nothing", function()
    assert.is_nil(go.extract({ { path = "/p/main.go", text = "package main\n\nfunc main() {}" } }))
  end)

  it("leaves test files out of the package", function()
    local dir = vim.fn.tempname()
    write_package(dir)
    local files = go.files(dir .. "/server.go")
    table.sort(files)
    assert.are.same({ dir .. "/server.go", dir .. "/store.go" }, files)
    assert.is_nil(go.files(dir .. "/server_test.go"))
  end)
end)

describe("API browse mode", function()
  local dir

  before_each(function()
    dir = vim.fn.tempname()
    write_package(dir)
    -- On macOS the temp directory is a symlink. Buffer names use the real path.
    dir = vim.fn.resolve(dir)
    vim.cmd("silent! %bwipeout!")
  end)

  after_each(function()
    if api.is_enabled() then
      api.toggle()
    end
  end)

  it("shows the package API view for an opened Go file, and <CR> opens the source", function()
    api.toggle()
    vim.cmd("edit " .. dir .. "/server.go")
    vim.api.nvim_win_set_cursor(0, { 17, 0 })
    -- The redirect runs on the next event loop turn.
    vim.wait(1000, function()
      return vim.api.nvim_buf_get_name(0):match("^codediff%-api://") ~= nil
    end)
    assert.are.equal("codediff-api://" .. dir, vim.api.nvim_buf_get_name(0))
    -- Line 17 is in Start's body, so the cursor lands on Start.
    assert.are.equal("func (s *Server) Start() error", vim.api.nvim_get_current_line())

    vim.cmd("/^\\tName")
    vim.api.nvim_feedkeys(vim.keycode("<CR>"), "x", false)
    vim.wait(100)
    assert.are.equal(dir .. "/server.go", vim.api.nvim_buf_get_name(0))
    assert.are.equal(11, vim.api.nvim_win_get_cursor(0)[1])
  end)

  it("leaves test files as they are", function()
    api.toggle()
    vim.cmd("edit " .. dir .. "/server_test.go")
    vim.wait(100)
    assert.are.equal(dir .. "/server_test.go", vim.api.nvim_buf_get_name(0))
  end)
end)
