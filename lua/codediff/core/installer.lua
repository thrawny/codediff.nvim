-- Locates the bundled Bun diff engine.
--
-- The engine and its runtime dependencies are bundled into engine/dist/main.js.
-- Users only need the Bun runtime on PATH.

local M = {}

local path_util = require("codediff.core.path")

function M.has_bun()
  return vim.fn.executable("bun") == 1
end

function M.get_engine_path()
  return vim.fn.fnamemodify(path_util.get_plugin_root() .. "/engine/dist/main.js", ":p")
end

return M
