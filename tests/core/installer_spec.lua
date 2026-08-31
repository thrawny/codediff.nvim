-- Test: Installer Module
-- Validates the bundled Bun engine

local installer = require('codediff.core.installer')
local version = require("codediff.version")

describe("Installer Module", function()
  -- Test 1: Module loads correctly
  it("Loads installer module", function()
    assert.is_not_nil(installer, "Installer module should load")
    assert.equal("table", type(installer), "Installer should be a table")
  end)

  -- Test 2: Public API functions exist
  it("Exposes correct public API", function()
    assert.equal("function", type(installer.install), "Should have install function")
    assert.equal("function", type(installer.is_installed), "Should have is_installed function")
    assert.equal("function", type(installer.has_bun), "Should have has_bun function")
    assert.equal("function", type(installer.get_engine_path), "Should have get_engine_path function")
    assert.equal("function", type(installer.get_installed_version), "Should have get_installed_version function")
    assert.equal("function", type(installer.needs_update), "Should have needs_update function")
  end)

  -- Test 3: VERSION is loaded from version.lua
  it("VERSION is available from version module", function()
    assert.is_not_nil(version.VERSION, "VERSION should be loaded")
    assert.equal("string", type(version.VERSION), "VERSION should be a string")
    assert.is_true(#version.VERSION > 0, "VERSION should not be empty")
    -- Check version format (e.g., "0.8.0" or "2.0.0-next.0")
    assert.is_true(version.VERSION:match("^%d+%.%d+%.%d+") ~= nil, "VERSION should match semantic version format")
  end)

  -- Test 4: get_engine_path points at the engine entry point
  it("get_engine_path returns valid engine entry path", function()
    local engine_path = installer.get_engine_path()
    assert.is_not_nil(engine_path, "Engine path should not be nil")
    assert.equal("string", type(engine_path), "Engine path should be a string")
    assert.is_true(engine_path:match("engine/dist/main%.js$") ~= nil,
      "Engine path should point at engine/dist/main.js")
  end)

  -- Test 5: is_installed checks Bun and the bundled engine
  it("is_installed returns boolean", function()
    local installed = installer.is_installed()
    assert.equal("boolean", type(installed), "is_installed should return boolean")

    -- If installed, the engine entry point should exist
    if installed then
      assert.equal(1, vim.fn.filereadable(installer.get_engine_path()),
        "Engine entry point should be readable if installed")
    end
  end)

  -- Test 6: get_installed_version returns nil or valid version
  it("get_installed_version returns nil or version string", function()
    local installed_version = installer.get_installed_version()

    if installed_version then
      assert.equal("string", type(installed_version), "Installed version should be string if present")
      assert.is_true(#installed_version > 0, "Installed version should not be empty")
      assert.is_true(installed_version:match("^%d+%.%d+%.%d+") ~= nil,
        "Installed version should match semantic version format")
    end
  end)

  -- Test 7: needs_update is the inverse of is_installed
  it("needs_update correctly determines update necessity", function()
    local needs_update = installer.needs_update()
    assert.equal("boolean", type(needs_update), "needs_update should return boolean")
    assert.equal(not installer.is_installed(), needs_update,
      "needs_update should be the inverse of is_installed")
  end)

  -- Test 8: install remains a compatible no-op
  it("install function accepts options table", function()
    if installer.is_installed() then
      local success = installer.install({ silent = true })
      assert.is_true(success, "install should succeed when already installed")
    end
  end)
end)
