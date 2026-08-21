import path from "node:path";
import { z } from "zod";
import { runPwshScript, textResult, REPO_ROOT } from "../lib/exec.js";

export const name = "lint_package";

export const config = {
  title: "Lint Package",
  description:
    "Runs scripts/lint-nuspec.ps1 against a package folder (internal/<id> or internalized/<id>) and reports every violation found. Read-only.",
  inputSchema: {
    package_dir: z
      .string()
      .describe(
        "Path to the package folder relative to the repo root, e.g. 'internal/my-package'"
      ),
  },
};

export async function handler({ package_dir }) {
  const absDir = path.join(REPO_ROOT, package_dir);
  const { code, stdout, stderr } = await runPwshScript(
    "scripts/lint-nuspec.ps1",
    ["-PackageDir", absDir]
  );

  return textResult(stdout + stderr, code !== 0);
}
