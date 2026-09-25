local proxy = require("codediff.review.lsp_proxy")

describe("codediff.review.lsp_proxy", function()
  it("maps original snapshot lines to modified working-tree lines", function()
    local session = {
      stored_diff_result = {
        changes = {
          { original = { start_line = 2, end_line = 3 }, modified = { start_line = 2, end_line = 4 } },
          { original = { start_line = 6, end_line = 8 }, modified = { start_line = 7, end_line = 8 } },
        },
      },
    }

    assert.are.equal(1, proxy._test.original_to_modified_line(session, 1))
    assert.are.equal(2, proxy._test.original_to_modified_line(session, 2))
    assert.are.equal(5, proxy._test.original_to_modified_line(session, 4))
    assert.are.equal(7, proxy._test.original_to_modified_line(session, 6))
    assert.are.equal(9, proxy._test.original_to_modified_line(session, 9))
  end)

  it("converts review cursor positions to LSP positions", function()
    local session = {
      original_bufnr = 11,
      modified_bufnr = 12,
      stored_diff_result = {
        changes = {
          { original = { start_line = 2, end_line = 3 }, modified = { start_line = 2, end_line = 4 } },
        },
      },
    }

    assert.are.same({ line = 4, character = 7 }, proxy._test.real_position(session, { 4, 7 }, 11))
    assert.are.same({ line = 3, character = 7 }, proxy._test.real_position(session, { 4, 7 }, 12))
  end)

  it("flattens LSP Location and LocationLink responses", function()
    local results = {
      [1] = {
        result = {
          {
            uri = "file:///tmp/a.go",
            range = { start = { line = 1, character = 2 }, ["end"] = { line = 1, character = 3 } },
          },
          {
            targetUri = "file:///tmp/b.go",
            targetSelectionRange = { start = { line = 4, character = 5 }, ["end"] = { line = 4, character = 6 } },
          },
        },
      },
    }

    local locations = proxy._test.flatten_locations(results)
    assert.are.equal(2, #locations)
    assert.are.equal("file:///tmp/a.go", locations[1].uri)
    assert.are.equal("file:///tmp/b.go", locations[2].uri)
  end)

  it("builds Snacks picker items from LSP locations", function()
    local path = vim.fn.tempname() .. ".go"
    vim.fn.writefile({ "package a", "  func Foo() {}" }, path)
    local loc = {
      uri = vim.uri_from_fname(path),
      range = { start = { line = 1, character = 7 }, ["end"] = { line = 1, character = 10 } },
    }

    local items = proxy._test.picker_items_from_locations({ loc })
    assert.are.equal(1, #items)
    assert.are.equal(path, items[1].file)
    assert.are.same({ 2, 7 }, items[1].pos)
    assert.are.same({ 2, 10 }, items[1].end_pos)
    assert.are.equal("func Foo() {}", items[1].line)
    assert.are.equal(loc, items[1].location)
    assert.is_nil(items[1].loc)
  end)

  it("recognises the reference under the cursor", function()
    local loc = {
      uri = "file:///tmp/a.go",
      range = { start = { line = 3, character = 5 }, ["end"] = { line = 3, character = 9 } },
    }

    assert.is_true(proxy._test.is_cursor_location(loc, "file:///tmp/a.go", { line = 3, character = 7 }))
    assert.is_false(proxy._test.is_cursor_location(loc, "file:///tmp/a.go", { line = 3, character = 10 }))
    assert.is_false(proxy._test.is_cursor_location(loc, "file:///tmp/a.go", { line = 4, character = 7 }))
    assert.is_false(proxy._test.is_cursor_location(loc, "file:///tmp/b.go", { line = 3, character = 7 }))
  end)
end)
