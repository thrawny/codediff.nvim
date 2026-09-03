-- Test init file for plenary tests
-- This loads the plugin and plenary.nvim

-- Disable auto-installation in tests (engine deps are installed by CI/make)
vim.env.VSCODE_DIFF_NO_AUTO_INSTALL = "1"

-- Disable ShaDa (fixes Windows permission issues in CI)
vim.opt.shadafile = "NONE"

-- Add current directory to runtimepath
local cwd = vim.fn.getcwd()
vim.opt.rtp:prepend(cwd)

-- Ensure lua/ directory is in package.path for direct requires
package.path = package.path .. ";" .. cwd .. "/lua/?.lua;" .. cwd .. "/lua/?/init.lua"

vim.opt.swapfile = false

-- Setup plenary.nvim in Neovim's data directory (proper location)
local plenary_dir = vim.fn.stdpath("data") .. "/plenary.nvim"
if vim.fn.isdirectory(plenary_dir) == 0 then
  -- Clone plenary if not found
  print("Installing plenary.nvim for tests...")
  vim.fn.system({
    "git",
    "clone",
    "--depth=1",
    "https://github.com/nvim-lua/plenary.nvim",
    plenary_dir,
  })
end
vim.opt.rtp:prepend(plenary_dir)

-- Install the optional parsers exercised by the symbol tests. Neovim only
-- bundles a small parser set, so clean machines and CI do not have these.
local function has_parser(lang)
  local ok, parser = pcall(vim.treesitter.get_string_parser, "", lang)
  return ok and parser ~= nil
end

local missing_parsers = {}
for _, lang in ipairs({ "javascript", "typescript", "tsx" }) do
  if not has_parser(lang) then
    table.insert(missing_parsers, lang)
  end
end

if #missing_parsers > 0 then
  local treesitter_dir = vim.fn.stdpath("data") .. "/codediff-test-nvim-treesitter"
  if vim.fn.isdirectory(treesitter_dir) == 0 then
    print("Installing nvim-treesitter for tests...")
    local clone_output = vim.fn.system({
      "git",
      "clone",
      "--depth=1",
      "--branch=master",
      "https://github.com/nvim-treesitter/nvim-treesitter.git",
      treesitter_dir,
    })
    if vim.v.shell_error ~= 0 then
      error("Failed to install nvim-treesitter for tests:\n" .. clone_output)
    end
  end
  vim.opt.rtp:prepend(treesitter_dir)

  require("nvim-treesitter.install").ensure_installed_sync(missing_parsers)
  for _, lang in ipairs(missing_parsers) do
    if not has_parser(lang) then
      error("Failed to install Tree-sitter parser for tests: " .. lang)
    end
  end
end

-- Load plugin files (for integration tests that need commands)
vim.cmd("runtime! plugin/*.lua plugin/*.vim")

-- Setup plugin
require("codediff").setup()
