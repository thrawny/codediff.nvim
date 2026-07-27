-- Tests for async seam classification (codediff.ui.explorer.seam)
local spec_path = debug.getinfo(1, "S").source:sub(2)
local plugin_root = vim.fn.fnamemodify(spec_path, ":p:h:h:h:h")
vim.opt.rtp:prepend(plugin_root)
package.path = package.path .. ";" .. plugin_root .. "/lua/?.lua;" .. plugin_root .. "/lua/?/init.lua"

local h = dofile("tests/helpers.lua")
h.ensure_plugin_loaded()

local seam = require("codediff.ui.explorer.seam")

local base_lines = {
  "local M = {}",
  "",
  "function M.alpha(a, b)",
  "  local x = a + b",
  "  return x",
  "end",
  "",
  "return M",
}

local function classify_and_wait(explorer, status_result)
  local changed = nil
  seam.classify(explorer, status_result, function(count)
    changed = count
  end)
  vim.wait(5000, function()
    return changed ~= nil
  end, 10)
  assert.is_not_nil(changed, "classification callback never fired")
  return changed
end

describe("explorer seam classification", function()
  local repo

  before_each(function()
    repo = h.create_temp_git_repo()
    repo.write_file("a.lua", base_lines)
    repo.write_file("b.txt", { "plain", "text" })
    repo.git("add .")
    repo.git('commit -m "initial"')
  end)

  after_each(function()
    if repo then
      repo.cleanup()
      repo = nil
    end
  end)

  it("classifies a body-only edit as impl and converges on re-run", function()
    local edited = vim.deepcopy(base_lines)
    edited[4] = "  local x = a * b"
    repo.write_file("a.lua", edited)

    local explorer = { git_root = repo.dir }
    local status_result = {
      unstaged = { { path = "a.lua", status = "M" } },
      staged = {},
    }

    assert.equals(1, classify_and_wait(explorer, status_result))
    assert.equals("impl", seam.get_result(explorer, "unstaged", "a.lua"))

    -- Second pass: fingerprint cache hit, nothing changed
    assert.equals(0, classify_and_wait(explorer, status_result))
  end)

  it("reclassifies when the file changes on disk", function()
    local edited = vim.deepcopy(base_lines)
    edited[4] = "  local x = a * b"
    repo.write_file("a.lua", edited)

    local explorer = { git_root = repo.dir }
    local status_result = {
      unstaged = { { path = "a.lua", status = "M" } },
      staged = {},
    }
    assert.equals(1, classify_and_wait(explorer, status_result))

    -- Now touch the signature too; the file moves out of impl-only
    edited[3] = "function M.alpha(a, b, c)"
    repo.write_file("a.lua", edited)
    assert.equals(1, classify_and_wait(explorer, status_result))
    assert.equals("seam", seam.get_result(explorer, "unstaged", "a.lua"))
  end)

  it("marks files without a parser as unsupported, not as a change", function()
    repo.write_file("b.txt", { "plain", "text", "edited" })

    local explorer = { git_root = repo.dir }
    local status_result = {
      unstaged = { { path = "b.txt", status = "M" } },
      staged = {},
    }

    -- unsupported never affects group membership, so changed = 0
    assert.equals(0, classify_and_wait(explorer, status_result))
    assert.equals("unsupported", seam.get_result(explorer, "unstaged", "b.txt"))
  end)

  it("skips non-modified files entirely", function()
    local explorer = { git_root = repo.dir }
    local status_result = {
      unstaged = { { path = "new.lua", status = "A" } },
      staged = {},
    }
    assert.equals(0, classify_and_wait(explorer, status_result))
    assert.is_nil(seam.get_result(explorer, "unstaged", "new.lua"))
  end)

  it("classifies staged edits against HEAD", function()
    local edited = vim.deepcopy(base_lines)
    edited[4] = "  local x = a * b"
    repo.write_file("a.lua", edited)
    repo.git("add a.lua")

    local explorer = { git_root = repo.dir }
    local status_result = {
      unstaged = {},
      staged = { { path = "a.lua", status = "M" } },
    }

    assert.equals(1, classify_and_wait(explorer, status_result))
    assert.equals("impl", seam.get_result(explorer, "staged", "a.lua"))
  end)
end)
