// @bun
var __esm = (fn, res, err) => () => {
  if (fn)
    try {
      res = fn(fn = 0);
    } catch (e) {
      err = [e];
    }
  if (err)
    throw err[0];
  return res;
};

// node_modules/@pierre/diffs/dist/constants.js
var GIT_DIFF_FILE_BREAK_REGEX, FILENAME_HEADER_REGEX, INDEX_LINE_METADATA, DEFAULT_VIRTUAL_FILE_METRICS, DEFAULT_CODE_VIEW_FILE_METRICS, DEFAULT_EXPANDED_REGION, EMPTY_LINE_ANNOTATIONS;
var init_constants = __esm(() => {
  GIT_DIFF_FILE_BREAK_REGEX = /(?=^diff --git)/gm;
  FILENAME_HEADER_REGEX = /^(---|\+\+\+)\s+([^\t\r\n]+)/;
  INDEX_LINE_METADATA = /^index ([0-9a-f]+)\.\.([0-9a-f]+)(?: (\d+))?$/i;
  DEFAULT_VIRTUAL_FILE_METRICS = {
    hunkLineCount: 50,
    lineHeight: 20,
    diffHeaderHeight: 44,
    spacing: 8
  };
  DEFAULT_CODE_VIEW_FILE_METRICS = {
    ...DEFAULT_VIRTUAL_FILE_METRICS,
    hunkLineCount: 1
  };
  DEFAULT_EXPANDED_REGION = Object.freeze({
    fromStart: 0,
    fromEnd: 0
  });
  EMPTY_LINE_ANNOTATIONS = Object.freeze([]);
});

// src/main.ts
import { readFileSync } from "fs";

// node_modules/@pierre/diffs/dist/utils/getHunkSideBoundaries.js
function getHunkSideStartBoundary(start, count) {
  return start - (count === 0 ? 0 : 1);
}
function getHunkSideEndBoundary(start, count) {
  return getHunkSideStartBoundary(start, count) + count;
}

// node_modules/@pierre/diffs/dist/utils/cleanLastNewline.js
function cleanLastNewline(contents) {
  let end = contents.length;
  if (contents.charCodeAt(end - 1) === 10) {
    end--;
    if (contents.charCodeAt(end - 1) === 13)
      end--;
  }
  return contents.slice(0, end);
}

// node_modules/@pierre/diffs/dist/utils/composeCacheKey.js
var CACHE_KEY_VERSION = 1;
function composeCacheKey(scope, ...segments) {
  return `ck${CACHE_KEY_VERSION}:${JSON.stringify([scope, ...segments])}`;
}

// node_modules/@pierre/diffs/dist/utils/detachString.js
var stringDetachEncoder = new TextEncoder;
var stringDetachDecoder = new TextDecoder("utf-8", { ignoreBOM: true });
var SURROGATE_CODE_UNIT_PATTERN = /[\uD800-\uDFFF]/;
var STRING_DETACH_INITIAL_BUFFER_SIZE = 1024;
var stringDetachBuffer = new Uint8Array(STRING_DETACH_INITIAL_BUFFER_SIZE);
function releaseStringDetachBuffer() {
  if (stringDetachBuffer.length !== STRING_DETACH_INITIAL_BUFFER_SIZE)
    stringDetachBuffer = new Uint8Array(STRING_DETACH_INITIAL_BUFFER_SIZE);
}
function detachString(value) {
  if (value.length === 0)
    return value;
  if (SURROGATE_CODE_UNIT_PATTERN.test(value))
    return JSON.parse(JSON.stringify(value));
  const requiredByteLength = value.length * 3;
  if (stringDetachBuffer.length < requiredByteLength)
    stringDetachBuffer = new Uint8Array(requiredByteLength);
  const { written } = stringDetachEncoder.encodeInto(value, stringDetachBuffer);
  return stringDetachDecoder.decode(stringDetachBuffer.subarray(0, written));
}

// node_modules/@pierre/diffs/dist/utils/parsePatchFiles.js
init_constants();

// node_modules/@pierre/diffs/dist/utils/parseQuotedDiffFileName.js
var filenameDecoder = new TextDecoder("utf-8", { ignoreBOM: true });
var NAMED_ESCAPES = {
  '"': '"',
  "\\": "\\",
  a: "\x07",
  b: "\b",
  t: "\t",
  n: `
`,
  v: "\v",
  f: "\f",
  r: "\r"
};
function parseQuotedDiffFileName(input) {
  if (input[0] !== '"')
    return;
  let fileName = "";
  let index = 1;
  while (index < input.length) {
    const char = input[index];
    if (char === '"')
      return {
        fileName,
        rawLength: index + 1
      };
    if (char !== "\\") {
      fileName += char;
      index++;
      continue;
    }
    const escaped = NAMED_ESCAPES[input[index + 1]];
    if (escaped != null) {
      fileName += escaped;
      index += 2;
      continue;
    }
    const bytes = [];
    do {
      const byte = readOctalByte(input, index + 1);
      if (byte == null)
        return;
      bytes.push(byte);
      index += 4;
    } while (input[index] === "\\" && input[index + 1] >= "0" && input[index + 1] <= "7");
    fileName += filenameDecoder.decode(new Uint8Array(bytes));
  }
}
function readOctalByte(input, index) {
  const first = input.charCodeAt(index) - 48;
  const second = input.charCodeAt(index + 1) - 48;
  const third = input.charCodeAt(index + 2) - 48;
  if (first >= 0 && first <= 3 && second >= 0 && second <= 7 && third >= 0 && third <= 7)
    return first * 64 + second * 8 + third;
}

// node_modules/@pierre/diffs/dist/utils/realignChangeContent.js
var MAX_ALIGNMENT_COMPARISONS = 4096;
var MIN_IMPROVEMENT_PER_PAIR = 0.5;
function realignChangeContentBySimilarity(diff) {
  for (const hunk of diff.hunks)
    for (let index = 0;index < hunk.hunkContent.length; index++) {
      const content = hunk.hunkContent[index];
      if (content.type !== "change")
        continue;
      const replacement = realignChangeBlock(diff, content);
      if (replacement != null) {
        hunk.hunkContent.splice(index, 1, ...replacement);
        index += replacement.length - 1;
      }
    }
}
function realignChangeBlock(diff, content) {
  const { deletions, additions, deletionLineIndex, additionLineIndex } = content;
  const pairCount = Math.min(deletions, additions);
  const surplus = Math.abs(additions - deletions);
  if (pairCount === 0 || surplus === 0 || pairCount * (surplus + 1) > MAX_ALIGNMENT_COMPARISONS)
    return null;
  const strippedDeletions = [];
  for (let line = 0;line < deletions; line++)
    strippedDeletions.push(stripWhitespace(diff.deletionLines[deletionLineIndex + line] ?? ""));
  const strippedAdditions = [];
  for (let line = 0;line < additions; line++)
    strippedAdditions.push(stripWhitespace(diff.additionLines[additionLineIndex + line] ?? ""));
  const additionsAreLonger = additions > deletions;
  let bestOffset = 0;
  let bestScore = -1;
  for (let offset = 0;offset <= surplus; offset++) {
    let score = 0;
    for (let pair = 0;pair < pairCount; pair++)
      score += lineSimilarity(strippedDeletions[pair + (additionsAreLonger ? 0 : offset)], strippedAdditions[pair + (additionsAreLonger ? offset : 0)]);
    if (offset === 0)
      bestScore = score + pairCount * MIN_IMPROVEMENT_PER_PAIR;
    else if (score > bestScore) {
      bestScore = score;
      bestOffset = offset;
    }
  }
  if (bestOffset === 0)
    return null;
  const blocks = [];
  const pushBlock = (blockDeletions, blockAdditions, blockDeletionIndex, blockAdditionIndex) => {
    if (blockDeletions > 0 || blockAdditions > 0)
      blocks.push({
        type: "change",
        deletions: blockDeletions,
        additions: blockAdditions,
        deletionLineIndex: blockDeletionIndex,
        additionLineIndex: blockAdditionIndex
      });
  };
  if (additionsAreLonger) {
    pushBlock(0, bestOffset, deletionLineIndex, additionLineIndex);
    pushBlock(pairCount, pairCount, deletionLineIndex, additionLineIndex + bestOffset);
    pushBlock(0, additions - pairCount - bestOffset, deletionLineIndex + pairCount, additionLineIndex + bestOffset + pairCount);
  } else {
    pushBlock(bestOffset, 0, deletionLineIndex, additionLineIndex);
    pushBlock(pairCount, pairCount, deletionLineIndex + bestOffset, additionLineIndex);
    pushBlock(deletions - pairCount - bestOffset, 0, deletionLineIndex + bestOffset + pairCount, additionLineIndex + pairCount);
  }
  return blocks;
}
var WHITESPACE = /\s+/g;
function stripWhitespace(line) {
  return line.replace(WHITESPACE, "");
}
function lineSimilarity(a, b) {
  if (a === b)
    return 1;
  const maxLength = Math.max(a.length, b.length);
  const minLength = Math.min(a.length, b.length);
  if (minLength === 0)
    return 0;
  let prefix = 0;
  while (prefix < minLength && a[prefix] === b[prefix])
    prefix++;
  let suffix = 0;
  while (suffix < minLength - prefix && a[a.length - 1 - suffix] === b[b.length - 1 - suffix])
    suffix++;
  return (prefix + suffix) / maxLength;
}

// node_modules/@pierre/diffs/dist/utils/parsePatchFiles.js
var GIT_DIFF_HEADER_FILENAMES = /^diff --git ("a\/(?:[^"\\]|\\.)*"|a\/.+?) ("b\/(?:[^"\\]|\\.)*"|b\/.+?)$/;
function processFile(fileDiffString, options) {
  try {
    return _processFile(fileDiffString, options);
  } finally {
    releaseStringDetachBuffer();
  }
}
function _processFile(fileDiffString, { cacheKey, disableLineMatching = false, isGitDiff = GIT_DIFF_FILE_BREAK_REGEX.test(fileDiffString), oldFile, newFile, throwOnError = false } = {}) {
  let lastHunkEnd = 0;
  const hunks = splitAtLinePrefix(fileDiffString, "@@ ");
  let currentFile;
  const isPartial = oldFile == null || newFile == null;
  let deletionLineIndex = 0;
  let additionLineIndex = 0;
  for (const hunk of hunks) {
    const lines = splitWithNewlines(hunk);
    const firstLine = lines[0];
    if (firstLine == null) {
      if (throwOnError)
        throw Error("parsePatchContent: invalid hunk");
      else
        console.error("parsePatchContent: invalid hunk", hunk);
      continue;
    }
    const fileHeader = parseHunkHeader(firstLine);
    let additionLines = 0;
    let deletionLines = 0;
    if (fileHeader == null || currentFile == null) {
      if (currentFile != null) {
        if (throwOnError)
          throw Error("parsePatchContent: Invalid hunk");
        else
          console.error("parsePatchContent: Invalid hunk", hunk);
        continue;
      }
      currentFile = {
        name: "",
        type: "change",
        hunks: [],
        splitLineCount: 0,
        unifiedLineCount: 0,
        isPartial,
        additionLines: !isPartial && oldFile != null && newFile != null ? splitFileContents(newFile.contents) : [],
        deletionLines: !isPartial && oldFile != null && newFile != null ? splitFileContents(oldFile.contents) : [],
        additionCharacterCount: !isPartial && oldFile != null && newFile != null ? newFile.contents.length : 0,
        deletionCharacterCount: !isPartial && oldFile != null && newFile != null ? oldFile.contents.length : 0,
        cacheKey: maybeDetachOptionalString(cacheKey)
      };
      if (currentFile.additionLines.length === 1 && newFile?.contents === "")
        currentFile.additionLines.length = 0;
      if (currentFile.deletionLines.length === 1 && oldFile?.contents === "")
        currentFile.deletionLines.length = 0;
      for (const line of lines) {
        if (line.startsWith("diff --git")) {
          const filenameMatch = line.trim().match(GIT_DIFF_HEADER_FILENAMES);
          if (filenameMatch == null) {
            if (throwOnError)
              throw Error("parsePatchContent: invalid git diff header");
            else
              console.error("parsePatchContent: invalid git diff header", line);
            continue;
          }
          const prevName = decodeDiffFileName(filenameMatch[1], true);
          const name = decodeDiffFileName(filenameMatch[2], true);
          currentFile.name = detachString(name);
          if (prevName !== name)
            currentFile.prevName = detachString(prevName);
          continue;
        }
        const filenameMatch = line.startsWith("---") || line.startsWith("+++") ? line.match(FILENAME_HEADER_REGEX) : null;
        if (filenameMatch != null) {
          const [, type, rawFileName] = filenameMatch;
          const fileName = decodeDiffFileName(rawFileName, isGitDiff);
          if (type === "---" && fileName !== "/dev/null") {
            const detachedFileName = detachString(fileName);
            currentFile.prevName = detachedFileName;
            currentFile.name = detachedFileName;
          } else if (type === "+++" && fileName !== "/dev/null")
            currentFile.name = detachString(fileName);
        } else if (isGitDiff) {
          if (line.startsWith("new mode "))
            currentFile.mode = detachString(line.slice(8).trim());
          if (line.startsWith("old mode "))
            currentFile.prevMode = detachString(line.slice(8).trim());
          if (line.startsWith("new file mode")) {
            currentFile.type = "new";
            currentFile.mode = detachString(line.slice(13).trim());
          }
          if (line.startsWith("deleted file mode")) {
            currentFile.type = "deleted";
            currentFile.mode = detachString(line.slice(17).trim());
          }
          if (line.startsWith("similarity index")) {
            if (line.startsWith("similarity index 100%"))
              currentFile.type = "rename-pure";
            else
              currentFile.type = "rename-changed";
          }
          if (line.startsWith("index ")) {
            const [, prevObjectId, newObjectId, mode] = line.trim().match(INDEX_LINE_METADATA) ?? [];
            if (prevObjectId != null)
              currentFile.prevObjectId = detachString(prevObjectId);
            if (newObjectId != null)
              currentFile.newObjectId = detachString(newObjectId);
            if (mode != null)
              currentFile.mode = detachString(mode);
          }
          if (line.startsWith("rename from ") || line.startsWith("copy from "))
            currentFile.prevName = detachString(decodeDiffFileName(line.slice(line.startsWith("rename") ? 12 : 10)));
          if (line.startsWith("rename to ") || line.startsWith("copy to "))
            currentFile.name = detachString(decodeDiffFileName(line.slice(line.startsWith("rename") ? 10 : 8)));
        }
      }
      continue;
    }
    let currentContent;
    let lastLineType;
    while (lines.length > 0 && (lines[lines.length - 1] === `
` || lines[lines.length - 1] === "\r" || lines[lines.length - 1] === `\r
` || lines[lines.length - 1] === ""))
      lines.pop();
    const { additionStart, deletionStart } = fileHeader;
    deletionLineIndex = isPartial ? deletionLineIndex : deletionStart - 1;
    additionLineIndex = isPartial ? additionLineIndex : additionStart - 1;
    const hunkData = {
      collapsedBefore: 0,
      splitLineCount: 0,
      splitLineStart: 0,
      unifiedLineCount: 0,
      unifiedLineStart: 0,
      additionCount: fileHeader.additionCount,
      additionStart,
      additionLines,
      deletionCount: fileHeader.deletionCount,
      deletionStart,
      deletionLines,
      deletionLineIndex,
      additionLineIndex,
      hunkContent: [],
      hunkContext: maybeDetachOptionalString(fileHeader.hunkContext),
      hunkSpecs: detachString(firstLine),
      noEOFCRAdditions: false,
      noEOFCRDeletions: false
    };
    let parsedAdditionLines = 0;
    let parsedDeletionLines = 0;
    for (let lineIndex = 1;lineIndex < lines.length; lineIndex++) {
      const rawLine = lines[lineIndex];
      if (parsedAdditionLines >= hunkData.additionCount && parsedDeletionLines >= hunkData.deletionCount && !rawLine.startsWith("\\")) {
        if (!(isHunkBodyLine(rawLine) && !isFormatPatchVersionSeparator(rawLine)))
          break;
        if (throwOnError)
          throw Error("parsePatchContent: hunk has more lines than expected");
      }
      const firstChar = rawLine[0];
      if (firstChar !== "+" && firstChar !== "-" && firstChar !== " " && firstChar !== "\\") {
        if (throwOnError)
          throw Error("parsePatchContent: invalid hunk line");
        console.error(`parseLineType: Invalid firstChar: "${firstChar}", full line: "${rawLine}"`);
        console.error("processFile: invalid rawLine:", rawLine);
        continue;
      }
      const type = parseRawLineType(firstChar);
      if (type === "addition") {
        if (throwOnError && parsedAdditionLines >= hunkData.additionCount)
          throw Error("parsePatchContent: hunk has too many addition lines");
        const line = getParsedLineContent(rawLine);
        if (currentContent == null || currentContent.type !== "change") {
          currentContent = createContentGroup("change", deletionLineIndex, additionLineIndex);
          hunkData.hunkContent.push(currentContent);
        }
        additionLineIndex++;
        parsedAdditionLines++;
        if (isPartial) {
          currentFile.additionLines.push(line);
          currentFile.additionCharacterCount += line.length;
        }
        currentContent.additions++;
        additionLines++;
        lastLineType = "addition";
      } else if (type === "deletion") {
        if (throwOnError && parsedDeletionLines >= hunkData.deletionCount)
          throw Error("parsePatchContent: hunk has too many deletion lines");
        const line = getParsedLineContent(rawLine);
        if (currentContent == null || currentContent.type !== "change") {
          currentContent = createContentGroup("change", deletionLineIndex, additionLineIndex);
          hunkData.hunkContent.push(currentContent);
        }
        deletionLineIndex++;
        parsedDeletionLines++;
        if (isPartial) {
          currentFile.deletionLines.push(line);
          currentFile.deletionCharacterCount += line.length;
        }
        currentContent.deletions++;
        deletionLines++;
        lastLineType = "deletion";
      } else if (type === "context") {
        if (throwOnError && (parsedDeletionLines >= hunkData.deletionCount || parsedAdditionLines >= hunkData.additionCount))
          throw Error("parsePatchContent: hunk has too many context lines");
        const line = getParsedLineContent(rawLine);
        if (currentContent == null || currentContent.type !== "context") {
          currentContent = createContentGroup("context", deletionLineIndex, additionLineIndex);
          hunkData.hunkContent.push(currentContent);
        }
        additionLineIndex++;
        deletionLineIndex++;
        parsedAdditionLines++;
        parsedDeletionLines++;
        if (isPartial) {
          currentFile.deletionLines.push(line);
          currentFile.additionLines.push(line);
          currentFile.deletionCharacterCount += line.length;
          currentFile.additionCharacterCount += line.length;
        }
        currentContent.lines++;
        lastLineType = "context";
      } else if (type === "metadata" && currentContent != null) {
        if (currentContent.type === "context") {
          hunkData.noEOFCRAdditions = true;
          hunkData.noEOFCRDeletions = true;
        } else if (lastLineType === "deletion")
          hunkData.noEOFCRDeletions = true;
        else if (lastLineType === "addition")
          hunkData.noEOFCRAdditions = true;
        if (isPartial && (lastLineType === "addition" || lastLineType === "context")) {
          const lastIndex = currentFile.additionLines.length - 1;
          if (lastIndex >= 0) {
            const line = currentFile.additionLines[lastIndex];
            const cleanedLine = cleanLastNewline(line);
            currentFile.additionLines[lastIndex] = cleanedLine;
            currentFile.additionCharacterCount += cleanedLine.length - line.length;
          }
        }
        if (isPartial && (lastLineType === "deletion" || lastLineType === "context")) {
          const lastIndex = currentFile.deletionLines.length - 1;
          if (lastIndex >= 0) {
            const line = currentFile.deletionLines[lastIndex];
            const cleanedLine = cleanLastNewline(line);
            currentFile.deletionLines[lastIndex] = cleanedLine;
            currentFile.deletionCharacterCount += cleanedLine.length - line.length;
          }
        }
      }
    }
    if (parsedAdditionLines !== hunkData.additionCount || parsedDeletionLines !== hunkData.deletionCount) {
      if (throwOnError)
        throw Error("parsePatchContent: hunk line count mismatch");
      console.error(`parsePatchContent: hunk line count mismatch: "${firstLine.trimEnd()}", declared old/new ${hunkData.deletionCount}/${hunkData.additionCount}, parsed old/new ${parsedDeletionLines}/${parsedAdditionLines}`);
      const repairedAdditionStart = getHunkSideStartBoundary(hunkData.additionStart, hunkData.additionCount) + (parsedAdditionLines === 0 ? 0 : 1);
      const repairedDeletionStart = getHunkSideStartBoundary(hunkData.deletionStart, hunkData.deletionCount) + (parsedDeletionLines === 0 ? 0 : 1);
      if (!isPartial) {
        const additionStartDelta = repairedAdditionStart - hunkData.additionStart;
        const deletionStartDelta = repairedDeletionStart - hunkData.deletionStart;
        hunkData.additionLineIndex += additionStartDelta;
        hunkData.deletionLineIndex += deletionStartDelta;
        for (const content of hunkData.hunkContent) {
          content.additionLineIndex += additionStartDelta;
          content.deletionLineIndex += deletionStartDelta;
        }
      }
      hunkData.additionStart = repairedAdditionStart;
      hunkData.deletionStart = repairedDeletionStart;
      hunkData.additionCount = parsedAdditionLines;
      hunkData.deletionCount = parsedDeletionLines;
    }
    hunkData.additionLines = additionLines;
    hunkData.deletionLines = deletionLines;
    hunkData.collapsedBefore = Math.max(getHunkSideStartBoundary(hunkData.additionStart, hunkData.additionCount) - lastHunkEnd, 0);
    currentFile.hunks.push(hunkData);
    lastHunkEnd = getHunkSideEndBoundary(hunkData.additionStart, hunkData.additionCount);
    for (const content of hunkData.hunkContent)
      if (content.type === "context") {
        hunkData.splitLineCount += content.lines;
        hunkData.unifiedLineCount += content.lines;
      } else {
        hunkData.splitLineCount += Math.max(content.additions, content.deletions);
        hunkData.unifiedLineCount += content.deletions + content.additions;
      }
    hunkData.splitLineStart = currentFile.splitLineCount + hunkData.collapsedBefore;
    hunkData.unifiedLineStart = currentFile.unifiedLineCount + hunkData.collapsedBefore;
    currentFile.splitLineCount += hunkData.collapsedBefore + hunkData.splitLineCount;
    currentFile.unifiedLineCount += hunkData.collapsedBefore + hunkData.unifiedLineCount;
  }
  if (currentFile == null)
    return;
  if (throwOnError && isPartial && !isGitDiff && currentFile.hunks.length === 0)
    throw Error("parsePatchContent: unified file has no hunks");
  if (currentFile.hunks.length > 0 && !isPartial && currentFile.additionLines.length > 0 && currentFile.deletionLines.length > 0) {
    const lastHunk = currentFile.hunks[currentFile.hunks.length - 1];
    const lastHunkEnd = getHunkSideEndBoundary(lastHunk.additionStart, lastHunk.additionCount);
    const totalFileLines = currentFile.additionLines.length;
    const collapsedAfter = Math.max(totalFileLines - lastHunkEnd, 0);
    currentFile.splitLineCount += collapsedAfter;
    currentFile.unifiedLineCount += collapsedAfter;
  }
  if (!isGitDiff) {
    if (currentFile.prevName != null && currentFile.name !== currentFile.prevName) {
      if (currentFile.hunks.length > 0)
        currentFile.type = "rename-changed";
      else
        currentFile.type = "rename-pure";
    } else if ((oldFile == null || oldFile.contents === "") && newFile != null && newFile.contents !== "")
      currentFile.type = "new";
    else if (oldFile != null && oldFile.contents !== "" && (newFile == null || newFile.contents === ""))
      currentFile.type = "deleted";
  }
  if (currentFile.type !== "rename-pure" && currentFile.type !== "rename-changed")
    currentFile.prevName = undefined;
  if (!disableLineMatching)
    realignChangeContentBySimilarity(currentFile);
  return currentFile;
}
function decodeDiffFileName(value, stripGitPrefix = false) {
  const rawName = value.trim();
  const name = rawName.startsWith('"') ? parseQuotedDiffFileName(rawName)?.fileName ?? rawName : rawName;
  return stripGitPrefix && (name.startsWith("a/") || name.startsWith("b/")) ? name.slice(2) : name;
}
function splitFileContents(contents) {
  const lines = splitWithNewlines(contents);
  for (let index = 0;index < lines.length; index++)
    lines[index] = detachString(lines[index]);
  return lines;
}
function splitWithNewlines(contents) {
  if (contents.length === 0)
    return [""];
  const lines = [];
  let startIndex = 0;
  for (;; ) {
    const newlineIndex = contents.indexOf(`
`, startIndex);
    if (newlineIndex === -1)
      break;
    lines.push(contents.slice(startIndex, newlineIndex + 1));
    startIndex = newlineIndex + 1;
  }
  if (startIndex < contents.length)
    lines.push(contents.slice(startIndex));
  return lines;
}
function isHunkBodyLine(line) {
  const firstChar = line[0];
  return firstChar === "+" || firstChar === "-" || firstChar === " ";
}
function isFormatPatchVersionSeparator(line) {
  if (!line.startsWith("--"))
    return false;
  for (let index = 2;index < line.length; index++) {
    const char = line[index];
    if (char !== " " && char !== "\t" && char !== `
` && char !== "\r")
      return false;
  }
  return true;
}
function parseHunkHeader(line) {
  if (!line.startsWith("@@ -"))
    return;
  let index = 4;
  const deletionStartResult = readPositiveInteger(line, index);
  if (deletionStartResult == null)
    return;
  const deletionStart = deletionStartResult.value;
  index = deletionStartResult.endIndex;
  let deletionCount = 1;
  if (line[index] === ",") {
    const deletionCountResult = readPositiveInteger(line, index + 1);
    if (deletionCountResult == null)
      return;
    deletionCount = deletionCountResult.value;
    index = deletionCountResult.endIndex;
  }
  if (line[index] !== " " || line[index + 1] !== "+")
    return;
  index += 2;
  const additionStartResult = readPositiveInteger(line, index);
  if (additionStartResult == null)
    return;
  const additionStart = additionStartResult.value;
  index = additionStartResult.endIndex;
  let additionCount = 1;
  if (line[index] === ",") {
    const additionCountResult = readPositiveInteger(line, index + 1);
    if (additionCountResult == null)
      return;
    additionCount = additionCountResult.value;
    index = additionCountResult.endIndex;
  }
  if (line[index] !== " " || line[index + 1] !== "@" || line[index + 2] !== "@")
    return;
  let hunkContext;
  const contextStartIndex = index + 3;
  if (line[contextStartIndex] === " ")
    hunkContext = trimLineEnd(line.slice(contextStartIndex + 1));
  return {
    additionCount,
    additionStart,
    deletionCount,
    deletionStart,
    hunkContext
  };
}
function readPositiveInteger(value, startIndex) {
  let index = startIndex;
  let parsedValue = 0;
  for (;index < value.length; index++) {
    const digit = value.charCodeAt(index) - 48;
    if (digit < 0 || digit > 9)
      break;
    parsedValue = parsedValue * 10 + digit;
  }
  if (index === startIndex)
    return;
  return {
    value: parsedValue,
    endIndex: index
  };
}
function trimLineEnd(value) {
  if (value.endsWith(`\r
`))
    return value.slice(0, -2);
  if (value.endsWith(`
`))
    return value.slice(0, -1);
  return value;
}
function splitAtLinePrefix(contents, prefix) {
  if (contents.length === 0)
    return [""];
  const newlinePrefix = `
${prefix}`;
  const firstBoundaryIndex = contents.startsWith(prefix) ? 0 : findLinePrefixIndex(contents, newlinePrefix, 0);
  if (firstBoundaryIndex === -1)
    return [contents];
  const parts = [];
  if (firstBoundaryIndex > 0)
    parts.push(contents.slice(0, firstBoundaryIndex));
  let startIndex = firstBoundaryIndex;
  for (;; ) {
    const nextBoundaryIndex = findLinePrefixIndex(contents, newlinePrefix, startIndex + 1);
    if (nextBoundaryIndex === -1)
      break;
    parts.push(contents.slice(startIndex, nextBoundaryIndex));
    startIndex = nextBoundaryIndex;
  }
  parts.push(contents.slice(startIndex));
  return parts;
}
function findLinePrefixIndex(contents, newlinePrefix, fromIndex) {
  const index = contents.indexOf(newlinePrefix, fromIndex);
  return index === -1 ? -1 : index + 1;
}
function maybeDetachOptionalString(value) {
  return value == null ? value : detachString(value);
}
function parseRawLineType(firstChar) {
  return firstChar === " " ? "context" : firstChar === "\\" ? "metadata" : firstChar === "+" ? "addition" : "deletion";
}
function getParsedLineContent(rawLine) {
  const processedLine = rawLine.slice(1);
  return detachString(processedLine === "" ? `
` : processedLine);
}
function createContentGroup(type, deletionLineIndex, additionLineIndex) {
  if (type === "change")
    return {
      type: "change",
      additions: 0,
      deletions: 0,
      additionLineIndex,
      deletionLineIndex
    };
  return {
    type: "context",
    lines: 0,
    additionLineIndex,
    deletionLineIndex
  };
}

// node_modules/@pierre/patches/dist/core.js
var enc = new TextEncoder;
var dec = new TextDecoder("utf-8", { ignoreBOM: true });
var lineKeys = ["ignoreWhitespace", "stripTrailingCr"];
var patchKeys = [
  ...lineKeys,
  "context",
  "headerOptions"
];
var load;
var wasm;
var memory;
var diffCall;
var u8;
var dv;
var maxBytes = 32 << 20;
var wtf8;
function init(loadModule) {
  load = loadModule;
  wasm = undefined;
}
function start() {
  const compiled = wasm ?? load();
  const { exports } = new WebAssembly.Instance(compiled, {});
  wasm = compiled;
  memory = exports.memory;
  diffCall = exports.diff;
  bind();
  try {
    crypto.getRandomValues(u8.subarray(1016, 1024));
    u8[1016] |= 1;
  } catch {}
}
function diffChars(oldStr, newStr, options) {
  check(options, "diffChars");
  return run(1, oldStr, newStr);
}
function diffWordsWithSpace(oldStr, newStr, options) {
  check(options, "diffWordsWithSpace");
  return run(2, oldStr, newStr);
}
function createTwoFilesPatch(oldFileName, newFileName, oldStr, newStr, oldHeader, newHeader, options) {
  if (options?.newlineIsToken ?? false)
    throw new Error("newlineIsToken may not be used with patch-generation functions, only with diffing functions");
  check(options, "createTwoFilesPatch", patchKeys);
  const h = options?.headerOptions;
  const c = options?.context;
  const context = c === undefined ? 4 : c === null || c === false ? 0 : c;
  if (!(Number.isInteger(context) && context >= 0) && context !== Infinity)
    throw new Error("options.context must be a non-negative integer");
  return run(3, oldStr, newStr, options, Math.min(context, 268435455), (Boolean(h) === false ? 7 : (h.includeIndex ?? false ? 1 : 0) | (h.includeUnderline ?? false ? 2 : 0) | (h.includeFileHeaders ?? false ? 4 : 0)) | (oldFileName !== undefined ? 8 : 0) | (newFileName !== undefined ? 16 : 0), [
    oldFileName === undefined ? "" : String(oldFileName),
    newFileName === undefined ? "" : String(newFileName),
    oldHeader ? String(oldHeader) : "",
    newHeader ? String(newHeader) : ""
  ]);
}
function check(options, api, allowed) {
  if (typeof options === "function")
    throw new Error("callbacks are not supported by @pierre/patches");
  if (options == null)
    return;
  for (const [key, value] of Object.entries(options))
    if (value != null && value !== false && !(allowed?.includes(key) ?? false))
      throw new Error(`options.${key} is not supported by @pierre/patches ${api}`);
}
function run(op, oldStr, newStr, options, context = 0, headerFlags = 0, headers) {
  if (typeof oldStr !== "string" || typeof newStr !== "string")
    throw new TypeError("expected the texts to diff to be strings");
  if (options?.stripTrailingCr ?? false) {
    oldStr = oldStr.replaceAll(`\r
`, `
`);
    newStr = newStr.replaceAll(`\r
`, `
`);
  }
  if (oldStr.length >= 268435456 || newStr.length >= 268435456)
    throw new Error("out of memory");
  if (wasm === undefined)
    start();
  let need = 65600 + (oldStr.length + newStr.length) * 3;
  if (headers !== undefined)
    for (const s of headers)
      need += s.length * 3;
  if (need > u8.length) {
    try {
      memory.grow(Math.ceil((need - u8.length) / 65536));
    } catch {
      throw new Error("out of memory");
    }
    bind();
  }
  wtf8 = false;
  const oldLen = encode(oldStr, 65536);
  const newLen = encode(newStr, 65536 + oldLen);
  if (headers !== undefined) {
    let p = 65536 + oldLen + newLen;
    for (let i = 0;i < 4; i++) {
      const n = encode(headers[i], p);
      dv.setUint32(28 + i * 4, n, true);
      p += n;
    }
  }
  dv.setUint32(0, op | headerFlags << 16 | (oldLen === oldStr.length ? 1 << 24 : 0) | (newLen === newStr.length ? 2 << 24 : 0) | (options?.ignoreWhitespace ?? false ? 4 << 24 : 0), true);
  dv.setUint32(4, oldLen, true);
  dv.setUint32(8, newLen, true);
  dv.setUint32(24, context, true);
  diffCall();
  if (u8.length === 0)
    bind();
  let ptr = dv.getUint32(16, true);
  if (u8[1] === 0) {
    const message = dec.decode(u8.subarray(ptr, ptr + dv.getUint32(12, true)));
    release();
    throw new Error(message);
  }
  let result;
  if (op === 3) {
    const bytes = u8.subarray(ptr, ptr + dv.getUint32(20, true));
    result = "";
    let from = 0;
    if (wtf8)
      for (let i = bytes.indexOf(237);i !== -1; i = bytes.indexOf(237, i + 1)) {
        if (bytes[i + 1] < 160)
          continue;
        result += dec.decode(bytes.subarray(from, i)) + String.fromCharCode(53248 | (bytes[i + 1] & 63) << 6 | bytes[i + 2] & 63);
        from = i + 3;
      }
    result += dec.decode(bytes.subarray(from));
  } else {
    const count = dv.getUint32(12, true);
    result = new Array(count);
    for (let i = 0;i < count; i++, ptr += 16) {
      const removed = u8[ptr] === 1;
      result[i] = {
        count: dv.getUint32(ptr + 4, true),
        added: u8[ptr] === 2,
        removed,
        value: (removed ? oldStr : newStr).slice(dv.getUint32(ptr + 8, true), dv.getUint32(ptr + 12, true))
      };
    }
  }
  release();
  return result;
}
function encode(s, p) {
  if (s.length < 256)
    return encodeJS(s, p);
  const written = enc.encodeInto(s, u8.subarray(p)).written;
  return written === s.length || (s.isWellFormed?.() ?? false) ? written : encodeJS(s, p);
}
function encodeJS(s, p) {
  let q = p;
  for (let i = 0;i < s.length; i++) {
    const c = s.codePointAt(i);
    if (c < 128) {
      u8[q++] = c;
      continue;
    }
    if (c < 2048)
      u8[q++] = 192 | c >> 6;
    else {
      if (c < 65536) {
        u8[q++] = 224 | c >> 12;
        if ((c & 63488) === 55296)
          wtf8 = true;
      } else {
        u8[q++] = 240 | c >> 18;
        u8[q++] = 128 | c >> 12 & 63;
        i++;
      }
      u8[q++] = 128 | c >> 6 & 63;
    }
    u8[q++] = 128 | c & 63;
  }
  return q - p;
}
function bind() {
  u8 = new Uint8Array(memory.buffer);
  dv = new DataView(memory.buffer);
}
function release() {
  if (u8.length > maxBytes)
    try {
      start();
    } catch {}
}

// node_modules/@pierre/patches/dist/patch.wasm.mjs
var patch_wasm_default = "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";

// node_modules/@pierre/patches/dist/index.js
init(() => {
  const s = atob(patch_wasm_default);
  const bytes = new Uint8Array(s.length);
  for (let i = 0;i < s.length; i++)
    bytes[i] = s.charCodeAt(i);
  return new WebAssembly.Module(bytes);
});
// node_modules/diff/libesm/diff/base.js
class Diff {
  diff(oldStr, newStr, options = {}) {
    let callback;
    if (typeof options === "function") {
      callback = options;
      options = {};
    } else if ("callback" in options) {
      callback = options.callback;
    }
    const oldString = this.castInput(oldStr, options);
    const newString = this.castInput(newStr, options);
    const oldTokens = this.removeEmpty(this.tokenize(oldString, options));
    const newTokens = this.removeEmpty(this.tokenize(newString, options));
    return this.diffWithOptionsObj(oldTokens, newTokens, options, callback);
  }
  diffWithOptionsObj(oldTokens, newTokens, options, callback) {
    var _a;
    const done = (value) => {
      value = this.postProcess(value, options);
      if (callback) {
        setTimeout(function() {
          callback(value);
        }, 0);
        return;
      } else {
        return value;
      }
    };
    const newLen = newTokens.length, oldLen = oldTokens.length;
    let editLength = 1;
    let maxEditLength = newLen + oldLen;
    if (options.maxEditLength != null) {
      maxEditLength = Math.min(maxEditLength, options.maxEditLength);
    }
    const maxExecutionTime = (_a = options.timeout) !== null && _a !== undefined ? _a : Infinity;
    const abortAfterTimestamp = Date.now() + maxExecutionTime;
    const bestPath = [{ oldPos: -1, lastComponent: undefined }];
    let newPos = this.extractCommon(bestPath[0], newTokens, oldTokens, 0, options);
    if (bestPath[0].oldPos + 1 >= oldLen && newPos + 1 >= newLen) {
      return done(this.buildValues(bestPath[0].lastComponent, newTokens, oldTokens));
    }
    let minDiagonalToConsider = -Infinity, maxDiagonalToConsider = Infinity;
    const execEditLength = () => {
      for (let diagonalPath = Math.max(minDiagonalToConsider, -editLength);diagonalPath <= Math.min(maxDiagonalToConsider, editLength); diagonalPath += 2) {
        let basePath;
        const removePath = bestPath[diagonalPath - 1], addPath = bestPath[diagonalPath + 1];
        if (removePath) {
          bestPath[diagonalPath - 1] = undefined;
        }
        let canAdd = false;
        if (addPath) {
          const addPathNewPos = addPath.oldPos - diagonalPath;
          canAdd = addPath && 0 <= addPathNewPos && addPathNewPos < newLen;
        }
        const canRemove = removePath && removePath.oldPos + 1 < oldLen;
        if (!canAdd && !canRemove) {
          bestPath[diagonalPath] = undefined;
          continue;
        }
        if (!canRemove || canAdd && removePath.oldPos < addPath.oldPos) {
          basePath = this.addToPath(addPath, true, false, 0, options);
        } else {
          basePath = this.addToPath(removePath, false, true, 1, options);
        }
        newPos = this.extractCommon(basePath, newTokens, oldTokens, diagonalPath, options);
        if (basePath.oldPos + 1 >= oldLen && newPos + 1 >= newLen) {
          return done(this.buildValues(basePath.lastComponent, newTokens, oldTokens)) || true;
        } else {
          bestPath[diagonalPath] = basePath;
          if (basePath.oldPos + 1 >= oldLen) {
            maxDiagonalToConsider = Math.min(maxDiagonalToConsider, diagonalPath - 1);
          }
          if (newPos + 1 >= newLen) {
            minDiagonalToConsider = Math.max(minDiagonalToConsider, diagonalPath + 1);
          }
        }
      }
      editLength++;
    };
    if (callback) {
      (function exec() {
        setTimeout(function() {
          if (editLength > maxEditLength || Date.now() > abortAfterTimestamp) {
            return callback(undefined);
          }
          if (!execEditLength()) {
            exec();
          }
        }, 0);
      })();
    } else {
      while (editLength <= maxEditLength && Date.now() <= abortAfterTimestamp) {
        const ret = execEditLength();
        if (ret) {
          return ret;
        }
      }
    }
  }
  addToPath(path, added, removed, oldPosInc, options) {
    const last = path.lastComponent;
    if (last && !options.oneChangePerToken && last.added === added && last.removed === removed) {
      return {
        oldPos: path.oldPos + oldPosInc,
        lastComponent: { count: last.count + 1, added, removed, previousComponent: last.previousComponent }
      };
    } else {
      return {
        oldPos: path.oldPos + oldPosInc,
        lastComponent: { count: 1, added, removed, previousComponent: last }
      };
    }
  }
  extractCommon(basePath, newTokens, oldTokens, diagonalPath, options) {
    const newLen = newTokens.length, oldLen = oldTokens.length;
    let oldPos = basePath.oldPos, newPos = oldPos - diagonalPath, commonCount = 0;
    while (newPos + 1 < newLen && oldPos + 1 < oldLen && this.equals(oldTokens[oldPos + 1], newTokens[newPos + 1], options)) {
      newPos++;
      oldPos++;
      commonCount++;
      if (options.oneChangePerToken) {
        basePath.lastComponent = { count: 1, previousComponent: basePath.lastComponent, added: false, removed: false };
      }
    }
    if (commonCount && !options.oneChangePerToken) {
      basePath.lastComponent = { count: commonCount, previousComponent: basePath.lastComponent, added: false, removed: false };
    }
    basePath.oldPos = oldPos;
    return newPos;
  }
  equals(left, right, options) {
    if (options.comparator) {
      return options.comparator(left, right);
    } else {
      return left === right || !!options.ignoreCase && left.toLowerCase() === right.toLowerCase();
    }
  }
  removeEmpty(array) {
    const ret = [];
    for (let i = 0;i < array.length; i++) {
      if (array[i]) {
        ret.push(array[i]);
      }
    }
    return ret;
  }
  castInput(value, options) {
    return value;
  }
  tokenize(value, options) {
    return Array.from(value);
  }
  join(chars) {
    return chars.join("");
  }
  postProcess(changeObjects, options) {
    return changeObjects;
  }
  get useLongestToken() {
    return false;
  }
  buildValues(lastComponent, newTokens, oldTokens) {
    const components = [];
    let nextComponent;
    while (lastComponent) {
      components.push(lastComponent);
      nextComponent = lastComponent.previousComponent;
      delete lastComponent.previousComponent;
      lastComponent = nextComponent;
    }
    components.reverse();
    const componentLen = components.length;
    let componentPos = 0, newPos = 0, oldPos = 0;
    for (;componentPos < componentLen; componentPos++) {
      const component = components[componentPos];
      if (!component.removed) {
        if (!component.added && this.useLongestToken) {
          let value = newTokens.slice(newPos, newPos + component.count);
          value = value.map(function(value, i) {
            const oldValue = oldTokens[oldPos + i];
            return oldValue.length > value.length ? oldValue : value;
          });
          component.value = this.join(value);
        } else {
          component.value = this.join(newTokens.slice(newPos, newPos + component.count));
        }
        newPos += component.count;
        if (!component.added) {
          oldPos += component.count;
        }
      } else {
        component.value = this.join(oldTokens.slice(oldPos, oldPos + component.count));
        oldPos += component.count;
      }
    }
    return components;
  }
}

// node_modules/diff/libesm/diff/character.js
class CharacterDiff extends Diff {
}
var characterDiff = new CharacterDiff;
function diffChars2(oldStr, newStr, options) {
  return characterDiff.diff(oldStr, newStr, options);
}

// node_modules/diff/libesm/util/string.js
function longestCommonPrefix(str1, str2) {
  let i;
  for (i = 0;i < str1.length && i < str2.length; i++) {
    if (str1[i] != str2[i]) {
      return str1.slice(0, i);
    }
  }
  return str1.slice(0, i);
}
function longestCommonSuffix(str1, str2) {
  let i;
  if (!str1 || !str2 || str1[str1.length - 1] != str2[str2.length - 1]) {
    return "";
  }
  for (i = 0;i < str1.length && i < str2.length; i++) {
    if (str1[str1.length - (i + 1)] != str2[str2.length - (i + 1)]) {
      return str1.slice(-i);
    }
  }
  return str1.slice(-i);
}
function replacePrefix(string, oldPrefix, newPrefix) {
  if (string.slice(0, oldPrefix.length) != oldPrefix) {
    throw Error(`string ${JSON.stringify(string)} doesn't start with prefix ${JSON.stringify(oldPrefix)}; this is a bug`);
  }
  return newPrefix + string.slice(oldPrefix.length);
}
function replaceSuffix(string, oldSuffix, newSuffix) {
  if (!oldSuffix) {
    return string + newSuffix;
  }
  if (string.slice(-oldSuffix.length) != oldSuffix) {
    throw Error(`string ${JSON.stringify(string)} doesn't end with suffix ${JSON.stringify(oldSuffix)}; this is a bug`);
  }
  return string.slice(0, -oldSuffix.length) + newSuffix;
}
function removePrefix(string, oldPrefix) {
  return replacePrefix(string, oldPrefix, "");
}
function removeSuffix(string, oldSuffix) {
  return replaceSuffix(string, oldSuffix, "");
}
function maximumOverlap(string1, string2) {
  return string2.slice(0, overlapCount(string1, string2));
}
function overlapCount(a, b) {
  let startA = 0;
  if (a.length > b.length) {
    startA = a.length - b.length;
  }
  let endB = b.length;
  if (a.length < b.length) {
    endB = a.length;
  }
  const map = Array(endB);
  let k = 0;
  map[0] = 0;
  for (let j = 1;j < endB; j++) {
    if (b[j] == b[k]) {
      map[j] = map[k];
    } else {
      map[j] = k;
    }
    while (k > 0 && b[j] != b[k]) {
      k = map[k];
    }
    if (b[j] == b[k]) {
      k++;
    }
  }
  k = 0;
  for (let i = startA;i < a.length; i++) {
    while (k > 0 && a[i] != b[k]) {
      k = map[k];
    }
    if (a[i] == b[k]) {
      k++;
    }
  }
  return k;
}
function segment(string, segmenter) {
  const parts = [];
  for (const segmentObj of Array.from(segmenter.segment(string))) {
    const segment = segmentObj.segment;
    if (parts.length && /\s/.test(parts[parts.length - 1]) && /\s/.test(segment)) {
      parts[parts.length - 1] += segment;
    } else {
      parts.push(segment);
    }
  }
  return parts;
}
function trailingWs(string, segmenter) {
  if (segmenter) {
    return leadingAndTrailingWs(string, segmenter)[1];
  }
  let i;
  for (i = string.length - 1;i >= 0; i--) {
    if (!string[i].match(/\s/)) {
      break;
    }
  }
  return string.substring(i + 1);
}
function leadingWs(string, segmenter) {
  if (segmenter) {
    return leadingAndTrailingWs(string, segmenter)[0];
  }
  const match = string.match(/^\s*/);
  return match ? match[0] : "";
}
function leadingAndTrailingWs(string, segmenter) {
  if (!segmenter) {
    return [leadingWs(string), trailingWs(string)];
  }
  if (segmenter.resolvedOptions().granularity != "word") {
    throw new Error('The segmenter passed must have a granularity of "word"');
  }
  const segments = segment(string, segmenter);
  const firstSeg = segments[0];
  const lastSeg = segments[segments.length - 1];
  const head = /\s/.test(firstSeg) ? firstSeg : "";
  const tail = /\s/.test(lastSeg) ? lastSeg : "";
  return [head, tail];
}

// node_modules/diff/libesm/diff/word.js
var extendedWordChars = "a-zA-Z0-9_\\u{AD}\\u{C0}-\\u{D6}\\u{D8}-\\u{F6}\\u{F8}-\\u{2C6}\\u{2C8}-\\u{2D7}\\u{2DE}-\\u{2FF}\\u{1E00}-\\u{1EFF}";
var tokenizeIncludingWhitespace = new RegExp(`[${extendedWordChars}]+|\\s+|[^${extendedWordChars}]`, "ug");

class WordDiff extends Diff {
  equals(left, right, options) {
    if (options.ignoreCase) {
      left = left.toLowerCase();
      right = right.toLowerCase();
    }
    return left.trim() === right.trim();
  }
  tokenize(value, options = {}) {
    let parts;
    if (options.intlSegmenter) {
      const segmenter = options.intlSegmenter;
      if (segmenter.resolvedOptions().granularity != "word") {
        throw new Error('The segmenter passed must have a granularity of "word"');
      }
      parts = segment(value, segmenter);
    } else {
      parts = value.match(tokenizeIncludingWhitespace) || [];
    }
    const tokens = [];
    let prevPart = null;
    parts.forEach((part) => {
      if (/\s/.test(part)) {
        if (prevPart == null) {
          tokens.push(part);
        } else {
          tokens.push(tokens.pop() + part);
        }
      } else if (prevPart != null && /\s/.test(prevPart)) {
        if (tokens[tokens.length - 1] == prevPart) {
          tokens.push(tokens.pop() + part);
        } else {
          tokens.push(prevPart + part);
        }
      } else {
        tokens.push(part);
      }
      prevPart = part;
    });
    return tokens;
  }
  join(tokens) {
    return tokens.map((token, i) => {
      if (i == 0) {
        return token;
      } else {
        return token.replace(/^\s+/, "");
      }
    }).join("");
  }
  postProcess(changes, options) {
    if (!changes || options.oneChangePerToken) {
      return changes;
    }
    let lastKeep = null;
    let insertion = null;
    let deletion = null;
    changes.forEach((change) => {
      if (change.added) {
        insertion = change;
      } else if (change.removed) {
        deletion = change;
      } else {
        if (insertion || deletion) {
          dedupeWhitespaceInChangeObjects(lastKeep, deletion, insertion, change, options.intlSegmenter);
        }
        lastKeep = change;
        insertion = null;
        deletion = null;
      }
    });
    if (insertion || deletion) {
      dedupeWhitespaceInChangeObjects(lastKeep, deletion, insertion, null, options.intlSegmenter);
    }
    return changes;
  }
}
var wordDiff = new WordDiff;
function dedupeWhitespaceInChangeObjects(startKeep, deletion, insertion, endKeep, segmenter) {
  if (deletion && insertion) {
    const [oldWsPrefix, oldWsSuffix] = leadingAndTrailingWs(deletion.value, segmenter);
    const [newWsPrefix, newWsSuffix] = leadingAndTrailingWs(insertion.value, segmenter);
    if (startKeep) {
      const commonWsPrefix = longestCommonPrefix(oldWsPrefix, newWsPrefix);
      startKeep.value = replaceSuffix(startKeep.value, newWsPrefix, commonWsPrefix);
      deletion.value = removePrefix(deletion.value, commonWsPrefix);
      insertion.value = removePrefix(insertion.value, commonWsPrefix);
    }
    if (endKeep) {
      const commonWsSuffix = longestCommonSuffix(oldWsSuffix, newWsSuffix);
      endKeep.value = replacePrefix(endKeep.value, newWsSuffix, commonWsSuffix);
      deletion.value = removeSuffix(deletion.value, commonWsSuffix);
      insertion.value = removeSuffix(insertion.value, commonWsSuffix);
    }
  } else if (insertion) {
    if (startKeep) {
      const ws = leadingWs(insertion.value, segmenter);
      insertion.value = insertion.value.substring(ws.length);
    }
    if (endKeep) {
      const ws = leadingWs(endKeep.value, segmenter);
      endKeep.value = endKeep.value.substring(ws.length);
    }
  } else if (startKeep && endKeep) {
    const newWsFull = leadingWs(endKeep.value, segmenter), [delWsStart, delWsEnd] = leadingAndTrailingWs(deletion.value, segmenter);
    const newWsStart = longestCommonPrefix(newWsFull, delWsStart);
    deletion.value = removePrefix(deletion.value, newWsStart);
    const newWsEnd = longestCommonSuffix(removePrefix(newWsFull, newWsStart), delWsEnd);
    deletion.value = removeSuffix(deletion.value, newWsEnd);
    endKeep.value = replacePrefix(endKeep.value, newWsFull, newWsEnd);
    startKeep.value = replaceSuffix(startKeep.value, newWsFull, newWsFull.slice(0, newWsFull.length - newWsEnd.length));
  } else if (endKeep) {
    const endKeepWsPrefix = leadingWs(endKeep.value, segmenter);
    const deletionWsSuffix = trailingWs(deletion.value, segmenter);
    const overlap = maximumOverlap(deletionWsSuffix, endKeepWsPrefix);
    deletion.value = removeSuffix(deletion.value, overlap);
  } else if (startKeep) {
    const startKeepWsSuffix = trailingWs(startKeep.value, segmenter);
    const deletionWsPrefix = leadingWs(deletion.value, segmenter);
    const overlap = maximumOverlap(startKeepWsSuffix, deletionWsPrefix);
    deletion.value = removePrefix(deletion.value, overlap);
  }
}

class WordsWithSpaceDiff extends Diff {
  tokenize(value) {
    const regex = new RegExp(`(\\r?\\n)|[${extendedWordChars}]+|[^\\S\\n\\r]+|[^${extendedWordChars}]`, "ug");
    return value.match(regex) || [];
  }
}
var wordsWithSpaceDiff = new WordsWithSpaceDiff;
function diffWordsWithSpace2(oldStr, newStr, options) {
  return wordsWithSpaceDiff.diff(oldStr, newStr, options);
}
// node_modules/diff/libesm/diff/line.js
class LineDiff extends Diff {
  constructor() {
    super(...arguments);
    this.tokenize = tokenize;
  }
  equals(left, right, options) {
    if (options.ignoreWhitespace) {
      if (!options.newlineIsToken || !left.includes(`
`)) {
        left = left.trim();
      }
      if (!options.newlineIsToken || !right.includes(`
`)) {
        right = right.trim();
      }
    } else if (options.ignoreNewlineAtEof && !options.newlineIsToken) {
      if (left.endsWith(`
`)) {
        left = left.slice(0, -1);
      }
      if (right.endsWith(`
`)) {
        right = right.slice(0, -1);
      }
    }
    return super.equals(left, right, options);
  }
}
var lineDiff = new LineDiff;
function diffLines2(oldStr, newStr, options) {
  return lineDiff.diff(oldStr, newStr, options);
}
function tokenize(value, options) {
  if (options.stripTrailingCr) {
    value = value.replace(/\r\n/g, `
`);
  }
  const retLines = [], linesAndNewlines = value.split(/(\n|\r\n)/);
  if (!linesAndNewlines[linesAndNewlines.length - 1]) {
    linesAndNewlines.pop();
  }
  for (let i = 0;i < linesAndNewlines.length; i++) {
    const line = linesAndNewlines[i];
    if (i % 2 && !options.newlineIsToken) {
      retLines[retLines.length - 1] += line;
    } else {
      retLines.push(line);
    }
  }
  return retLines;
}

// node_modules/diff/libesm/patch/create.js
function needsQuoting(s) {
  for (let i = 0;i < s.length; i++) {
    if (s[i] < " " || s[i] > "~" || s[i] === '"' || s[i] === "\\") {
      return true;
    }
  }
  return false;
}
function quoteFileNameIfNeeded(s) {
  if (!needsQuoting(s)) {
    return s;
  }
  let result = '"';
  const bytes = new TextEncoder().encode(s);
  let i = 0;
  while (i < bytes.length) {
    const b = bytes[i];
    if (b === 7) {
      result += "\\a";
    } else if (b === 8) {
      result += "\\b";
    } else if (b === 9) {
      result += "\\t";
    } else if (b === 10) {
      result += "\\n";
    } else if (b === 11) {
      result += "\\v";
    } else if (b === 12) {
      result += "\\f";
    } else if (b === 13) {
      result += "\\r";
    } else if (b === 34) {
      result += "\\\"";
    } else if (b === 92) {
      result += "\\\\";
    } else if (b >= 32 && b <= 126) {
      result += String.fromCharCode(b);
    } else {
      result += "\\" + b.toString(8).padStart(3, "0");
    }
    i++;
  }
  result += '"';
  return result;
}
var INCLUDE_HEADERS = {
  includeIndex: true,
  includeUnderline: true,
  includeFileHeaders: true
};
function structuredPatch(oldFileName, newFileName, oldStr, newStr, oldHeader, newHeader, options) {
  let optionsObj;
  if (!options) {
    optionsObj = {};
  } else if (typeof options === "function") {
    optionsObj = { callback: options };
  } else {
    optionsObj = options;
  }
  if (typeof optionsObj.context === "undefined") {
    optionsObj.context = 4;
  }
  const context = optionsObj.context;
  if (optionsObj.newlineIsToken) {
    throw new Error("newlineIsToken may not be used with patch-generation functions, only with diffing functions");
  }
  if (!optionsObj.callback) {
    return diffLinesResultToPatch(diffLines2(oldStr, newStr, optionsObj));
  } else {
    const { callback } = optionsObj;
    diffLines2(oldStr, newStr, Object.assign(Object.assign({}, optionsObj), { callback: (diff) => {
      const patch = diffLinesResultToPatch(diff);
      callback(patch);
    } }));
  }
  function diffLinesResultToPatch(diff) {
    if (!diff) {
      return;
    }
    diff.push({ value: "", lines: [] });
    function contextLines(lines) {
      return lines.map(function(entry) {
        return " " + entry;
      });
    }
    const hunks = [];
    let oldRangeStart = 0, newRangeStart = 0, curRange = [], oldLine = 1, newLine = 1;
    for (let i = 0;i < diff.length; i++) {
      const current = diff[i], lines = current.lines || splitLines(current.value);
      current.lines = lines;
      if (current.added || current.removed) {
        if (!oldRangeStart) {
          const prev = diff[i - 1];
          oldRangeStart = oldLine;
          newRangeStart = newLine;
          if (prev) {
            curRange = context > 0 ? contextLines(prev.lines.slice(-context)) : [];
            oldRangeStart -= curRange.length;
            newRangeStart -= curRange.length;
          }
        }
        for (const line of lines) {
          curRange.push((current.added ? "+" : "-") + line);
        }
        if (current.added) {
          newLine += lines.length;
        } else {
          oldLine += lines.length;
        }
      } else {
        if (oldRangeStart) {
          if (lines.length <= context * 2 && i < diff.length - 2) {
            for (const line of contextLines(lines)) {
              curRange.push(line);
            }
          } else {
            const contextSize = Math.min(lines.length, context);
            for (const line of contextLines(lines.slice(0, contextSize))) {
              curRange.push(line);
            }
            const hunk = {
              oldStart: oldRangeStart,
              oldLines: oldLine - oldRangeStart + contextSize,
              newStart: newRangeStart,
              newLines: newLine - newRangeStart + contextSize,
              lines: curRange
            };
            hunks.push(hunk);
            oldRangeStart = 0;
            newRangeStart = 0;
            curRange = [];
          }
        }
        oldLine += lines.length;
        newLine += lines.length;
      }
    }
    for (const hunk of hunks) {
      for (let i = 0;i < hunk.lines.length; i++) {
        if (hunk.lines[i].endsWith(`
`)) {
          hunk.lines[i] = hunk.lines[i].slice(0, -1);
        } else {
          hunk.lines.splice(i + 1, 0, "\\ No newline at end of file");
          i++;
        }
      }
    }
    return {
      oldFileName,
      newFileName,
      oldHeader,
      newHeader,
      hunks
    };
  }
}
function formatPatch(patch, headerOptions) {
  var _a, _b, _c, _d, _e, _f;
  if (!headerOptions) {
    headerOptions = INCLUDE_HEADERS;
  }
  if (Array.isArray(patch)) {
    if (patch.length > 1 && !headerOptions.includeFileHeaders && !patch.every((p) => p.isGit)) {
      throw new Error("Cannot omit file headers on a multi-file patch. " + "(The result would be unparseable; how would a tool trying to apply " + "the patch know which changes are to which file?)");
    }
    return patch.map((p) => formatPatch(p, headerOptions)).join(`
`);
  }
  const ret = [];
  if (patch.isGit) {
    headerOptions = INCLUDE_HEADERS;
    if (!patch.oldFileName) {
      throw new Error("oldFileName must be specified for Git patches");
    }
    if (!patch.newFileName) {
      throw new Error("newFileName must be specified for Git patches");
    }
    let gitOldName = patch.oldFileName;
    let gitNewName = patch.newFileName;
    if (patch.isCreate && gitOldName === "/dev/null") {
      gitOldName = gitNewName.replace(/^b\//, "a/");
    } else if (patch.isDelete && gitNewName === "/dev/null") {
      gitNewName = gitOldName.replace(/^a\//, "b/");
    }
    ret.push("diff --git " + quoteFileNameIfNeeded(gitOldName) + " " + quoteFileNameIfNeeded(gitNewName));
    if (patch.isDelete) {
      ret.push("deleted file mode " + ((_a = patch.oldMode) !== null && _a !== undefined ? _a : "100644"));
    }
    if (patch.isCreate) {
      ret.push("new file mode " + ((_b = patch.newMode) !== null && _b !== undefined ? _b : "100644"));
    }
    if (patch.oldMode && patch.newMode && !patch.isDelete && !patch.isCreate) {
      ret.push("old mode " + patch.oldMode);
      ret.push("new mode " + patch.newMode);
    }
    if (patch.isRename) {
      ret.push("rename from " + quoteFileNameIfNeeded(((_c = patch.oldFileName) !== null && _c !== undefined ? _c : "").replace(/^a\//, "")));
      ret.push("rename to " + quoteFileNameIfNeeded(((_d = patch.newFileName) !== null && _d !== undefined ? _d : "").replace(/^b\//, "")));
    }
    if (patch.isCopy) {
      ret.push("copy from " + quoteFileNameIfNeeded(((_e = patch.oldFileName) !== null && _e !== undefined ? _e : "").replace(/^a\//, "")));
      ret.push("copy to " + quoteFileNameIfNeeded(((_f = patch.newFileName) !== null && _f !== undefined ? _f : "").replace(/^b\//, "")));
    }
  } else {
    if (headerOptions.includeIndex && patch.oldFileName == patch.newFileName && patch.oldFileName !== undefined) {
      ret.push("Index: " + patch.oldFileName);
    }
    if (headerOptions.includeUnderline) {
      ret.push("===================================================================");
    }
  }
  const hasHunks = patch.hunks.length > 0;
  if (headerOptions.includeFileHeaders && patch.oldFileName !== undefined && patch.newFileName !== undefined && (!patch.isGit || hasHunks)) {
    ret.push("--- " + quoteFileNameIfNeeded(patch.oldFileName) + (patch.oldHeader ? "\t" + patch.oldHeader : ""));
    ret.push("+++ " + quoteFileNameIfNeeded(patch.newFileName) + (patch.newHeader ? "\t" + patch.newHeader : ""));
  }
  for (let i = 0;i < patch.hunks.length; i++) {
    const hunk = patch.hunks[i];
    const oldStart = hunk.oldLines === 0 ? hunk.oldStart - 1 : hunk.oldStart;
    const newStart = hunk.newLines === 0 ? hunk.newStart - 1 : hunk.newStart;
    ret.push("@@ -" + oldStart + "," + hunk.oldLines + " +" + newStart + "," + hunk.newLines + " @@");
    for (const line of hunk.lines) {
      ret.push(line);
    }
  }
  return ret.join(`
`) + `
`;
}
function createTwoFilesPatch2(oldFileName, newFileName, oldStr, newStr, oldHeader, newHeader, options) {
  if (typeof options === "function") {
    options = { callback: options };
  }
  if (!(options === null || options === undefined ? undefined : options.callback)) {
    const patchObj = structuredPatch(oldFileName, newFileName, oldStr, newStr, oldHeader, newHeader, options);
    if (!patchObj) {
      return;
    }
    return formatPatch(patchObj, options === null || options === undefined ? undefined : options.headerOptions);
  } else {
    const { callback } = options;
    structuredPatch(oldFileName, newFileName, oldStr, newStr, oldHeader, newHeader, Object.assign(Object.assign({}, options), { callback: (patchObj) => {
      if (!patchObj) {
        callback(undefined);
      } else {
        callback(formatPatch(patchObj, options.headerOptions));
      }
    } }));
  }
}
function splitLines(text) {
  const hasTrailingNl = text.endsWith(`
`);
  const result = text.split(`
`).map((line) => line + `
`);
  if (hasTrailingNl) {
    result.pop();
  } else {
    result.push(result.pop().slice(0, -1));
  }
  return result;
}
// node_modules/@pierre/diffs/dist/utils/diffLibs.js
var diffLibs = {
  jsdiff: {
    createTwoFilesPatch: createTwoFilesPatch2,
    diffChars: diffChars2,
    diffWordsWithSpace: diffWordsWithSpace2
  },
  "@pierre/patches": {
    createTwoFilesPatch,
    diffChars,
    diffWordsWithSpace
  }
};
var patchesWork;
function resolveDiffLib(preferred) {
  if (preferred === "jsdiff")
    return preferred;
  if (patchesWork === undefined)
    try {
      diffChars("", "");
      patchesWork = true;
    } catch (error) {
      console.error(error);
      patchesWork = false;
    }
  return patchesWork ? preferred : "jsdiff";
}

// node_modules/@pierre/diffs/dist/utils/parseDiffFromFile.js
var MISSING_FILE_NAME = "/dev/null";
function parseDiffFromFile(oldFile, newFile, { preferredDiffLib = "jsdiff", disableLineMatching, ...diffOptions } = {}, throwOnError = false) {
  if (oldFile === null && newFile === null)
    throw new Error("parseDiffFromFile: You must pass oldFile, newFile, or both");
  const resolvedOldFile = oldFile ?? createMissingFile();
  const resolvedNewFile = newFile ?? createMissingFile();
  const patchArgs = [
    resolvedOldFile.name,
    resolvedNewFile.name,
    resolvedOldFile.contents,
    resolvedNewFile.contents,
    resolvedOldFile.header,
    resolvedNewFile.header,
    diffOptions
  ];
  const diffLib = throwOnError ? preferredDiffLib : resolveDiffLib(preferredDiffLib);
  let patch;
  try {
    patch = diffLibs[diffLib].createTwoFilesPatch(...patchArgs);
  } catch (error) {
    if (throwOnError || diffLib === "jsdiff")
      throw error;
    console.error(error);
    patch = diffLibs.jsdiff.createTwoFilesPatch(...patchArgs);
  }
  const fileData = processFile(patch, {
    cacheKey: (() => {
      const oldCacheKey = oldFile?.cacheKey;
      const newCacheKey = newFile?.cacheKey;
      return oldCacheKey != null && newCacheKey != null ? composeCacheKey(disableLineMatching === true ? "diff-raw" : "diff", oldCacheKey, newCacheKey) : undefined;
    })(),
    oldFile: resolvedOldFile,
    newFile: resolvedNewFile,
    disableLineMatching,
    throwOnError
  });
  if (fileData == null)
    throw new Error("parseDiffFrom: FileInvalid diff -- probably need to fix something -- if the files are the same maybe?");
  if (oldFile === null) {
    fileData.type = "new";
    fileData.prevName = undefined;
  } else if (newFile === null) {
    fileData.type = "deleted";
    fileData.prevName = undefined;
  }
  const language = newFile?.lang ?? (newFile === null ? oldFile?.lang : undefined);
  if (language != null)
    fileData.lang = language;
  return fileData;
}
function createMissingFile() {
  return {
    name: MISSING_FILE_NAME,
    contents: ""
  };
}

// src/linesDiff.ts
var DEFAULT_TIMEOUT_MS = 5000;
var MIN_MOVE_LINES = 3;
var MAX_WORD_DIFF_LENGTH = 200000;
var MAX_INNER_EMPHASIS_RATIO = 0.5;
function linesEqual(a, b, ignoreTrimWhitespace) {
  if (a.length !== b.length)
    return false;
  for (let i = 0;i < a.length; i += 1) {
    const left = ignoreTrimWhitespace ? a[i].trim() : a[i];
    const right = ignoreTrimWhitespace ? b[i].trim() : b[i];
    if (left !== right)
      return false;
  }
  return true;
}
function comparisonLines(lines, ignoreWhitespace) {
  if (!ignoreWhitespace)
    return lines;
  return lines.map((line) => line.replace(/\s/g, ""));
}
function advancePos(pos, text) {
  let lastNewline = -1;
  let newlines = 0;
  for (let i = 0;i < text.length; i += 1) {
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
function emptyRangeAt(pos) {
  return { start_line: pos.line, start_col: pos.col, end_line: pos.line, end_col: pos.col };
}
function rangeBetween(start, end) {
  return { start_line: start.line, start_col: start.col, end_line: end.line, end_col: end.col };
}
function wholeBlockMapping(origLines, modLines, origStartLine, modStartLine) {
  const origEnd = origLines.length;
  const modEnd = modLines.length;
  return {
    original: {
      start_line: origStartLine,
      start_col: 1,
      end_line: origStartLine + Math.max(origEnd - 1, 0),
      end_col: (origLines[origEnd - 1]?.length ?? 0) + 1
    },
    modified: {
      start_line: modStartLine,
      start_col: 1,
      end_line: modStartLine + Math.max(modEnd - 1, 0),
      end_col: (modLines[modEnd - 1]?.length ?? 0) + 1
    }
  };
}
function computeInnerChanges(origLines, modLines, origStartLine, modStartLine, state) {
  if (origLines.length === 0 || modLines.length === 0) {
    return [];
  }
  if (Date.now() >= state.deadline) {
    state.hitTimeout = true;
    return [wholeBlockMapping(origLines, modLines, origStartLine, modStartLine)];
  }
  const origText = origLines.join(`
`);
  const modText = modLines.join(`
`);
  const totalLength = origText.length + modText.length;
  if (totalLength > MAX_WORD_DIFF_LENGTH) {
    return [wholeBlockMapping(origLines, modLines, origStartLine, modStartLine)];
  }
  const parts = diffWordsWithSpace(origText, modText);
  let removedChars = 0;
  let addedChars = 0;
  for (const part of parts) {
    if (part.removed)
      removedChars += part.value.length;
    else if (part.added)
      addedChars += part.value.length;
  }
  if (removedChars > origText.length * MAX_INNER_EMPHASIS_RATIO || addedChars > modText.length * MAX_INNER_EMPHASIS_RATIO) {
    return [];
  }
  const inner = [];
  const origPos = { line: origStartLine, col: 1 };
  const modPos = { line: modStartLine, col: 1 };
  let i = 0;
  while (i < parts.length) {
    const part = parts[i];
    if (!part.added && !part.removed) {
      advancePos(origPos, part.value);
      advancePos(modPos, part.value);
      i += 1;
      continue;
    }
    let removedRange;
    if (part.removed) {
      const start = { ...origPos };
      advancePos(origPos, part.value);
      removedRange = rangeBetween(start, origPos);
      i += 1;
    } else {
      removedRange = emptyRangeAt(origPos);
    }
    let addedRange;
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
function computeMoves(changes, originalLines, modifiedLines) {
  const deletedSet = new Set;
  const addedSet = new Set;
  for (const change of changes) {
    for (let l = change.original.start_line;l < change.original.end_line; l += 1) {
      deletedSet.add(l);
    }
    for (let l = change.modified.start_line;l < change.modified.end_line; l += 1) {
      addedSet.add(l);
    }
  }
  if (deletedSet.size === 0 || addedSet.size === 0) {
    return [];
  }
  const indexLines = (lines) => {
    const index = new Map;
    for (let i = 0;i < lines.length; i += 1) {
      const existing = index.get(lines[i]);
      if (existing) {
        existing.push(i + 1);
      } else {
        index.set(lines[i], [i + 1]);
      }
    }
    return index;
  };
  const candidates = [];
  const collectRuns = (sourceLines, sourceChanged, targetLines, targetChanged, targetIndex, toCandidate) => {
    for (const s of sourceChanged) {
      if (sourceChanged.has(s - 1))
        continue;
      for (const t of targetIndex.get(sourceLines[s - 1] ?? "") ?? []) {
        if (!targetChanged.has(t))
          continue;
        let k = 0;
        let hasContent = false;
        while (sourceChanged.has(s + k) && t + k <= targetLines.length && sourceLines[s + k - 1] === targetLines[t + k - 1]) {
          if (sourceLines[s + k - 1].trim() !== "")
            hasContent = true;
          k += 1;
        }
        if (k >= MIN_MOVE_LINES && hasContent) {
          candidates.push(toCandidate(s, t, k));
        }
      }
    }
  };
  collectRuns(originalLines, deletedSet, modifiedLines, addedSet, indexLines(modifiedLines), (sourceStart, targetStart, length) => ({
    origStart: sourceStart,
    modStart: targetStart,
    length
  }));
  collectRuns(modifiedLines, addedSet, originalLines, deletedSet, indexLines(originalLines), (sourceStart, targetStart, length) => ({
    origStart: targetStart,
    modStart: sourceStart,
    length
  }));
  candidates.sort((a, b) => b.length - a.length);
  const usedOrig = new Set;
  const usedMod = new Set;
  const moves = [];
  for (const candidate of candidates) {
    let overlaps = false;
    for (let t = 0;t < candidate.length; t += 1) {
      if (usedOrig.has(candidate.origStart + t) || usedMod.has(candidate.modStart + t)) {
        overlaps = true;
        break;
      }
    }
    if (overlaps)
      continue;
    for (let t = 0;t < candidate.length; t += 1) {
      usedOrig.add(candidate.origStart + t);
      usedMod.add(candidate.modStart + t);
    }
    moves.push({
      original: {
        start_line: candidate.origStart,
        end_line: candidate.origStart + candidate.length
      },
      modified: { start_line: candidate.modStart, end_line: candidate.modStart + candidate.length }
    });
  }
  moves.sort((a, b) => a.original.start_line - b.original.start_line);
  return moves;
}
function toArray(lines) {
  if (Array.isArray(lines))
    return lines;
  return [];
}
function parseLineDiff(original, modified, ignoreWhitespace, timeoutMs) {
  const oldFile = { name: "original", contents: original };
  const newFile = { name: "modified", contents: modified };
  const options = {
    context: 0,
    ignoreWhitespace,
    disableLineMatching: true
  };
  try {
    return parseDiffFromFile(oldFile, newFile, { ...options, preferredDiffLib: "@pierre/patches" }, true);
  } catch {}
  try {
    return parseDiffFromFile(oldFile, newFile, { ...options, preferredDiffLib: "jsdiff", timeout: timeoutMs }, true);
  } catch {
    return;
  }
}
function computeLinesDiff(originalInput, modifiedInput, options = {}) {
  const originalLines = toArray(originalInput);
  const modifiedLines = toArray(modifiedInput);
  const ignoreWhitespace = options.ignore_whitespace ?? false;
  const ignoreTrimWhitespace = !ignoreWhitespace && (options.ignore_trim_whitespace ?? false);
  const timeoutMs = options.max_computation_time_ms || DEFAULT_TIMEOUT_MS;
  const state = { deadline: Date.now() + timeoutMs, hitTimeout: false };
  const comparedOriginal = comparisonLines(originalLines, ignoreWhitespace);
  const comparedModified = comparisonLines(modifiedLines, ignoreWhitespace);
  if (linesEqual(comparedOriginal, comparedModified, ignoreTrimWhitespace)) {
    return { changes: [], moves: [], hit_timeout: false };
  }
  const toContents = (lines) => lines.length > 0 ? `${lines.join(`
`)}
` : "";
  const metadata = parseLineDiff(toContents(comparedOriginal), toContents(comparedModified), ignoreTrimWhitespace, timeoutMs);
  if (!metadata) {
    return {
      changes: [
        {
          original: { start_line: 1, end_line: originalLines.length + 1 },
          modified: { start_line: 1, end_line: modifiedLines.length + 1 },
          inner_changes: []
        }
      ],
      moves: [],
      hit_timeout: true
    };
  }
  const changes = [];
  for (const hunk of metadata.hunks) {
    let oldLine = hunk.deletionCount === 0 ? hunk.deletionStart + 1 : hunk.deletionStart;
    let newLine = hunk.additionCount === 0 ? hunk.additionStart + 1 : hunk.additionStart;
    for (const content of hunk.hunkContent) {
      if (content.type === "context") {
        oldLine += content.lines;
        newLine += content.lines;
        continue;
      }
      const origBlock = originalLines.slice(oldLine - 1, oldLine + content.deletions - 1);
      const modBlock = modifiedLines.slice(newLine - 1, newLine + content.additions - 1);
      changes.push({
        original: { start_line: oldLine, end_line: oldLine + content.deletions },
        modified: { start_line: newLine, end_line: newLine + content.additions },
        inner_changes: computeInnerChanges(origBlock, modBlock, oldLine, newLine, state)
      });
      oldLine += content.deletions;
      newLine += content.additions;
    }
  }
  const moves = options.compute_moves ? computeMoves(changes, originalLines, modifiedLines) : [];
  return { changes, moves, hit_timeout: state.hitTimeout };
}

// src/main.ts
function engineVersion() {
  try {
    const versionFile = new URL("../../VERSION", import.meta.url);
    return readFileSync(versionFile, "utf8").trim();
  } catch {
    return "unknown";
  }
}
function respond(payload) {
  process.stdout.write(`${JSON.stringify(payload)}
`);
}
function handleLine(line) {
  const trimmed = line.trim();
  if (trimmed === "")
    return;
  let request;
  try {
    request = JSON.parse(trimmed);
  } catch (error) {
    respond({ id: null, error: `invalid JSON request: ${String(error)}` });
    return;
  }
  const id = request.id ?? null;
  try {
    switch (request.method) {
      case "computeDiff": {
        const params = request.params ?? {};
        const result = computeLinesDiff(params.original, params.modified, params.options ?? {});
        respond({ id, result });
        break;
      }
      case "version": {
        respond({ id, result: { version: engineVersion(), engine: "pierre" } });
        break;
      }
      case "shutdown": {
        respond({ id, result: true });
        process.exit(0);
      }
      default:
        respond({ id, error: `unknown method: ${String(request.method)}` });
    }
  } catch (error) {
    respond({ id, error: error instanceof Error ? error.message : String(error) });
  }
}
async function main() {
  const decoder = new TextDecoder;
  let buffered = "";
  for await (const chunk of Bun.stdin.stream()) {
    buffered += decoder.decode(chunk, { stream: true });
    let newlineIndex = buffered.indexOf(`
`);
    while (newlineIndex !== -1) {
      const line = buffered.slice(0, newlineIndex);
      buffered = buffered.slice(newlineIndex + 1);
      handleLine(line);
      newlineIndex = buffered.indexOf(`
`);
    }
  }
}
main().catch((error) => {
  process.stderr.write(`codediff engine crashed: ${String(error)}
`);
  process.exit(1);
});
