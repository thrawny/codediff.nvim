// NDJSON-over-stdio diff server for codediff.nvim.
//
// One long-lived process per Neovim instance. Requests and responses are
// single-line JSON objects:
//   -> {"id":1,"method":"computeDiff","params":{"original":[],"modified":[],"options":{}}}
//   <- {"id":1,"result":{"changes":[],"moves":[],"hit_timeout":false}}
//   <- {"id":1,"error":"message"} on failure

import { readFileSync } from "node:fs";
import { computeLinesDiff, type DiffOptions } from "./linesDiff";

interface Request {
  id?: number;
  method?: string;
  params?: {
    original?: unknown;
    modified?: unknown;
    options?: DiffOptions;
  };
}

function engineVersion(): string {
  try {
    const versionFile = new URL("../../VERSION", import.meta.url);
    return readFileSync(versionFile, "utf8").trim();
  } catch {
    return "unknown";
  }
}

function respond(payload: Record<string, unknown>): void {
  process.stdout.write(`${JSON.stringify(payload)}\n`);
}

function handleLine(line: string): void {
  const trimmed = line.trim();
  if (trimmed === "") return;

  let request: Request;
  try {
    request = JSON.parse(trimmed) as Request;
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

async function main(): Promise<void> {
  const decoder = new TextDecoder();
  let buffered = "";

  for await (const chunk of Bun.stdin.stream()) {
    buffered += decoder.decode(chunk, { stream: true });
    let newlineIndex = buffered.indexOf("\n");
    while (newlineIndex !== -1) {
      const line = buffered.slice(0, newlineIndex);
      buffered = buffered.slice(newlineIndex + 1);
      handleLine(line);
      newlineIndex = buffered.indexOf("\n");
    }
  }
}

main().catch((error) => {
  process.stderr.write(`codediff engine crashed: ${String(error)}\n`);
  process.exit(1);
});
