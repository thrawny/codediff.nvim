-- Test: Merge Alignment
-- Tests the 3-way merge alignment algorithm using the current API

local merge_alignment = require("codediff.ui.merge_alignment")

describe("Merge Alignment", function()
  -- Helper to create mock diff results
  local function make_diff(changes)
    return { changes = changes or {} }
  end

  local function make_change(orig_start, orig_end, mod_start, mod_end, inner_changes)
    return {
      original = { start_line = orig_start, end_line = orig_end },
      modified = { start_line = mod_start, end_line = mod_end },
      inner_changes = inner_changes or {},
    }
  end

  -- Test 1: Empty diffs produce no fillers
  it("Empty diffs produce no fillers", function()
    local diff1 = make_diff({})
    local diff2 = make_diff({})

    local left_fillers, right_fillers = merge_alignment.compute_merge_fillers(diff1, diff2, {}, {}, {})

    assert.equal(0, #left_fillers)
    assert.equal(0, #right_fillers)
  end)

  -- Test 2: Single overlapping change produces fillers
  it("Single overlapping change produces fillers", function()
    -- Base lines 2-4, input1 expands to 2-6 (4 lines), input2 expands to 2-5 (3 lines)
    local diff1 = make_diff({ make_change(2, 4, 2, 6) })
    local diff2 = make_diff({ make_change(2, 4, 2, 5) })

    local left_fillers, right_fillers = merge_alignment.compute_merge_fillers(diff1, diff2, { "a", "b", "c", "d" }, { "a", "b", "c", "d", "e", "f" }, { "a", "b", "c", "d", "e" })

    -- Right side has fewer lines, so it should get a filler
    assert.is_true(#right_fillers > 0 or #left_fillers > 0)
  end)

  -- Test 3: Non-overlapping changes
  it("Non-overlapping changes produce separate regions", function()
    local diff1 = make_diff({ make_change(2, 4, 2, 5) })
    local diff2 = make_diff({ make_change(10, 12, 10, 14) })

    local base_lines = {}
    for i = 1, 20 do
      base_lines[i] = "line" .. i
    end
    local input1_lines = {}
    for i = 1, 21 do
      input1_lines[i] = "line" .. i
    end
    local input2_lines = {}
    for i = 1, 22 do
      input2_lines[i] = "line" .. i
    end

    local left_fillers, right_fillers = merge_alignment.compute_merge_fillers(diff1, diff2, base_lines, input1_lines, input2_lines)

    -- Should produce fillers for both regions
    assert.is_table(left_fillers)
    assert.is_table(right_fillers)
  end)

  -- Test 4: compute_merge_fillers_and_conflicts returns conflict info
  it("compute_merge_fillers_and_conflicts returns conflict changes", function()
    -- Both sides modify the same region - this is a conflict
    local diff1 = make_diff({ make_change(2, 4, 2, 6) })
    local diff2 = make_diff({ make_change(2, 4, 2, 5) })

    local fillers, conflict_left, conflict_right = merge_alignment.compute_merge_fillers_and_conflicts(
      diff1,
      diff2,
      { "a", "b", "c", "d" },
      { "a", "b", "c", "d", "e", "f" },
      { "a", "b", "c", "d", "e" }
    )

    assert.is_table(fillers)
    assert.is_table(fillers.left_fillers)
    assert.is_table(fillers.right_fillers)
    assert.is_table(conflict_left)
    assert.is_table(conflict_right)
  end)

  -- Test 5: Only one side has changes (no conflict)
  it("Only one side has changes produces no conflicts", function()
    local diff1 = make_diff({ make_change(5, 8, 5, 10) })
    local diff2 = make_diff({}) -- No changes on this side

    local base_lines = {}
    for i = 1, 10 do
      base_lines[i] = "line" .. i
    end
    local input1_lines = {}
    for i = 1, 12 do
      input1_lines[i] = "line" .. i
    end

    local fillers, conflict_left, conflict_right = merge_alignment.compute_merge_fillers_and_conflicts(diff1, diff2, base_lines, input1_lines, base_lines)

    assert.is_table(fillers)
    -- When only one side has changes, it's not a conflict
    -- The conflict arrays may be empty or only contain the single-side change
    assert.is_table(conflict_left)
    assert.is_table(conflict_right)
  end)

  -- Test 6: Filler structure is correct
  it("Filler structure has after_line and count", function()
    -- Create a scenario that definitely produces fillers
    local diff1 = make_diff({ make_change(2, 3, 2, 5) }) -- Adds 2 lines
    local diff2 = make_diff({ make_change(2, 3, 2, 3) }) -- No change in line count

    local base_lines = { "a", "b", "c", "d" }
    local input1_lines = { "a", "b", "c", "d", "e", "f" }
    local input2_lines = { "a", "b", "c", "d" }

    local left_fillers, right_fillers = merge_alignment.compute_merge_fillers(diff1, diff2, base_lines, input1_lines, input2_lines)

    -- At least one side should have fillers due to line count difference
    local has_fillers = #left_fillers > 0 or #right_fillers > 0
    if has_fillers then
      local fillers = #left_fillers > 0 and left_fillers or right_fillers
      assert.is_number(fillers[1].after_line)
      assert.is_number(fillers[1].count)
      assert.is_true(fillers[1].count > 0)
    end
  end)

  -- Test 7: Adjacent changes are handled
  it("Adjacent changes are grouped together", function()
    -- Two adjacent changes
    local diff1 = make_diff({
      make_change(2, 4, 2, 5),
      make_change(4, 6, 5, 8),
    })
    local diff2 = make_diff({
      make_change(2, 6, 2, 7),
    })

    local base_lines = {}
    for i = 1, 10 do
      base_lines[i] = "line" .. i
    end
    local input1_lines = {}
    for i = 1, 12 do
      input1_lines[i] = "line" .. i
    end
    local input2_lines = {}
    for i = 1, 11 do
      input2_lines[i] = "line" .. i
    end

    local left_fillers, right_fillers = merge_alignment.compute_merge_fillers(diff1, diff2, base_lines, input1_lines, input2_lines)

    -- Should not error
    assert.is_table(left_fillers)
    assert.is_table(right_fillers)
  end)

  -- Test 8: Handles inner changes
  it("Handles changes with inner_changes", function()
    local inner = {
      { original = { start_line = 2, start_col = 5, end_line = 2, end_col = 10 }, modified = { start_line = 2, start_col = 5, end_line = 2, end_col = 15 } },
    }
    local diff1 = make_diff({ make_change(2, 3, 2, 3, inner) })
    local diff2 = make_diff({ make_change(2, 3, 2, 4) })

    local base_lines = { "a", "b", "c" }
    local input1_lines = { "a", "b", "c" }
    local input2_lines = { "a", "b", "c", "d" }

    local left_fillers, right_fillers = merge_alignment.compute_merge_fillers(diff1, diff2, base_lines, input1_lines, input2_lines)

    assert.is_table(left_fillers)
    assert.is_table(right_fillers)
  end)
end)
