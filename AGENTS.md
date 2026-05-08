# Agent Instructions

## General CLI Agent Behavior Instructions

> ⚠️ **CRITICAL: NEVER commit code unless the user explicitly requests it.** After completing changes, STOP and wait for user to say "commit". Each commit request authorizes only ONE commit operation.

### Communication and File Operation Guidelines

1. **Output Messages**: When responding to users, utilize the native chat output interface. Do not use command-line utilities such as `cat`, `echo`, or `write-host` to display messages in the console.

2. **File Creation and Editing**: Always use native file operation tools (create, edit, patch/diff APIs) for all file operations. Do not use shell redirection operators (`>`, `>>`, `<<`) or command-line utilities (`cat`, `sed`, `awk`, `grep`) to create or modify files. This applies to ALL files, regardless of location (project files, `/tmp`, `%TEMP%`, etc.).

   **Prohibited patterns**:
   - `cat > /tmp/file.md << 'EOF'`
   - `echo "content" > file.txt`
   - `sed -i 's/pattern/replacement/' file.js`
   
   **Required approach**: Use native `create` or `str_replace` tools instead.

3. **Experimental and Demonstration Scripts**: When running experiments, demonstrations, or temporary operations that require script files, create the script files explicitly in temporary directories (`/tmp` on Linux/macOS, `%TEMP%` on Windows) using native file creation tools first, then execute them. Do not use inline heredocs or shell redirection. Do not place code that should have commited and checked-in in `/tmp` folder

   **Example workflow**:
   - Step 1: Use `create` tool to make `/tmp/experiment.sh`
   - Step 2: Execute `bash /tmp/experiment.sh`
   - Step 3: Clean up the file after use

4. **Trailing Spaces**: NEVER add trailing spaces to any line in any file. Always ensure lines end cleanly without whitespace.

5. **Pull Requests**: When asked to create a PR, push the branch as is (do not create a new branch), create PR with comprehensive description (summary, changes, benefits, testing), and enable auto-merge.

## Path-Specific Instructions

Path-specific instructions are defined in `.github/copilot-instructions.md` files within respective directories.

## Debugging Neovim Review/LSP Issues

When investigating codediff/review behavior inside Neovim, reproduce issues in a real Neovim session instead of relying only on static inspection.

### Test Harness Pattern

1. Create temporary Lua harnesses with the file-write tool (not shell heredocs), for example under `/tmp/*.lua`.
2. If Pi's `interactive_shell` extension is enabled, run Neovim through it (not `bash`) when the run is interactive or TUI-like:
   - Headless assertion: `nvim --headless -S /tmp/harness.lua`
   - Visible/manual observation: `nvim -S /tmp/harness.lua`
3. With `interactive_shell`, use `mode = "hands-free"` so the user can see the overlay and the agent can query/send keys.
4. If `interactive_shell` is not available, use normal shell commands only for finite headless checks (`nvim --headless -S /tmp/harness.lua`) and ask the user to perform/observe interactive TUI steps manually.
5. Clean up or let finite sessions exit; do not leave test Neovim sessions running.

### Useful Repro Case

For large Go review/LSP regressions, `~/work/kanel/code/kanel-backend` has a representative last-commit diff:

```vim
:Review commits HEAD
```

This opens commit snapshots where both review buffers can be synthetic `nofile` buffers. That differs from `:Review` on uncommitted changes, where the modified side may be a real working-tree file with `gopls` attached.

### What to Inspect

Inside the harness, inspect the codediff session and buffers:

```lua
local lifecycle = require("codediff.ui.lifecycle")
local sess = lifecycle.get_session(vim.api.nvim_get_current_tabpage())
print(vim.inspect({
  original_path = sess.original_path,
  modified_path = sess.modified_path,
  original_revision = sess.original_revision,
  modified_revision = sess.modified_revision,
  original_bufnr = sess.original_bufnr,
  modified_bufnr = sess.modified_bufnr,
}))
```

For each relevant buffer, log:

- `vim.bo[buf].buftype`
- `vim.bo[buf].filetype`
- `vim.b[buf].codediff_filetype`
- `vim.api.nvim_buf_get_name(buf)`
- `vim.lsp.get_clients({ bufnr = buf })`
- buffer-local mappings from `vim.api.nvim_buf_get_keymap(buf, "n")`

### Validating `gr` / References

Do not only verify that `gr` is mapped. Demonstrate that it works:

1. Position the cursor on a symbol with known references, e.g. `initDatabase` in `cmd/api-v2/main.go` for `kanel-backend`'s last commit.
2. Feed the actual mapping with `vim.api.nvim_feedkeys("gr", "mx", false)` or send `gr` via `interactive_shell`.
3. Observe the result, e.g. quickfix/FzfLua entries. A successful run in the kanel repro produced two references for `initDatabase`:
   - the function declaration
   - the call `kanelDB := initDatabase(kanelDBConf)`

For synthetic commit-review buffers, `gopls` should not attach directly. Reference lookup may need to proxy through the real working-tree file and then display results via quickfix/FzfLua quickfix.
