-- Whitespace diff option coverage through the Bun engine client.

local diff = require("codediff.core.diff")

describe("ignore_whitespace", function()
  it("ignores indentation and internal spacing", function()
    local result = diff.compute_diff({ "function greet ( name )", "  return name" }, { "function greet(name)", "\treturn  name  " }, { ignore_whitespace = true })
    assert.equal(0, #result.changes)
  end)

  it("still detects non-whitespace changes", function()
    local result = diff.compute_diff({ "const value = 1" }, { "const  value=2" }, { ignore_whitespace = true })
    assert.equal(1, #result.changes)
  end)
end)

describe("ignore_trim_whitespace", function()
  it("detects whitespace-only changes when disabled", function()
    local result = diff.compute_diff({ "  hello", "world" }, { "    hello", "world" }, { ignore_trim_whitespace = false })
    assert.is_true(#result.changes > 0, "Should detect leading whitespace change")
  end)

  it("ignores leading whitespace changes when enabled", function()
    local result = diff.compute_diff({ "  hello", "world" }, { "    hello", "world" }, { ignore_trim_whitespace = true })
    assert.equal(0, #result.changes, "Should ignore leading whitespace difference")
  end)

  it("ignores trailing whitespace changes when enabled", function()
    local result = diff.compute_diff({ "hello  ", "world" }, { "hello    ", "world" }, { ignore_trim_whitespace = true })
    assert.equal(0, #result.changes, "Should ignore trailing whitespace difference")
  end)

  it("still detects content changes when whitespace is ignored", function()
    local result = diff.compute_diff({ "  hello", "world" }, { "  goodbye", "world" }, { ignore_trim_whitespace = true })
    assert.is_true(#result.changes > 0, "Should still detect non-whitespace changes")
  end)

  it("ignores indentation-only changes across multiple lines", function()
    local result = diff.compute_diff({ "function foo()", "  return 1", "end" }, { "function foo()", "    return 1", "end" }, { ignore_trim_whitespace = true })
    assert.equal(0, #result.changes, "Should ignore indentation-only differences")
  end)

  it("defaults to false when not specified", function()
    local with_default = diff.compute_diff({ "  hello" }, { "    hello" })
    local with_false = diff.compute_diff({ "  hello" }, { "    hello" }, { ignore_trim_whitespace = false })
    assert.equal(#with_default.changes, #with_false.changes, "Default behavior should match ignore_trim_whitespace=false")
  end)
end)
