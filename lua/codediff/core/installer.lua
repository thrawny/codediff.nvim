-- Bootstrap for the Bun diff engine
-- Verifies the Bun runtime is available and installs the engine's
-- JavaScript dependencies (@pierre/diffs) with `bun install`.

local M = {}

local path_util = require("codediff.core.path")

local function get_engine_dir()
  return path_util.get_plugin_root() .. "/engine"
end

-- Check if the Bun runtime is available
function M.has_bun()
  return vim.fn.executable("bun") == 1
end

-- Path to the engine entry point (used for diagnostics)
function M.get_engine_path()
  return get_engine_dir() .. "/src/main.ts"
end

-- Get the installed @pierre/diffs version, or nil when not installed
function M.get_installed_version()
  local package_json = get_engine_dir() .. "/node_modules/@pierre/diffs/package.json"
  local f = io.open(package_json, "r")
  if not f then
    return nil
  end
  local content = f:read("*a")
  f:close()

  local ok, decoded = pcall(vim.json.decode, content)
  if ok and type(decoded) == "table" then
    return decoded.version
  end
  return nil
end

-- Check if the engine is ready to run
function M.is_installed()
  if not M.has_bun() then
    return false
  end
  return vim.fn.isdirectory(get_engine_dir() .. "/node_modules/@pierre/diffs") == 1
end

-- Check if engine dependencies need to be (re)installed
function M.needs_update()
  return not M.is_installed()
end

-- Install engine dependencies via `bun install`
function M.install(opts)
  opts = opts or {}

  if not M.has_bun() then
    local msg = "codediff.nvim requires the Bun runtime (https://bun.sh). " .. "Install it with `curl -fsSL https://bun.sh/install | bash` and make sure `bun` is on your PATH."
    vim.notify(msg, vim.log.levels.ERROR)
    return false, msg
  end

  local engine_dir = get_engine_dir()
  if vim.fn.isdirectory(engine_dir) == 0 then
    local msg = "codediff engine directory not found at: " .. engine_dir
    vim.notify(msg, vim.log.levels.ERROR)
    return false, msg
  end

  if not opts.force and M.is_installed() then
    if not opts.silent then
      vim.notify("codediff engine already installed (" .. (M.get_installed_version() or "unknown") .. ")", vim.log.levels.INFO)
    end
    return true
  end

  if not opts.silent then
    vim.notify("Installing codediff engine dependencies (bun install)...", vim.log.levels.INFO)
  end

  local result = vim.system({ "bun", "install" }, { cwd = engine_dir, text = true }):wait()
  if result.code ~= 0 then
    local msg = "bun install failed: " .. (result.stderr or result.stdout or "unknown error")
    vim.notify(msg, vim.log.levels.ERROR)
    return false, msg
  end

  if not opts.silent then
    vim.notify("Successfully installed codediff engine!", vim.log.levels.INFO)
  end

  return true
end

return M
