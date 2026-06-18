# Neovim review sidecar architecture handoff

Written 2026-06-10.

## Context

The current Neovim review workflow is implemented mostly inside Lua around
`codediff.nvim`. It works, but the architecture is getting strained:

- diff parsing / row planning / navigation state is complex for Lua-only plugin
  code;
- GitHub PR/session loading wants richer async IO and caching;
- terminal review tools such as Hunk already have a better diff core;
- Hunk uses Pierre-style diff planning, which produces review-friendly rows and
  layouts;
- keeping the Neovim side responsible for everything makes keymap bugs and UI
  state bugs harder to isolate.

The preferred direction is not to embed Hunk's terminal UI in Neovim. The useful
part is the review/diff engine model behind it.

## Decision direction

Build a **Bun/TypeScript review sidecar** and keep the Neovim Lua plugin thin.

High-level shape:

```text
Neovim plugin UI
  <-> Lua adapter
  <-> Bun JSON-RPC review engine
  <-> Hunk/Pierre-style diff core
  <-> git / GitHub
```

Neovim should own editor-native concerns:

- buffers, windows, tabs;
- keymaps;
- extmarks, signs, highlights, folds;
- cursor position and jump/navigation UX;
- applying edits/hunks to files;
- showing comments inline in editor buffers.

The Bun sidecar should own review-engine concerns:

- git working-tree / branch / PR loading;
- GitHub API calls;
- diff parsing;
- Pierre-style row planning;
- file/hunk metadata;
- comment/thread/session domain model;
- caching and watch mode;
- machine-readable review state.

## Reuse strategy

Prefer this order:

1. **Extract or reuse Pierre-like pieces from Hunk**
   - Reuse the diff model and row planner.
   - Do not reuse OpenTUI rendering directly.
   - Ideal end state: shared TS module/package that both Hunk and the Neovim
     sidecar can import.

2. **Add machine-readable Hunk output if extraction is not practical yet**
   - Example: `hunk diff --json-plan` or similar.
   - Neovim consumes the plan and renders editor buffers itself.
   - This can validate the boundary before deeper extraction.

3. **Fork Hunk only as a short-term accelerator**
   - Forking may be useful to prototype quickly.
   - Avoid long-term fork drift if possible.

## IPC boundary

Use JSON-RPC over stdio or a local socket.

Initial preference: stdio JSON-RPC for a single per-Neovim sidecar process.

Example request/response classes:

- `initialize`
- `loadWorkingTree`
- `loadPullRequest`
- `listFiles`
- `getFilePlan`
- `getHunkAtCursor`
- `nextHunk` / `previousHunk`
- `createComment`
- `updateComment`
- `submitReview`
- `applyHunk`
- `refresh`

The sidecar should return stable IDs for files, hunks, rows, and comments so Lua
can keep UI state without owning the entire domain model.

## Data model sketch

The sidecar should expose a review snapshot shaped roughly like:

```ts
type ReviewSnapshot = {
  sessionId: string;
  repoRoot: string;
  baseRef: string;
  headRef: string;
  files: ReviewFile[];
};

type ReviewFile = {
  id: string;
  path: string;
  oldPath?: string;
  status: "added" | "modified" | "deleted" | "renamed" | "untracked";
  stats: { added: number; removed: number };
  hunks: ReviewHunk[];
};

type ReviewHunk = {
  id: string;
  fileId: string;
  oldStart: number;
  oldLines: number;
  newStart: number;
  newLines: number;
  rows: PierreRow[];
  comments: ReviewCommentThread[];
};
```

Lua should not need to parse unified diffs once this boundary exists.

## Neovim rendering approach

Do not try to render Hunk's terminal UI in Neovim.

Instead, Lua renders normal buffers from the sidecar's row plan:

- original/modified buffers or synthetic review buffers;
- extmarks for line signs, virtual text, and comment anchors;
- Neovim highlight groups mapped to the user's colorscheme;
- editor-native navigation over sidecar-provided stable hunk/file IDs.

This keeps the editor interaction reliable and avoids fighting terminal layout
inside a buffer.

## Why Bun/TypeScript

Pros:

- matches Hunk's implementation stack;
- easier to reuse Hunk/Pierre code;
- good async IO story for git and GitHub;
- easier testing of the review engine outside Neovim;
- fewer native plugin/build issues than C;
- a long-lived sidecar can avoid repeated startup cost.

Cons / risks:

- introduces a runtime/process dependency;
- IPC failures need clean user-facing recovery;
- startup latency if the sidecar is spawned too often;
- Nix packaging must include Bun/runtime cleanly;
- editor and sidecar state can drift unless snapshots/events are disciplined.

Mitigations:

- one long-lived sidecar per Neovim instance;
- explicit `refresh` and generation/version numbers on snapshots;
- clear error channel in JSON-RPC;
- integration tests for sidecar protocol;
- Lua fallback/error UI when the sidecar dies.

## Prototype plan

### Phase 1: read-only working-tree review

Goal: prove the split without GitHub or mutation.

- Build a Bun command that emits a JSON row plan for `git diff`.
- Use Hunk/Pierre code directly if possible; otherwise mimic the minimum row
  model needed for rendering.
- Lua command opens a review tab/buffer from that JSON.
- Implement file list, next/previous hunk, and close/refresh.

Success criteria:

- no Lua unified-diff parsing;
- navigation is stable when switching files/tabs;
- visual output is close to current Neovim diff highlighting;
- sidecar errors are visible rather than silently corrupting state.

### Phase 2: comments and session model

- Add comment/thread objects to the sidecar model.
- Persist draft review state locally.
- Render comment anchors in Neovim via extmarks.
- Add create/edit/delete draft comment operations through JSON-RPC.

### Phase 3: PR/GitHub integration

- Load PR metadata, file list, and existing comments.
- Support submit review / export review.
- Cache API responses and expose explicit refresh.

### Phase 4: extraction/upstreaming

- If Hunk internals were copied/forked, extract the shared engine cleanly.
- Prefer an upstreamable Hunk package or machine-readable output mode.

## Open questions

- Can Hunk's Pierre code be imported as a stable internal package, or does it
  need extraction first?
- Should the sidecar be part of `codediff.nvim`, a separate repo, or a local
  package in dotfiles while prototyping?
- Is stdio enough, or do we want a socket so multiple Neovim instances can share
  one daemon?
- Should applying hunks be done by Neovim buffer edits or by the sidecar invoking
  git/apply logic?
- How much of the current `codediff.nvim` Lua API should be preserved for keymaps
  and muscle memory?

## Suggested next concrete step

Create a tiny proof of concept:

```bash
bun run review-sidecar diff --repo . --format json
```

Then a Neovim command:

```vim
:ReviewSidecar
```

that spawns the command, decodes JSON, and renders one file's planned rows in a
scratch buffer with existing Monokai diff highlights.

Keep the first prototype read-only. The goal is to validate the boundary before
moving comments, GitHub, or hunk application into it.
