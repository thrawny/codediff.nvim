local context = require("codediff.review.context")
local config = require("codediff.review.config")

local function branch_system(branch)
  return function(args)
    assert.are.same({ "git", "rev-parse", "--abbrev-ref", "HEAD" }, args)
    return { code = 0, stdout = branch .. "\n" }
  end
end

describe("codediff.review.context", function()
  before_each(function()
    config.setup()
    context.take_pending()
  end)

  it("takes the Jira key from the revision before the branch", function()
    local entries = context.entries_for_revision("CON-12-fix", {
      system = function()
        error("should not ask git for the branch")
      end,
    })
    assert.are.equal(1, #entries)
    assert.are.equal("CON-12", entries[1].key)
  end)

  it("falls back to the checked-out branch", function()
    local entries = context.entries_for_revision("abc123", { system = branch_system("feat/CON-7-thing") })
    assert.are.equal(1, #entries)
    assert.are.equal("CON-7", entries[1].key)
  end)

  it("returns nothing when no key is found", function()
    local entries = context.entries_for_revision(nil, { system = branch_system("main") })
    assert.are.equal(0, #entries)
    context.set_pending(entries)
    assert.is_false(context.has_pending())
  end)

  it("returns nothing when Jira is disabled", function()
    config.setup({ jira = { enabled = false } })
    assert.are.equal(0, #context.entries_for_revision("CON-1"))
  end)

  it("keeps the Jira entry for a PR", function()
    local entries = context.entries_for_pr({ number = 3, title = "feat(CON-9): x", headRefName = "b" })
    assert.are.equal(2, #entries)
    assert.are.equal("CON-9", entries[2].key)
  end)
end)
