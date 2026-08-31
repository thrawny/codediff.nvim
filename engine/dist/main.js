// @bun
// src/main.ts
import { readFileSync } from "fs";
// node_modules/@pierre/diffs/dist/constants.js
var DIFFS_DEVELOPMENT_BUILD = (() => {
  try {
    return true;
  } catch {
    return false;
  }
})();
var GIT_DIFF_FILE_BREAK_REGEX = /(?=^diff --git)/gm;
var FILENAME_HEADER_REGEX = /^(---|\+\+\+)\s+([^\t\r\n]+)/;
var FILENAME_HEADER_REGEX_GIT = /^(---|\+\+\+)\s+[ab]\/([^\t\r\n]+)/;
var ALTERNATE_FILE_NAMES_GIT = /^diff --git (?:"a\/(.+?)"|a\/(.+?)) (?:"b\/(.+?)"|b\/(.+?))$/;
var INDEX_LINE_METADATA = /^index ([0-9a-f]+)\.\.([0-9a-f]+)(?: (\d+))?$/i;
var DEFAULT_VIRTUAL_FILE_METRICS = {
  hunkLineCount: 50,
  lineHeight: 20,
  diffHeaderHeight: 44,
  spacing: 8
};
var DEFAULT_CODE_VIEW_FILE_METRICS = {
  ...DEFAULT_VIRTUAL_FILE_METRICS,
  hunkLineCount: 1
};
var DEFAULT_EXPANDED_REGION = Object.freeze({
  fromStart: 0,
  fromEnd: 0
});

// node_modules/@pierre/diffs/dist/utils/cleanLastNewline.js
function cleanLastNewline(contents) {
  return contents.replace(/\n$|\r\n$/, "");
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
function processFile(fileDiffString, options) {
  try {
    return _processFile(fileDiffString, options);
  } finally {
    releaseStringDetachBuffer();
  }
}
function _processFile(fileDiffString, { cacheKey, isGitDiff = GIT_DIFF_FILE_BREAK_REGEX.test(fileDiffString), oldFile, newFile, throwOnError = false } = {}) {
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
        cacheKey: maybeDetachOptionalString(cacheKey)
      };
      if (currentFile.additionLines.length === 1 && newFile?.contents === "")
        currentFile.additionLines.length = 0;
      if (currentFile.deletionLines.length === 1 && oldFile?.contents === "")
        currentFile.deletionLines.length = 0;
      for (const line of lines) {
        if (line.startsWith("diff --git")) {
          const [, , prevName, , name] = line.trim().match(ALTERNATE_FILE_NAMES_GIT) ?? [];
          currentFile.name = detachString(name.trim());
          if (prevName !== name)
            currentFile.prevName = detachString(prevName.trim());
          continue;
        }
        const filenameMatch = line.startsWith("---") || line.startsWith("+++") ? line.match(isGitDiff ? FILENAME_HEADER_REGEX_GIT : FILENAME_HEADER_REGEX) : null;
        if (filenameMatch != null) {
          const [, type, fileName] = filenameMatch;
          if (type === "---" && fileName !== "/dev/null") {
            const detachedFileName = detachString(fileName.trim());
            currentFile.prevName = detachedFileName;
            currentFile.name = detachedFileName;
          } else if (type === "+++" && fileName !== "/dev/null")
            currentFile.name = detachString(fileName.trim());
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
          if (line.startsWith("similarity index"))
            if (line.startsWith("similarity index 100%"))
              currentFile.type = "rename-pure";
            else
              currentFile.type = "rename-changed";
          if (line.startsWith("index ")) {
            const [, prevObjectId, newObjectId, mode] = line.trim().match(INDEX_LINE_METADATA) ?? [];
            if (prevObjectId != null)
              currentFile.prevObjectId = detachString(prevObjectId);
            if (newObjectId != null)
              currentFile.newObjectId = detachString(newObjectId);
            if (mode != null)
              currentFile.mode = detachString(mode);
          }
          if (line.startsWith("rename from "))
            currentFile.prevName = detachString(line.slice(12).trim());
          if (line.startsWith("rename to "))
            currentFile.name = detachString(line.slice(10).trim());
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
      if (parsedAdditionLines >= hunkData.additionCount && parsedDeletionLines >= hunkData.deletionCount && !rawLine.startsWith("\\"))
        break;
      const firstChar = rawLine[0];
      if (firstChar !== "+" && firstChar !== "-" && firstChar !== " " && firstChar !== "\\") {
        console.error(`parseLineType: Invalid firstChar: "${firstChar}", full line: "${rawLine}"`);
        console.error("processFile: invalid rawLine:", rawLine);
        continue;
      }
      const type = parseRawLineType(firstChar);
      if (type === "addition") {
        const line = getParsedLineContent(rawLine);
        if (currentContent == null || currentContent.type !== "change") {
          currentContent = createContentGroup("change", deletionLineIndex, additionLineIndex);
          hunkData.hunkContent.push(currentContent);
        }
        additionLineIndex++;
        parsedAdditionLines++;
        if (isPartial)
          currentFile.additionLines.push(line);
        currentContent.additions++;
        additionLines++;
        lastLineType = "addition";
      } else if (type === "deletion") {
        const line = getParsedLineContent(rawLine);
        if (currentContent == null || currentContent.type !== "change") {
          currentContent = createContentGroup("change", deletionLineIndex, additionLineIndex);
          hunkData.hunkContent.push(currentContent);
        }
        deletionLineIndex++;
        parsedDeletionLines++;
        if (isPartial)
          currentFile.deletionLines.push(line);
        currentContent.deletions++;
        deletionLines++;
        lastLineType = "deletion";
      } else if (type === "context") {
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
          if (lastIndex >= 0)
            currentFile.additionLines[lastIndex] = cleanLastNewline(currentFile.additionLines[lastIndex]);
        }
        if (isPartial && (lastLineType === "deletion" || lastLineType === "context")) {
          const lastIndex = currentFile.deletionLines.length - 1;
          if (lastIndex >= 0)
            currentFile.deletionLines[lastIndex] = cleanLastNewline(currentFile.deletionLines[lastIndex]);
        }
      }
    }
    hunkData.additionLines = additionLines;
    hunkData.deletionLines = deletionLines;
    hunkData.collapsedBefore = Math.max(hunkData.additionStart - 1 - lastHunkEnd, 0);
    currentFile.hunks.push(hunkData);
    lastHunkEnd = hunkData.additionStart + hunkData.additionCount - 1;
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
  if (currentFile.hunks.length > 0 && !isPartial && currentFile.additionLines.length > 0 && currentFile.deletionLines.length > 0) {
    const lastHunk = currentFile.hunks[currentFile.hunks.length - 1];
    const lastHunkEnd$1 = lastHunk.additionStart + lastHunk.additionCount - 1;
    const totalFileLines = currentFile.additionLines.length;
    const collapsedAfter = Math.max(totalFileLines - lastHunkEnd$1, 0);
    currentFile.splitLineCount += collapsedAfter;
    currentFile.unifiedLineCount += collapsedAfter;
  }
  if (!isGitDiff) {
    if (currentFile.prevName != null && currentFile.name !== currentFile.prevName)
      if (currentFile.hunks.length > 0)
        currentFile.type = "rename-changed";
      else
        currentFile.type = "rename-pure";
    else if ((oldFile == null || oldFile.contents === "") && newFile != null && newFile.contents !== "")
      currentFile.type = "new";
    else if (oldFile != null && oldFile.contents !== "" && (newFile == null || newFile.contents === ""))
      currentFile.type = "deleted";
  }
  if (currentFile.type !== "rename-pure" && currentFile.type !== "rename-changed")
    currentFile.prevName = undefined;
  return currentFile;
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
// node_modules/@pierre/diffs/node_modules/diff/libesm/diff/base.js
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
          value = value.map(function(value2, i) {
            const oldValue = oldTokens[oldPos + i];
            return oldValue.length > value2.length ? oldValue : value2;
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

// node_modules/@pierre/diffs/node_modules/diff/libesm/diff/line.js
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
function diffLines(oldStr, newStr, options) {
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

// node_modules/@pierre/diffs/node_modules/diff/libesm/patch/create.js
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
    return diffLinesResultToPatch(diffLines(oldStr, newStr, optionsObj));
  } else {
    const { callback } = optionsObj;
    diffLines(oldStr, newStr, Object.assign(Object.assign({}, optionsObj), { callback: (diff) => {
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
  if (!headerOptions) {
    headerOptions = INCLUDE_HEADERS;
  }
  if (Array.isArray(patch)) {
    if (patch.length > 1 && !headerOptions.includeFileHeaders) {
      throw new Error("Cannot omit file headers on a multi-file patch. " + "(The result would be unparseable; how would a tool trying to apply " + "the patch know which changes are to which file?)");
    }
    return patch.map((p) => formatPatch(p, headerOptions)).join(`
`);
  }
  const ret = [];
  if (headerOptions.includeIndex && patch.oldFileName == patch.newFileName) {
    ret.push("Index: " + patch.oldFileName);
  }
  if (headerOptions.includeUnderline) {
    ret.push("===================================================================");
  }
  if (headerOptions.includeFileHeaders) {
    ret.push("--- " + patch.oldFileName + (typeof patch.oldHeader === "undefined" ? "" : "\t" + patch.oldHeader));
    ret.push("+++ " + patch.newFileName + (typeof patch.newHeader === "undefined" ? "" : "\t" + patch.newHeader));
  }
  for (let i = 0;i < patch.hunks.length; i++) {
    const hunk = patch.hunks[i];
    if (hunk.oldLines === 0) {
      hunk.oldStart -= 1;
    }
    if (hunk.newLines === 0) {
      hunk.newStart -= 1;
    }
    ret.push("@@ -" + hunk.oldStart + "," + hunk.oldLines + " +" + hunk.newStart + "," + hunk.newLines + " @@");
    for (const line of hunk.lines) {
      ret.push(line);
    }
  }
  return ret.join(`
`) + `
`;
}
function createTwoFilesPatch(oldFileName, newFileName, oldStr, newStr, oldHeader, newHeader, options) {
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
// node_modules/@pierre/diffs/dist/utils/parseDiffFromFile.js
function parseDiffFromFile(oldFile, newFile, options, throwOnError = false) {
  const fileData = processFile(createTwoFilesPatch(oldFile.name, newFile.name, oldFile.contents, newFile.contents, oldFile.header, newFile.header, options), {
    cacheKey: (() => {
      if (oldFile.cacheKey != null && newFile.cacheKey != null)
        return `${oldFile.cacheKey}:${newFile.cacheKey}`;
    })(),
    oldFile,
    newFile,
    throwOnError
  });
  if (fileData == null)
    throw new Error("parseDiffFrom: FileInvalid diff -- probably need to fix something -- if the files are the same maybe?");
  if (newFile.lang != null)
    fileData.lang = newFile.lang;
  return fileData;
}
// node_modules/diff/libesm/diff/base.js
class Diff3 {
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
          value = value.map(function(value2, i) {
            const oldValue = oldTokens[oldPos + i];
            return oldValue.length > value2.length ? oldValue : value2;
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
    const segment2 = segmentObj.segment;
    if (parts.length && /\s/.test(parts[parts.length - 1]) && /\s/.test(segment2)) {
      parts[parts.length - 1] += segment2;
    } else {
      parts.push(segment2);
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

class WordDiff extends Diff3 {
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
var wordDiff2 = new WordDiff;
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

class WordsWithSpaceDiff extends Diff3 {
  tokenize(value) {
    const regex = new RegExp(`(\\r?\\n)|[${extendedWordChars}]+|[^\\S\\n\\r]+|[^${extendedWordChars}]`, "ug");
    return value.match(regex) || [];
  }
}
var wordsWithSpaceDiff2 = new WordsWithSpaceDiff;
function diffWordsWithSpace2(oldStr, newStr, options) {
  return wordsWithSpaceDiff2.diff(oldStr, newStr, options);
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
  const remaining = state.deadline - Date.now();
  if (remaining <= 0) {
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
  const parts = diffWordsWithSpace2(origText, modText, { timeout: remaining });
  if (!parts) {
    state.hitTimeout = true;
    return [wholeBlockMapping(origLines, modLines, origStartLine, modStartLine)];
  }
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
function stripTrailingNewline(line) {
  if (line.endsWith(`\r
`))
    return line.slice(0, -2);
  if (line.endsWith(`
`))
    return line.slice(0, -1);
  return line;
}
function toArray(lines) {
  if (Array.isArray(lines))
    return lines;
  return [];
}
function computeLinesDiff(originalInput, modifiedInput, options = {}) {
  const originalLines = toArray(originalInput);
  const modifiedLines = toArray(modifiedInput);
  const ignoreTrimWhitespace = options.ignore_trim_whitespace ?? false;
  const timeoutMs = options.max_computation_time_ms || DEFAULT_TIMEOUT_MS;
  const state = { deadline: Date.now() + timeoutMs, hitTimeout: false };
  if (linesEqual(originalLines, modifiedLines, ignoreTrimWhitespace)) {
    return { changes: [], moves: [], hit_timeout: false };
  }
  const toContents = (lines) => lines.length > 0 ? `${lines.join(`
`)}
` : "";
  let metadata;
  try {
    metadata = parseDiffFromFile({ name: "original", contents: toContents(originalLines) }, { name: "modified", contents: toContents(modifiedLines) }, {
      context: 0,
      ignoreWhitespace: ignoreTrimWhitespace,
      timeout: timeoutMs
    });
  } catch {
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
      const origBlock = metadata.deletionLines.slice(deletionLineIndex, deletionLineIndex + content.deletions).map(stripTrailingNewline);
      const modBlock = metadata.additionLines.slice(additionLineIndex, additionLineIndex + content.additions).map(stripTrailingNewline);
      changes.push({
        original: { start_line: oldLine, end_line: oldLine + content.deletions },
        modified: { start_line: newLine, end_line: newLine + content.additions },
        inner_changes: computeInnerChanges(origBlock, modBlock, oldLine, newLine, state)
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
