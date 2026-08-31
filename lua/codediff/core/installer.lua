-- Compatibility helpers for the bundled Bun diff engine.
--
-- The engine and its runtime dependencies are bundled into engine/dist/main.js
-- before release. Users only need the Bun runtime; no installation writes into
-- the plugin directory.

local M = {}

local path_util = require("codediff.core.path")
local version = require("codediff.version")

local function get_engine_dir()
  return path_util.get_plugin_root() .. "/engine"
end

function M.has_bun()
  return vim.fn.executable("bun") == 1
end

function M.get_engine_path()
  return vim.fn.fnamemodify(get_engine_dir() .. "/dist/main.js", ":p")
end

function M.get_installed_version()
  if vim.fn.filereadable(M.get_engine_path()) ~= 1 then
    return nil
  end
  return version.VERSION
end

function M.is_installed()
  return M.has_bun() and vim.fn.filereadable(M.get_engine_path()) == 1
end

function M.needs_update()
  return not M.is_installed()
end

-- Kept for compatibility with :CodeDiff install and callers of the old API.
function M.install(opts)
  opts = opts or {}

  if not M.has_bun() then
    local msg = "codediff.nvim requires the Bun runtime (https://bun.sh). Install Bun and make sure it is on your PATH."
    vim.notify(msg, vim.log.levels.ERROR)
    return false, msg
  end

  if vim.fn.filereadable(M.get_engine_path()) ~= 1 then
    local msg = "codediff bundled engine not found at: " .. M.get_engine_path() .. ". Reinstall or update the plugin."
    vim.notify(msg, vim.log.levels.ERROR)
    return false, msg
  end

  if not opts.silent then
    vim.notify("codediff engine is bundled with the plugin; no installation is needed", vim.log.levels.INFO)
  end
  return true
end

return M
