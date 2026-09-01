import { describe, expect, it } from "bun:test";
import { computeLinesDiff } from "./linesDiff";

describe("computeLinesDiff", () => {
  it("returns the LinesDiff structure", () => {
    const result = computeLinesDiff(["a"], ["b"]);
    expect(Array.isArray(result.changes)).toBe(true);
    expect(Array.isArray(result.moves)).toBe(true);
    expect(typeof result.hit_timeout).toBe("boolean");
  });

  it("reports no changes for identical content", () => {
    expect(computeLinesDiff(["a", "b", "c"], ["a", "b", "c"]).changes).toHaveLength(0);
    expect(computeLinesDiff([], []).changes).toHaveLength(0);
  });

  it("maps a single-line replacement", () => {
    const result = computeLinesDiff(["a", "b"], ["a", "c"]);
    expect(result.changes).toHaveLength(1);
    const change = result.changes[0]!;
    expect(change.original).toEqual({ start_line: 2, end_line: 3 });
    expect(change.modified).toEqual({ start_line: 2, end_line: 3 });
    // Fully-rewritten line: no inner emphasis, plain line highlight only.
    expect(change.inner_changes).toHaveLength(0);
  });

  it("maps an insertion with an empty original range", () => {
    const result = computeLinesDiff(["a", "b"], ["a", "x", "b"]);
    expect(result.changes).toHaveLength(1);
    const change = result.changes[0]!;
    expect(change.original.start_line).toBe(change.original.end_line);
    expect(change.modified).toEqual({ start_line: 2, end_line: 3 });
  });

  it("maps an insertion at the top of the file", () => {
    const result = computeLinesDiff(["a"], ["x", "a"]);
    expect(result.changes).toHaveLength(1);
    const change = result.changes[0]!;
    expect(change.original).toEqual({ start_line: 1, end_line: 1 });
    expect(change.modified).toEqual({ start_line: 1, end_line: 2 });
  });

  it("maps a deletion with an empty modified range", () => {
    const result = computeLinesDiff(["a", "x", "b"], ["a", "b"]);
    expect(result.changes).toHaveLength(1);
    const change = result.changes[0]!;
    expect(change.original).toEqual({ start_line: 2, end_line: 3 });
    expect(change.modified.start_line).toBe(change.modified.end_line);
  });

  it("produces 1-based char ranges with exclusive ends (word granularity)", () => {
    const result = computeLinesDiff(["const hello = 1"], ["const goodbye = 1"]);
    expect(result.changes).toHaveLength(1);
    const inner = result.changes[0]!.inner_changes;
    expect(inner.length).toBeGreaterThan(0);
    const first = inner[0]!;
    expect(first.original.start_line).toBe(1);
    expect(first.original.start_col).toBe(7);
    expect(first.original.end_col).toBe(12);
    expect(first.modified.start_col).toBe(7);
    expect(first.modified.end_col).toBe(14);
  });

  describe("ignore_whitespace", () => {
    it("ignores all whitespace inside lines", () => {
      const result = computeLinesDiff(
        ["function greet ( name ) {", "  return name;", "}"],
        ["function greet(name){", "\treturn  name;  ", "}"],
        { ignore_whitespace: true },
      );
      expect(result.changes).toHaveLength(0);
    });

    it("still detects non-whitespace changes", () => {
      const result = computeLinesDiff(["const value = 1;"], ["const  value=2;"], {
        ignore_whitespace: true,
      });
      expect(result.changes).toHaveLength(1);
      expect(result.changes[0]!.original).toEqual({ start_line: 1, end_line: 2 });
      expect(result.changes[0]!.modified).toEqual({ start_line: 1, end_line: 2 });
    });

    it("takes precedence over trim-only comparison", () => {
      const result = computeLinesDiff(["call(one, two)"], ["call(one,two)"], {
        ignore_whitespace: true,
        ignore_trim_whitespace: false,
      });
      expect(result.changes).toHaveLength(0);
    });
  });

  describe("ignore_trim_whitespace", () => {
    it("detects whitespace-only changes when disabled", () => {
      const result = computeLinesDiff(["  hello", "world"], ["    hello", "world"], {
        ignore_trim_whitespace: false,
      });
      expect(result.changes.length).toBeGreaterThan(0);
    });

    it("ignores leading/trailing whitespace changes when enabled", () => {
      const leading = computeLinesDiff(["  hello", "world"], ["    hello", "world"], {
        ignore_trim_whitespace: true,
      });
      expect(leading.changes).toHaveLength(0);

      const trailing = computeLinesDiff(["hello  ", "world"], ["hello    ", "world"], {
        ignore_trim_whitespace: true,
      });
      expect(trailing.changes).toHaveLength(0);
    });

    it("still detects content changes when whitespace is ignored", () => {
      const result = computeLinesDiff(["  hello", "world"], ["  goodbye", "world"], {
        ignore_trim_whitespace: true,
      });
      expect(result.changes.length).toBeGreaterThan(0);
    });

    it("ignores mixed indentation-only changes", () => {
      const result = computeLinesDiff(
        ["function foo()", "  return 1", "end"],
        ["function foo()", "    return 1", "end"],
        { ignore_trim_whitespace: true },
      );
      expect(result.changes).toHaveLength(0);
    });
  });

  describe("move detection", () => {
    const orig = ["function foo()", "  return 1", "end", "", "function bar()", "  return 2", "end"];
    const mod = ["function bar()", "  return 2", "end", "", "function foo()", "  return 1", "end"];

    it("detects a move when two blocks are swapped", () => {
      const result = computeLinesDiff(orig, mod, { compute_moves: true });
      expect(result.moves).toHaveLength(1);
      const move = result.moves[0]!;
      expect(move.original.end_line - move.original.start_line).toBe(
        move.modified.end_line - move.modified.start_line,
      );
      expect(move.original.end_line - move.original.start_line).toBeGreaterThanOrEqual(3);
    });

    it("returns empty moves when compute_moves is false", () => {
      const result = computeLinesDiff(orig, mod, { compute_moves: false });
      expect(result.moves).toHaveLength(0);
    });

    it("does not report a single moved line", () => {
      const result = computeLinesDiff(
        ["aaa", "local x = 42", "bbb", "ccc"],
        ["aaa", "bbb", "ccc", "local x = 42"],
        { compute_moves: true },
      );
      expect(result.moves).toHaveLength(0);
    });

    it("reports no moves for normal edits", () => {
      const result = computeLinesDiff(
        ["line 1", "line 2", "line 3"],
        ["line 1", "changed 2", "line 3", "new line"],
        { compute_moves: true },
      );
      expect(result.moves).toHaveLength(0);
    });

    it("produces identical changes regardless of compute_moves", () => {
      const withMoves = computeLinesDiff(orig, mod, { compute_moves: true });
      const withoutMoves = computeLinesDiff(orig, mod, { compute_moves: false });
      expect(withMoves.changes).toEqual(withoutMoves.changes);
    });
  });

  it("handles large inputs", () => {
    const a: string[] = [];
    const b: string[] = [];
    for (let i = 1; i <= 1000; i += 1) {
      a.push(`line ${i}`);
      b.push(`modified ${i}`);
    }
    const result = computeLinesDiff(a, b);
    expect(result.changes.length).toBeGreaterThan(0);
  });

  it("keeps inner change positions within the mapping bounds", () => {
    const orig = ["function a()", "  local x = compute(1, 2)", "  return x + 1", "end"];
    const mod = [
      "function a()",
      "  local y = compute(3, 4)",
      "  local z = y * 2",
      "  return z + 1",
      "end",
    ];
    const result = computeLinesDiff(orig, mod);
    for (const change of result.changes) {
      for (const inner of change.inner_changes) {
        expect(inner.original.start_line).toBeGreaterThanOrEqual(change.original.start_line);
        expect(inner.original.end_line).toBeLessThanOrEqual(
          Math.max(change.original.end_line, change.original.start_line),
        );
        expect(inner.modified.start_line).toBeGreaterThanOrEqual(change.modified.start_line);
        expect(inner.modified.end_line).toBeLessThanOrEqual(
          Math.max(change.modified.end_line, change.modified.start_line),
        );
      }
    }
  });

  describe("inner emphasis sparseness", () => {
    it("keeps emphasis for a small edit inside a line", () => {
      const result = computeLinesDiff(["local x = compute(1, 2)"], ["local y = compute(1, 2)"]);
      expect(result.changes[0]!.inner_changes.length).toBeGreaterThan(0);
    });

    it("drops emphasis when a multi-line block collapses to one line", () => {
      const result = computeLinesDiff(
        [
          "home-manager.extraSpecialArgs = flakeArgs // {",
          "  containerAssets = storeHomeAssets;",
          "};",
        ],
        ["home-manager.extraSpecialArgs = flakeArgs;"],
      );
      expect(result.changes).toHaveLength(1);
      expect(result.changes[0]!.inner_changes).toHaveLength(0);
    });

    it("drops emphasis for a fully-rewritten block", () => {
      const result = computeLinesDiff(["alpha beta gamma"], ["delta epsilon zeta"]);
      expect(result.changes[0]!.inner_changes).toHaveLength(0);
    });
  });

  it("keeps separate hunks when the last line matches mid-file content", () => {
    const result = computeLinesDiff(
      ["line1", "line2", "line3"],
      ["line1", "changed", "line3", "appended_line"],
    );
    expect(result.changes).toHaveLength(2);
    expect(result.changes[0]!.original).toEqual({ start_line: 2, end_line: 3 });
    expect(result.changes[1]!.modified).toEqual({ start_line: 4, end_line: 5 });
  });

  it("treats non-array input as empty", () => {
    const result = computeLinesDiff({}, {});
    expect(result.changes).toHaveLength(0);
  });
});
