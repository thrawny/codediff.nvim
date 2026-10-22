# codediff.nvim

VSCode-style diffs in Neovim, side by side or inline, with a review mode for branches and GitHub PRs.

This is a fork of [esmuellert/codediff.nvim](https://github.com/esmuellert/codediff.nvim). It adds review sessions and the skeleton view, and it has diverged from upstream.

![Side-by-side diff with line and character highlights](https://github.com/user-attachments/assets/473ae319-40ac-40e4-958b-a0f2525d1f94)

## Requirements

- Neovim 0.10 or later
- [Bun](https://bun.sh), which runs the diff engine. The engine ships prebuilt in `engine/dist`, so there is no build step.
- Git
- [nui.nvim](https://github.com/MunifTanjim/nui.nvim), for review sessions
- The [GitHub CLI](https://cli.github.com) (`gh`), for `:CodeReview pr` and `:CodeReview branch`

## Install

With lazy.nvim:

```lua
{
  "thrawny/codediff.nvim",
  dependencies = { "MunifTanjim/nui.nvim" },
  cmd = { "CodeDiff", "CodeReview", "Review" },
  opts = {
    diff = { layout = "inline" },
  },
}
```

`lua/codediff/config.lua` lists every option with its default. Highlights follow your colorscheme's `DiffAdd` and `DiffDelete`.

## Use

```vim
:CodeDiff                   " changed files in the working tree
:CodeDiff main...           " what a PR from this branch would show
:CodeDiff file HEAD~1       " the current file against a revision
:CodeDiff history %         " commits that touched the current file
:Review branch              " review this branch against its PR base
:Review pr 123              " review a GitHub PR
```

In a diff, `]c`/`[c` move between changes, `t` switches layout, `s` cycles the skeleton view and `g?` lists every keymap.

`:help codediff` documents every command, option, highlight group and event.

To work on the plugin, see `AGENTS.md` for the checks and tests.
