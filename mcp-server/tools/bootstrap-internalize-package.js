import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { z } from "zod";
import { run, runPwshScript, textResult } from "../lib/exec.js";
import { resolveLatestVersion, COMMUNITY_SOURCE } from "../lib/resolve-version.js";

export const name = "bootstrap_internalize_package";

export const config = {
  title: "Bootstrap Internalize Package",
  description:
    "One-time first-time onboarding of a Community package: downloads + internalizes it, scans it (AV + Grype via scan-package.ps1), and pushes it to the STAGING feed only. Requires STAGING_FEED_URL/STAGING_API_KEY in the server's environment — this tool never receives production credentials. Use only for a package not yet in staging; refresh-internalized-packages.yml keeps it updated afterward without needing this tool again.",
  inputSchema: {
    package_id: z.string().describe("Chocolatey Community package id to internalize"),
    version: z
      .string()
      .optional()
      .describe("Specific version to internalize; omit to resolve the latest"),
  },
};

export async function handler({ package_id, version }) {
  if (!process.env.STAGING_FEED_URL || !process.env.STAGING_API_KEY) {
    return textResult(
      "STAGING_FEED_URL / STAGING_API_KEY are not set in this server's environment — refusing to internalize without a known, scoped push target.",
      true
    );
  }

  let resolvedVersion = version;
  if (!resolvedVersion) {
    try {
      const resolved = await resolveLatestVersion(package_id);
      if (!resolved) {
        return textResult(`No exact match for '${package_id}' in the Community Repository.`, true);
      }
      resolvedVersion = resolved.version;
    } catch (err) {
      return textResult(String(err.message ?? err), true);
    }
  }

  const tempDir = await fs.mkdtemp(path.join(os.tmpdir(), "internalize-"));

  try {
    const download = await run("choco", [
      "download",
      package_id,
      "--internalize",
      `--source=${COMMUNITY_SOURCE}`,
      "--internalize-all-urls",
      "--no-progress",
      `--version=${resolvedVersion}`,
      `--outputdirectory=${tempDir}`,
    ]);
    if (download.code !== 0) {
      return textResult(
        `choco download --internalize failed (exit ${download.code}):\n${download.stderr || download.stdout}`,
        true
      );
    }

    const scan = await runPwshScript("scripts/scan-package.ps1", ["-PackagePath", tempDir]);
    if (scan.code !== 0) {
      return textResult(
        `scan-package.ps1 failed (exit ${scan.code}) — not pushing:\n${scan.stdout}${scan.stderr}`,
        true
      );
    }

    const nupkgFiles = (await fs.readdir(tempDir)).filter((f) => f.endsWith(".nupkg"));
    if (nupkgFiles.length === 0) {
      return textResult(`No .nupkg produced in ${tempDir} after a successful download — unexpected.`, true);
    }

    for (const file of nupkgFiles) {
      const push = await run("choco", [
        "push",
        path.join(tempDir, file),
        `--source=${process.env.STAGING_FEED_URL}`,
        `--api-key=${process.env.STAGING_API_KEY}`,
      ]);
      if (push.code !== 0) {
        return textResult(
          `choco push failed for ${file} (exit ${push.code}):\n${push.stderr || push.stdout}`,
          true
        );
      }
    }

    return textResult(
      JSON.stringify(
        { packageId: package_id, version: resolvedVersion, pushedTo: "staging", files: nupkgFiles },
        null,
        2
      )
    );
  } finally {
    await fs.rm(tempDir, { recursive: true, force: true });
  }
}
