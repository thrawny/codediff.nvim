-- Diff engine client for codediff.nvim
-- Talks to a long-lived Bun sidecar (engine/) that computes diffs with
-- @pierre/diffs, replacing the old libvscode-diff C library. The protocol is
-- newline-delimited JSON over stdio; results keep the LinesDiff shape the
-- rest of the plugin has always consumed.
--
-- IPC uses vim.uv directly (not jobstart) so responses arrive as fast events
-- and requests can block with vim.wait(..., fast_only). This keeps
-- compute_diff synchronous from the caller's point of view, like the old C
-- FFI call: no scheduled UI callbacks run while a diff is in flight.

local M = {}

local uv = vim.uv or vim.loop
local path_util = require("codediff.core.path")
local installer = require("codediff.core.installer")

local DEFAULT_TIMEOUT_MS = 5000
-- Extra slack on top of the diff computation budget for process scheduling
-- and JSON round-tripping of large files.
local REQUEST_GRACE_MS = 10000

-- Resolve the engine path once at module load, while cwd-relative paths are
-- still valid (callers may chdir later, e.g. tests in temp git repos).
local engine_dir = (vim.fn.fnamemodify(path_util.get_plugin_root() .. "/engine", ":p"):gsub("/$", ""))

local state = {
  handle = nil,
  stdin = nil,
  stdout_buffer = "",
  responses = {},
  stderr_lines = {},
  next_id = 0,
}

local function is_running()
  return state.handle ~= nil and not state.handle:is_closing()
end

local function stop_engine()
  if state.stdin and not state.stdin:is_closing() then
    state.stdin:close()
  end
  if state.handle and not state.handle:is_closing() then
    state.handle:kill("sigterm")
    state.handle:close()
  end
  state.handle = nil
  state.stdin = nil
end

local function on_stdout_chunk(chunk)
  state.stdout_buffer = state.stdout_buffer .. chunk
  while true do
    local newline = state.stdout_buffer:find("\n", 1, true)
    if not newline then
      break
    end
    local line = state.stdout_buffer:sub(1, newline - 1)
    state.stdout_buffer = state.stdout_buffer:sub(newline + 1)
    if line ~= "" then
      local ok, decoded = pcall(vim.json.decode, line)
      if ok and type(decoded) == "table" and decoded.id ~= nil then
        state.responses[decoded.id] = decoded
      end
    end
  end
end

local function ensure_engine()
  if is_running() then
    return
  end

  if not installer.has_bun() then
    error("codediff.nvim requires the Bun runtime for its diff engine.\n" .. "Install it from https://bun.sh and make sure `bun` is on your PATH.")
  end

  local engine_path = installer.get_engine_path()
  if vim.fn.filereadable(engine_path) ~= 1 then
    error("codediff.nvim bundled engine not found at: " .. engine_path .. ". Reinstall or update the plugin.")
  end

  state.stdout_buffer = ""
  state.responses = {}
  state.stderr_lines = {}

  local stdin = uv.new_pipe(false)
  local stdout = uv.new_pipe(false)
  local stderr = uv.new_pipe(false)

  local handle, spawn_err = uv.spawn("bun", {
    args = { installer.get_engine_path() },
    cwd = engine_dir,
    stdio = { stdin, stdout, stderr },
  }, function()
    -- on exit: mark engine dead so callers can error/restart
    if state.handle then
      state.handle:close()
    end
    state.handle = nil
    state.stdin = nil
  end)

  if not handle then
    stdin:close()
    stdout:close()
    stderr:close()
    error("codediff.nvim: failed to start the Bun diff engine: " .. tostring(spawn_err))
  end

  stdout:read_start(function(err, chunk)
    if err or not chunk then
      stdout:close()
      return
    end
    on_stdout_chunk(chunk)
  end)

  stderr:read_start(function(err, chunk)
    if err or not chunk then
      stderr:close()
      return
    end
    for line in chunk:gmatch("[^\n]+") do
      table.insert(state.stderr_lines, line)
      if #state.stderr_lines > 50 then
        table.remove(state.stderr_lines, 1)
      end
    end
  end)

  state.handle = handle
  state.stdin = stdin
end

local function request(method, params, timeout_ms)
  ensure_engine()

  state.next_id = state.next_id + 1
  local id = state.next_id

  local ok_encode, payload = pcall(vim.json.encode, { id = id, method = method, params = params })
  if not ok_encode then
    error("codediff.nvim: failed to encode diff request (non-UTF-8 buffer content?): " .. tostring(payload))
  end

  state.stdin:write(payload .. "\n")

  -- fast_only: uv pipe callbacks still fire, but scheduled UI callbacks do
  -- not. This keeps the call synchronous without re-entrancy into plugin
  -- state (layout toggles, refreshes) while a diff is computing.
  vim.wait(timeout_ms, function()
    return state.responses[id] ~= nil or state.handle == nil
  end, 3, true)

  local response = state.responses[id]
  state.responses[id] = nil

  if not response then
    local stderr = table.concat(state.stderr_lines, "\n")
    if state.handle == nil then
      error("codediff.nvim: diff engine exited unexpectedly." .. (stderr ~= "" and ("\n" .. stderr) or ""))
    end
    error("codediff.nvim: diff engine did not respond within " .. timeout_ms .. "ms")
  end

  if response.error ~= nil and response.error ~= vim.NIL then
    error("codediff.nvim: diff engine error: " .. tostring(response.error))
  end

  return response.result
end

---@class DiffOptions
---@field ignore_trim_whitespace boolean
---@field max_computation_time_ms integer
---@field compute_moves boolean
---@field extend_to_subwords boolean

-- Main API: Compute diff between two sets of lines
-- Returns Lua table representation of LinesDiff:
-- { changes = { { original = LineRange, modified = LineRange, inner_changes = {...} } },
--   moves = { { original = LineRange, modified = LineRange } },
--   hit_timeout = boolean }
function M.compute_diff(original_lines, modified_lines, options)
  options = options or {}
  local engine_options = {
    ignore_trim_whitespace = options.ignore_trim_whitespace or false,
    max_computation_time_ms = options.max_computation_time_ms or DEFAULT_TIMEOUT_MS,
    compute_moves = options.compute_moves or false,
    extend_to_subwords = options.extend_to_subwords or false,
  }

  local result = request("computeDiff", {
    original = original_lines,
    modified = modified_lines,
    options = engine_options,
  }, engine_options.max_computation_time_ms + REQUEST_GRACE_MS)

  -- Normalize for consumers that index these unconditionally.
  result.changes = result.changes or {}
  result.moves = result.moves or {}
  for _, change in ipairs(result.changes) do
    change.inner_changes = change.inner_changes or {}
  end
  if type(result.hit_timeout) ~= "boolean" then
    result.hit_timeout = false
  end

  return result
end

-- Get engine version
function M.get_version()
  local result = request("version", nil, DEFAULT_TIMEOUT_MS)
  return result.version
end

-- Stop the engine process (mainly for tests)
function M.shutdown()
  stop_engine()
end

return M
