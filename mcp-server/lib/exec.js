import { spawn } from "node:child_process";
import path from "node:path";
import { fileURLToPath } from "node:url";

// mcp-server/ lives at the repo root's top level, so its parent is the repo root.
export const REPO_ROOT = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  "..",
  ".."
);

/**
 * Runs a command and collects its output. Never throws on a non-zero exit —
 * callers decide what a failing exit code means for their tool's result.
 */
export function run(command, args, options = {}) {
  return new Promise((resolve, reject) => {
    const proc = spawn(command, args, {
      cwd: options.cwd ?? REPO_ROOT,
      env: { ...process.env, ...(options.env ?? {}) },
      shell: false,
    });

    let stdout = "";
    let stderr = "";
    proc.stdout?.on("data", (d) => (stdout += d.toString()));
    proc.stderr?.on("data", (d) => (stderr += d.toString()));
    proc.on("error", reject);
    proc.on("close", (code) => resolve({ code: code ?? -1, stdout, stderr }));
  });
}

/** Runs a repo PowerShell script under pwsh, relative to REPO_ROOT unless absolute. */
export function runPwshScript(scriptRelativePath, args = [], options = {}) {
  const scriptPath = path.isAbsolute(scriptRelativePath)
    ? scriptRelativePath
    : path.join(REPO_ROOT, scriptRelativePath);
  return run(
    "pwsh",
    ["-NoProfile", "-NonInteractive", "-File", scriptPath, ...args],
    options
  );
}

/** Wraps a plain-text tool result, flagging isError when the exit code is non-zero. */
export function textResult(text, isError = false) {
  return { content: [{ type: "text", text }], isError };
}
