# Test Suite

Integration tests for codediff.nvim using [plenary.nvim](https://github.com/nvim-lua/plenary.nvim).

## Test Coverage

### ✅ Engine Integration (core/engine_integration_spec.lua)
Bun engine ↔ Lua boundary validation:
- Data structure conversion
- Repeated calls through the long-lived sidecar
- Edge cases (empty diffs, large files)

### ✅ Git Integration (core/git_integration_spec.lua)
Git operations and async handling:
- Repository detection
- Async callbacks
- Error handling for invalid revisions
- Path calculation
- LRU cache validation

### ✅ Installer (core/installer_spec.lua)
Bun engine bootstrap and dependency management:
- Module API validation
- VERSION loading from version.lua
- Engine path construction
- Update necessity logic

### ✅ Semantic Tokens (ui/semantic_tokens_spec.lua)
LSP integration and rendering:
- Module compatibility checks
- Virtual file URL handling
- Namespace management

Plus diff behavior specs (moves, whitespace, timeout) in `core/` and UI specs in `ui/`.

## Running Tests

### All tests:
```bash
./tests/run_plenary_tests.sh
```

### Individual spec:
```bash
nvim --headless --noplugin -u tests/init.lua \
  -c "lua require('plenary.test_harness').test_file('tests/core/engine_integration_spec.lua', { minimal_init = 'tests/init.lua' })"
```

### Engine unit tests:
```bash
cd engine && bun test
```

## Test Philosophy

Focus on **integration points**:
- Engine sidecar boundary integrity
- Lua async operations
- System integration (git)
- UI behavior (scrolling, rendering)

Diff algorithm internals are validated by the engine's own bun tests in
`engine/src/*.test.ts`.
