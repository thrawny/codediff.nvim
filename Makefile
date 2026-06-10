# Makefile for codediff.nvim
# The diff engine is a Bun/TypeScript sidecar in engine/

.PHONY: all build test test-engine test-lua lint format typecheck clean help bump-patch bump-minor bump-major bump-prerelease

all: build

build:
	@cd engine && bun install
	@echo "✓ Engine dependencies installed"

test: test-engine test-lua

test-engine: build
	@cd engine && bun test

test-lua: build
	@./tests/run_plenary_tests.sh

typecheck:
	@cd engine && bun run typecheck

lint:
	@stylua --check lua
	@cd engine && bun run lint && bun run format:check

format:
	@stylua lua
	@cd engine && bun run format
	@echo "✓ Formatted lua/ and engine/"

clean:
	@rm -rf engine/node_modules

bump-patch:
	@node scripts/bump_version.mjs patch

bump-minor:
	@node scripts/bump_version.mjs minor

bump-major:
	@node scripts/bump_version.mjs major

bump-prerelease:
	@node scripts/bump_version.mjs prerelease

help:
	@echo "Targets: build, test, test-engine, test-lua, typecheck, lint, format, clean, help"
	@echo "Version: bump-patch, bump-minor, bump-major, bump-prerelease"
