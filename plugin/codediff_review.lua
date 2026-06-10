if vim.g.loaded_codediff_review then
  return
end
vim.g.loaded_codediff_review = true

require("codediff.review").setup()

local subcommands = {
  open = { fn = function() require("codediff.review").open() end, desc = "Open codediff review" },
  commits = {
    fn = function(args)
      require("codediff.review").open_commits(args[1], args[2])
    end,
    desc = "Open review for a revision or revision range",
  },
  pr = {
    fn = function(args)
      require("codediff.review").open_pr(args[1])
    end,
    desc = "Open review for a GitHub pull request",
  },
  close = { fn = function() require("codediff.review").close() end, desc = "Close review and export comments" },
  export = { fn = function() require("codediff.review").export() end, desc = "Export comments to clipboard" },
  preview = { fn = function() require("codediff.review").preview() end, desc = "Preview exported markdown" },
  clear = { fn = function() require("codediff.review").clear() end, desc = "Clear all comments" },
  list = { fn = function() require("codediff.review").list() end, desc = "List all comments" },
  sidekick = { fn = function() require("codediff.review.export").to_sidekick() end, desc = "Send comments to sidekick.nvim" },
  toggle = { fn = function() require("codediff.review").toggle_readonly() end, desc = "Toggle readonly/edit mode" },
}

local subcommand_names = vim.tbl_keys(subcommands)

local function create_review_command(name)
  vim.api.nvim_create_user_command(name, function(opts)
    local args = opts.fargs
    local cmd = args[1]
    if not cmd or cmd == "" then
      cmd = "open"
    end

    local subcmd = subcommands[cmd]
    if not subcmd then
      vim.notify(
        "Unknown subcommand: " .. cmd .. "\nAvailable: " .. table.concat(subcommand_names, ", "),
        vim.log.levels.ERROR,
        { title = "codediff.review" }
      )
      return
    end

    local subargs = { unpack(args, 2) }
    subcmd.fn(subargs)
  end, {
    nargs = "*",
    complete = function(arg_lead, cmd_line)
      local parts = vim.split(cmd_line, "%s+", { trimempty = true })
      if #parts <= 2 then
        return vim.tbl_filter(function(candidate)
          return candidate:find(arg_lead, 1, true) == 1
        end, subcommand_names)
      end
      return {}
    end,
    desc = "Code review commands",
  })
end

create_review_command("CodeReview")
if vim.fn.exists(":Review") == 0 then
  create_review_command("Review")
end
