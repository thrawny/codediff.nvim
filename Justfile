# codediff.nvim task runner
# Run `just` to see all available recipes

# Default recipe - list all recipes
default:
    @just --list

# Install development dependencies and bundle the engine
build:
    cd engine && bun install --frozen-lockfile && bun run bundle

# === Tests ===

# Run all tests
test: test-engine test-lua

# Run engine (bun) unit tests
test-engine: build
    cd engine && bun test

# Run Lua integration tests
test-lua: build
    ./tests/run_plenary_tests.sh

# === Formatters / Linters ===

# Format Lua and engine
fmt:
    stylua lua
    cd engine && bun run format

alias format := fmt

# Lint Lua and engine
lint:
    stylua --check lua
    cd engine && bun run lint && bun run format:check

# Typecheck the engine
typecheck:
    cd engine && bun run typecheck

# Format, lint, typecheck, and test
check: fmt lint typecheck test

# Remove development dependencies
clean:
    rm -rf engine/node_modules
