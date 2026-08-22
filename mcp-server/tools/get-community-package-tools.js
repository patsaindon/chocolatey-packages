import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { z } from "zod";
import { run, textResult } from "../lib/exec.js";
import { resolveLatestVersion, COMMUNITY_SOURCE } from "../lib/resolve-version.js";

export const name = "get_community_package_tools";

export const config = {
  title: "Get Community Package Tools",
  description:
    "Downloads a Chocolatey Community Repository package (read-only — never internalizes, never pushes anywhere) and returns its tools/chocolateyInstall.ps1 (and chocolateyUninstall.ps1, if present) as text, plus a best-effort detectedSilentArgs pulled straight out of that script if a recognizable 'silentArgs = ...' assignment is in it — checking it yourself in the returned file text first is still worth doing, this is a regex over an arbitrary third-party script, not a guarantee. Useful when scaffolding an internal AU package for software that already has a Community package: its real, community-vetted install script is often a better starting point for silentArgs/softwareName/fileType than a generic guess or a best-effort switch-catalog scrape. Many Community packages split the real install logic into a '<id>.install' variant — the bare id is just a metapackage with no tools/ folder at all — this is tried automatically if the given id has none, found by testing against a real package (7zip has no tools/ folder; 7zip.install does).",
  inputSchema: {
    package_id: z.string().describe("Chocolatey Community package id to read from, e.g. '7zip'"),
  },
};

/** Best-effort extraction of a `silentArgs = '...'` (or "...") assignment
 * from a chocolateyInstall.ps1's text -- the common Chocolatey packaging
 * convention (a $packageArgs hashtable with a silentArgs key), confirmed
 * against a real package (7zip.install). Not exhaustive: scripts that
 * build the switch differently (string concatenation, an array of
 * switches, a per-OS branch) won't match, hence "detected", not
 * "confirmed" -- the caller still gets the full script text to check by
 * eye. Returns null rather than a wrong guess when nothing matches. */
function extractSilentArgs(installScript) {
  if (!installScript) return null;
  const match = installScript.match(/silentArgs\s*=\s*(['"])((?:(?!\1).)*)\1/);
  return match ? match[2] : null;
}

async function downloadAndExtract(packageId, tempDir) {
  const resolved = await resolveLatestVersion(packageId);
  if (!resolved) return { found: false };

  const downloadDir = path.join(tempDir, packageId);
  await fs.mkdir(downloadDir, { recursive: true });

  const download = await run("choco", [
    "download",
    packageId,
    `--source=${COMMUNITY_SOURCE}`,
    "--no-progress",
    "--ignore-dependencies",
    `--version=${resolved.version}`,
    `--outputdirectory=${downloadDir}`,
  ]);
  if (download.code !== 0) {
    throw new Error(
      `choco download failed for '${packageId}' (exit ${download.code}): ${download.stderr || download.stdout}`
    );
  }

  const nupkgFiles = (await fs.readdir(downloadDir)).filter((f) => f.endsWith(".nupkg"));
  if (nupkgFiles.length === 0) return { found: false };

  // A .nupkg is a plain zip — Expand-Archive handles it regardless of the
  // extension, confirmed by testing. Paths go through environment
  // variables rather than string-interpolated into the -Command text, to
  // sidestep PowerShell quoting entirely rather than get it subtly wrong.
  const extractDir = path.join(downloadDir, "extracted");
  const expand = await run(
    "pwsh",
    ["-NoProfile", "-NonInteractive", "-Command", "Expand-Archive -Path $env:NUPKG_PATH -DestinationPath $env:EXTRACT_DIR -Force"],
    { env: { NUPKG_PATH: path.join(downloadDir, nupkgFiles[0]), EXTRACT_DIR: extractDir } }
  );
  if (expand.code !== 0) {
    throw new Error(`Expand-Archive failed for '${packageId}': ${expand.stderr || expand.stdout}`);
  }

  const toolsDir = path.join(extractDir, "tools");
  const files = {};
  for (const fileName of ["chocolateyInstall.ps1", "chocolateyUninstall.ps1"]) {
    try {
      files[fileName] = await fs.readFile(path.join(toolsDir, fileName), "utf8");
    } catch {
      // not present — fine, not every package has an uninstall script, and
      // a metapackage variant has no tools/ folder at all
    }
  }
  return { found: Object.keys(files).length > 0, version: resolved.version, files };
}

export async function handler({ package_id }) {
  const tempDir = await fs.mkdtemp(path.join(os.tmpdir(), "get-community-tools-"));
  try {
    let result;
    let resolvedFrom = package_id;
    try {
      result = await downloadAndExtract(package_id, tempDir);
    } catch (err) {
      return textResult(String(err.message ?? err), true);
    }

    if (!result.found && !package_id.endsWith(".install")) {
      const installVariant = `${package_id}.install`;
      try {
        const fallback = await downloadAndExtract(installVariant, tempDir);
        if (fallback.found) {
          result = fallback;
          resolvedFrom = installVariant;
        }
      } catch {
        // the .install variant not existing is expected for most packages
        // that aren't split this way — not worth surfacing as an error
        // when the original lookup already gave a clear answer
      }
    }

    if (!result.found) {
      return textResult(
        `No tools/chocolateyInstall.ps1 found for '${package_id}'${
          package_id.endsWith(".install") ? "" : ` (also tried '${package_id}.install')`
        } — either it doesn't exist on the Community Repository, or its install logic lives under a different id.`,
        true
      );
    }

    const detectedSilentArgs = extractSilentArgs(result.files["chocolateyInstall.ps1"]);

    return textResult(
      JSON.stringify(
        {
          resolvedFrom,
          version: result.version,
          detectedSilentArgs: detectedSilentArgs ?? "none recognized -- check tools/chocolateyInstall.ps1's text yourself",
          files: result.files,
        },
        null,
        2
      )
    );
  } finally {
    await fs.rm(tempDir, { recursive: true, force: true });
  }
}
