// Pierre-based replacement for the old libvscode-diff C library.
//
// Computes a vscode-style LinesDiff from two arrays of lines using
// @pierre/diffs (the same diff core Hunk is built on). The output shape
// matches what the Lua side of codediff.nvim has always consumed:
// line ranges are 1-based with exclusive ends, char columns are 1-based
// UTF-16 columns (the Lua renderer converts them to byte columns).

import { parseDiffFromFile, type FileDiffMetadata } from "@pierre/diffs";
import { diffWordsWithSpace } from "diff";

export interface LineRange {
  start_line: number; // 1-based, inclusive
  end_line: number; // 1-based, EXCLUSIVE
}

export interface CharRange {
  start_line: number; // 1-based
  start_col: number; // 1-based UTF-16 column, inclusive
  end_line: number; // 1-based
  end_col: number; // 1-based UTF-16 column, EXCLUSIVE
}

export interface RangeMapping {
  original: CharRange;
  modified: CharRange;
}

export interface DetailedLineRangeMapping {
  original: LineRange;
  modified: LineRange;
  inner_changes: RangeMapping[];
}

export interface MovedText {
  original: LineRange;
  modified: LineRange;
}

export interface LinesDiff {
  changes: DetailedLineRangeMapping[];
  moves: MovedText[];
  hit_timeout: boolean;
}

export interface DiffOptions {
  ignore_trim_whitespace?: boolean;
  max_computation_time_ms?: number;
  compute_moves?: boolean;
  extend_to_subwords?: boolean;
}

const DEFAULT_TIMEOUT_MS = 5000;
// vscode does not report single-line relocations as moves; require a block.
const MIN_MOVE_LINES = 3;
// Beyond this size skip inner detail entirely (Myers is O(N*D)).
const MAX_WORD_DIFF_LENGTH = 200_000;
// Word emphasis only carries signal when it is sparse. If more than this
// fraction of either side of a block would be emphasized, drop the inner
// changes and let plain line-level highlighting tell the story.
const MAX_INNER_EMPHASIS_RATIO = 0.5;

function linesEqual(a: string[], b: string[], ignoreTrimWhitespace: boolean): boolean {
  if (a.length !== b.length) return false;
  for (let i = 0; i < a.length; i += 1) {
    const left = ignoreTrimWhitespace ? a[i]!.trim() : a[i]!;
    const right = ignoreTrimWhitespace ? b[i]!.trim() : b[i]!;
    if (left !== right) return false;
  }
  return true;
}

interface Pos {
  line: number;
  col: number;
}

function advancePos(pos: Pos, text: string): void {
  let lastNewline = -1;
  let newlines = 0;
  for (let i = 0; i < text.length; i += 1) {
    if (text.charCodeAt(i) === 10) {
      newlines += 1;
      lastNewline = i;
    }
  }
  if (newlines > 0) {
    pos.line += newlines;
    pos.col = text.length - lastNewline;
  } else {
    pos.col += text.length;
  }
}

function emptyRangeAt(pos: Pos): CharRange {
  return { start_line: pos.line, start_col: pos.col, end_line: pos.line, end_col: pos.col };
}

function rangeBetween(start: Pos, end: Pos): CharRange {
  return { start_line: start.line, start_col: start.col, end_line: end.line, end_col: end.col };
}

function wholeBlockMapping(
  origLines: string[],
  modLines: string[],
  origStartLine: number,
  modStartLine: number,
): RangeMapping {
  const origEnd = origLines.length;
  const modEnd = modLines.length;
  return {
    original: {
      start_line: origStartLine,
      start_col: 1,
      end_line: origStartLine + Math.max(origEnd - 1, 0),
      end_col: (origLines[origEnd - 1]?.length ?? 0) + 1,
    },
    modified: {
      start_line: modStartLine,
      start_col: 1,
      end_line: modStartLine + Math.max(modEnd - 1, 0),
      end_col: (modLines[modEnd - 1]?.length ?? 0) + 1,
    },
  };
}

interface ComputeState {
  deadline: number;
  hitTimeout: boolean;
}

function computeInnerChanges(
  origLines: string[],
  modLines: string[],
  origStartLine: number,
  modStartLine: number,
  state: ComputeState,
): RangeMapping[] {
  if (origLines.length === 0 || modLines.length === 0) {
    return [];
  }

  const remaining = state.deadline - Date.now();
  if (remaining <= 0) {
    state.hitTimeout = true;
    return [wholeBlockMapping(origLines, modLines, origStartLine, modStartLine)];
  }

  const origText = origLines.join("\n");
  const modText = modLines.join("\n");
  const totalLength = origText.length + modText.length;
  if (totalLength > MAX_WORD_DIFF_LENGTH) {
    return [wholeBlockMapping(origLines, modLines, origStartLine, modStartLine)];
  }

  // Word-level granularity matches Hunk's Pierre rendering (lineDiffType
  // "word-alt") and avoids the scattered single-char matches raw char diffs
  // produce, which fragment syntax token highlights downstream.
  const parts = diffWordsWithSpace(origText, modText, { timeout: remaining });
  if (!parts) {
    state.hitTimeout = true;
    return [wholeBlockMapping(origLines, modLines, origStartLine, modStartLine)];
  }

  let removedChars = 0;
  let addedChars = 0;
  for (const part of parts) {
    if (part.removed) removedChars += part.value.length;
    else if (part.added) addedChars += part.value.length;
  }
  if (
    removedChars > origText.length * MAX_INNER_EMPHASIS_RATIO ||
    addedChars > modText.length * MAX_INNER_EMPHASIS_RATIO
  ) {
    return [];
  }

  const inner: RangeMapping[] = [];
  const origPos: Pos = { line: origStartLine, col: 1 };
  const modPos: Pos = { line: modStartLine, col: 1 };

  let i = 0;
  while (i < parts.length) {
    const part = parts[i]!;
    if (!part.added && !part.removed) {
      advancePos(origPos, part.value);
      advancePos(modPos, part.value);
      i += 1;
      continue;
    }

    // jsdiff emits a removal immediately followed by its paired addition.
    let removedRange: CharRange;
    if (part.removed) {
      const start = { ...origPos };
      advancePos(origPos, part.value);
      removedRange = rangeBetween(start, origPos);
      i += 1;
    } else {
      removedRange = emptyRangeAt(origPos);
    }

    let addedRange: CharRange;
    const next = parts[i];
    if (next && next.added) {
      const start = { ...modPos };
      advancePos(modPos, next.value);
      addedRange = rangeBetween(start, modPos);
      i += 1;
    } else {
      addedRange = emptyRangeAt(modPos);
    }

    inner.push({ original: removedRange, modified: addedRange });
  }

  return inner;
}

// Detect relocated blocks: contiguous runs of deleted lines that reappear
// verbatim elsewhere in the modified file (and vice versa). The diff may
// align part of a moved block against unchanged context (e.g. a shared
// "end" line), so the target side is matched against the full file and only
// required to overlap the inserted/deleted region.
function computeMoves(
  changes: DetailedLineRangeMapping[],
  originalLines: string[],
  modifiedLines: string[],
): MovedText[] {
  const deletedSet = new Set<number>();
  const addedSet = new Set<number>();
  for (const change of changes) {
    for (let l = change.original.start_line; l < change.original.end_line; l += 1) {
      deletedSet.add(l);
    }
    for (let l = change.modified.start_line; l < change.modified.end_line; l += 1) {
      addedSet.add(l);
    }
  }
  if (deletedSet.size === 0 || addedSet.size === 0) {
    return [];
  }

  const indexLines = (lines: string[]) => {
    const index = new Map<string, number[]>();
    for (let i = 0; i < lines.length; i += 1) {
      const existing = index.get(lines[i]!);
      if (existing) {
        existing.push(i + 1);
      } else {
        index.set(lines[i]!, [i + 1]);
      }
    }
    return index;
  };

  interface Candidate {
    origStart: number;
    modStart: number;
    length: number;
  }

  const candidates: Candidate[] = [];

  const collectRuns = (
    sourceLines: string[],
    sourceChanged: Set<number>,
    targetLines: string[],
    targetChanged: Set<number>,
    targetIndex: Map<string, number[]>,
    toCandidate: (sourceStart: number, targetStart: number, length: number) => Candidate,
  ) => {
    for (const s of sourceChanged) {
      // Only start runs at the beginning of a contiguous changed block.
      if (sourceChanged.has(s - 1)) continue;
      for (const t of targetIndex.get(sourceLines[s - 1] ?? "") ?? []) {
        // Anchor moves on lines that changed on BOTH sides; a run may extend
        // over context-aligned lines but must not start on one, or the move
        // annotation would point outside the diffed region.
        if (!targetChanged.has(t)) continue;
        let k = 0;
        let hasContent = false;
        while (
          sourceChanged.has(s + k) &&
          t + k <= targetLines.length &&
          sourceLines[s + k - 1] === targetLines[t + k - 1]
        ) {
          if (sourceLines[s + k - 1]!.trim() !== "") hasContent = true;
          k += 1;
        }
        if (k >= MIN_MOVE_LINES && hasContent) {
          candidates.push(toCandidate(s, t, k));
        }
      }
    }
  };

  collectRuns(
    originalLines,
    deletedSet,
    modifiedLines,
    addedSet,
    indexLines(modifiedLines),
    (sourceStart, targetStart, length) => ({
      origStart: sourceStart,
      modStart: targetStart,
      length,
    }),
  );
  collectRuns(
    modifiedLines,
    addedSet,
    originalLines,
    deletedSet,
    indexLines(originalLines),
    (sourceStart, targetStart, length) => ({
      origStart: targetStart,
      modStart: sourceStart,
      length,
    }),
  );

  candidates.sort((a, b) => b.length - a.length);

  const usedOrig = new Set<number>();
  const usedMod = new Set<number>();
  const moves: MovedText[] = [];
  for (const candidate of candidates) {
    let overlaps = false;
    for (let t = 0; t < candidate.length; t += 1) {
      if (usedOrig.has(candidate.origStart + t) || usedMod.has(candidate.modStart + t)) {
        overlaps = true;
        break;
      }
    }
    if (overlaps) continue;
    for (let t = 0; t < candidate.length; t += 1) {
      usedOrig.add(candidate.origStart + t);
      usedMod.add(candidate.modStart + t);
    }
    moves.push({
      original: { start_line: candidate.origStart, end_line: candidate.origStart + candidate.length },
      modified: { start_line: candidate.modStart, end_line: candidate.modStart + candidate.length },
    });
  }

  moves.sort((a, b) => a.original.start_line - b.original.start_line);
  return moves;
}

function stripTrailingNewline(line: string): string {
  if (line.endsWith("\r\n")) return line.slice(0, -2);
  if (line.endsWith("\n")) return line.slice(0, -1);
  return line;
}

function toArray(lines: unknown): string[] {
  // Lua's vim.json.encode turns empty arrays into `{}`, which arrives as an
  // empty object rather than an array.
  if (Array.isArray(lines)) return lines as string[];
  return [];
}

export function computeLinesDiff(
  originalInput: unknown,
  modifiedInput: unknown,
  options: DiffOptions = {},
): LinesDiff {
  const originalLines = toArray(originalInput);
  const modifiedLines = toArray(modifiedInput);
  const ignoreTrimWhitespace = options.ignore_trim_whitespace ?? false;
  const timeoutMs = options.max_computation_time_ms || DEFAULT_TIMEOUT_MS;
  const state: ComputeState = { deadline: Date.now() + timeoutMs, hitTimeout: false };

  if (linesEqual(originalLines, modifiedLines, ignoreTrimWhitespace)) {
    return { changes: [], moves: [], hit_timeout: false };
  }

  // Neovim buffer lines all semantically end with a newline; without the
  // trailing one, jsdiff treats the last line as distinct from its
  // mid-file occurrences and merges hunks that should stay separate.
  const toContents = (lines: string[]) => (lines.length > 0 ? `${lines.join("\n")}\n` : "");
  const metadata: FileDiffMetadata = parseDiffFromFile(
    { name: "original", contents: toContents(originalLines) },
    { name: "modified", contents: toContents(modifiedLines) },
    { context: 0, ignoreWhitespace: ignoreTrimWhitespace },
  );

  const changes: DetailedLineRangeMapping[] = [];
  for (const hunk of metadata.hunks) {
    // For zero-length sides the unified header points at the line *before*
    // the change; vscode ranges point at the insertion line itself.
    let oldLine = hunk.deletionCount === 0 ? hunk.deletionStart + 1 : hunk.deletionStart;
    let newLine = hunk.additionCount === 0 ? hunk.additionStart + 1 : hunk.additionStart;
    let deletionLineIndex = hunk.deletionLineIndex;
    let additionLineIndex = hunk.additionLineIndex;

    for (const content of hunk.hunkContent) {
      if (content.type === "context") {
        oldLine += content.lines;
        newLine += content.lines;
        deletionLineIndex += content.lines;
        additionLineIndex += content.lines;
        continue;
      }

      // Pierre keeps the trailing newline on each parsed line; strip it so
      // joined block text and char positions line up with buffer columns.
      const origBlock = metadata.deletionLines
        .slice(deletionLineIndex, deletionLineIndex + content.deletions)
        .map(stripTrailingNewline);
      const modBlock = metadata.additionLines
        .slice(additionLineIndex, additionLineIndex + content.additions)
        .map(stripTrailingNewline);

      changes.push({
        original: { start_line: oldLine, end_line: oldLine + content.deletions },
        modified: { start_line: newLine, end_line: newLine + content.additions },
        inner_changes: computeInnerChanges(origBlock, modBlock, oldLine, newLine, state),
      });

      oldLine += content.deletions;
      newLine += content.additions;
      deletionLineIndex += content.deletions;
      additionLineIndex += content.additions;
    }
  }

  const moves = options.compute_moves ? computeMoves(changes, originalLines, modifiedLines) : [];

  return { changes, moves, hit_timeout: state.hitTimeout };
}
