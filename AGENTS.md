# codediff.nvim

Jonas's fork of [esmuellert/codediff.nvim](https://github.com/esmuellert/codediff.nvim). The fork has diverged from `upstream` and is developed on its own `main`, pushed to `origin`. The Lua plugin lives in `lua/codediff/`. The diff engine is a Bun sidecar in `engine/`.

Jonas's Neovim loads this checkout directly, so a change reaches his editor when he restarts Neovim.

## Workflow

Commit and push to `origin` after every change, once its checks pass.

## Checks

- `just test-lua` runs every `tests/**/*_spec.lua` file. The runner finds new spec files by itself.
- `stylua --check lua` checks Lua formatting. `just fmt` fixes it.
- `just test` also runs the engine tests. Run it when you touch `engine/`.

Run one spec file:

```bash
nvim --headless --noplugin -u tests/init.lua -c "lua require('plenary.busted').run('tests/ui/inline_spec.lua')"
```

The first test run clones plenary.nvim and installs Tree-sitter parsers, so it needs network access.

## Tests

Add a test case to the existing spec that covers the area. Write tests against the current API, and update an old test rather than keeping a removed API alive for it.

## Reproducing bugs

Reproduce a bug in a real headless Neovim before you fix it, and run the same reproduction again after the fix. Keep scratch scripts outside the repo.

For a scripted user flow, write a scenario and run it with the end-to-end runner:

```bash
SCENARIO_FILE=/path/to/scenario.lua nvim --headless -u tests/init.lua -c "luafile scripts/nvim-e2e.lua" -c "qa!"
```

A scenario returns a table with `setup`, `run`, `validate` and `cleanup` functions. `validate` returns `true` when the behaviour is correct. `tests/e2e/` has working scenarios to copy, and `scripts/nvim-e2e.lua` defines the helpers they call, such as temporary git repos, waits and key presses.

## Review mode and LSP

`:Review` on uncommitted changes shows the real working-tree file on the modified side, so language servers attach to it. `:Review commits <rev>` shows commit snapshots, where both sides can be `nofile` buffers with no language server. LSP requests from those buffers go through the real working-tree file, in `lua/codediff/review/lsp_proxy.lua`.

When you debug this, log the session and each buffer:

```lua
local sess = require("codediff.ui.lifecycle").get_session(vim.api.nvim_get_current_tabpage())
print(vim.inspect({
  original_path = sess.original_path,
  modified_path = sess.modified_path,
  original_revision = sess.original_revision,
  modified_revision = sess.modified_revision,
  original_bufnr = sess.original_bufnr,
  modified_bufnr = sess.modified_bufnr,
}))
```

For each buffer, log `buftype`, `filetype`, `vim.b[buf].codediff_filetype`, the buffer name, `vim.lsp.get_clients({ bufnr = buf })` and the normal-mode buffer keymaps.

To verify a proxied mapping such as `gr`, put the cursor on a symbol with known references, feed the keys with `vim.api.nvim_feedkeys("gr", "mx", false)`, and check the quickfix entries it produces.

## Docs

`README.md` and `doc/codediff.txt` are the user docs. Update both when you add or change a command, keymap or option. `docs/review-sidecar-architecture.md` is the design of review mode's LSP sidecar.
