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
end)
