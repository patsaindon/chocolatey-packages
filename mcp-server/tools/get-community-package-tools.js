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
    "Downloads a Chocolatey Community Repository package (read-only — never internalizes, never pushes anywhere) and returns its tools/chocolateyInstall.ps1 (and chocolateyUninstall.ps1, if present) as text, plus a best-effort detectedSilentArgs pulled straight out of that script if a recognizable 'silentArgs = ...' assignment is in it — checking it yourself in the returned file text first is still worth doing, this is a regex over an arbitrary third-party script, not a guarantee. Useful when scaffolding an internal AU package for software that already has a Community package: its real, community-vetted install script is often a better starting point for silentArgs/softwareName/fileType than a generic guess or a best-effort switch-catalog scrape. Many Community packages split the real install logic into a '<id>.install' variant — the bare id is just a metapackage with no tools/ folder at all — this is tried automatically if the given id has none, found by testing against a real package (7zip has no tools/ folder; 7zip.install does). Some packages instead have a tools/ folder whose whole script is just an Install-VirtualPackage redirect to the real one(s) — found by testing against a different real package (notepadplusplus's own script is one line pointing at notepadplusplus.install) — every named target is tried automatically too, before falling back to the '<id>.install' guess. The returned 'resolvedFrom' (and 'note', if it took a redirect or the '.install' guess to get there) says which id the returned files actually came from.",
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

/** Chocolatey's own convention for a package id that doesn't install
 * anything itself, only points at whichever real package(s) actually do
 * -- found by testing against a real package: notepadplusplus's own
 * chocolateyInstall.ps1 is one line, `Install-VirtualPackage
 * 'notepadplusplus.commandline' 'notepadplusplus.install'`, no real
 * install logic at all. Naively treating that as "found" (which the
 * original version of this tool did, since the file does exist and is
 * non-empty) would hand back a redirect instead of anything usable.
 * Extracts every single-quoted token on the matched line as a candidate
 * target -- this repo doesn't know Install-VirtualPackage's own
 * parameter order/meaning well enough to pick "the" real one over the
 * other, so every token is a candidate, not just the first. */
function extractVirtualPackageTargets(installScript) {
  if (!installScript || !/Install-VirtualPackage/.test(installScript)) return null;
  const line = installScript.split(/\r?\n/).find((l) => /Install-VirtualPackage/.test(l));
  if (!line) return null;
  const ids = [...line.matchAll(/'([^']+)'/g)].map((m) => m[1]);
  return ids.length > 0 ? ids : null;
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
  return {
    found: Object.keys(files).length > 0,
    version: resolved.version,
    files,
    virtualPackageTargets: extractVirtualPackageTargets(files["chocolateyInstall.ps1"]),
  };
}

// Bounds how many candidates a pathological or looping redirect chain
// could make this tool try — real packages need at most two or three
// (the id itself, an '.install' guess, maybe one redirect target), so
// this is purely a backstop, not a limit expected to matter in practice.
const MAX_CANDIDATES = 6;

export async function handler({ package_id }) {
  const tempDir = await fs.mkdtemp(path.join(os.tmpdir(), "get-community-tools-"));
  try {
    const attempted = [];
    const queue = [package_id];
    const validResults = [];

    while (queue.length > 0 && attempted.length < MAX_CANDIDATES) {
      const candidateId = queue.shift();
      if (attempted.includes(candidateId)) continue;
      attempted.push(candidateId);

      let candidateResult;
      try {
        candidateResult = await downloadAndExtract(candidateId, tempDir);
      } catch (err) {
        // The very first candidate failing to even download at all means
        // this id doesn't resolve on Community full stop — worth
        // surfacing immediately. A later, guessed candidate (a
        // '<id>.install' variant, or a virtual-package redirect target)
        // failing the same way is expected far more often than not —
        // not worth an error when another candidate might still answer.
        if (attempted.length === 1) return textResult(String(err.message ?? err), true);
        continue;
      }

      if (candidateResult.found && !candidateResult.virtualPackageTargets) {
        validResults.push({ candidateId, ...candidateResult });
        // Deliberately keep exploring rather than stopping here: a
        // package that redirects to more than one real target (found by
        // testing a real one — notepadplusplus points at both
        // notepadplusplus.commandline and notepadplusplus.install, and
        // the first-found one isn't necessarily the more useful of the
        // two) means the first structurally-valid hit isn't necessarily
        // the best one for what this tool exists to find.
        continue;
      }

      // Follow what the script itself names before guessing a
      // '<id>.install' variant — the script's own redirect is more
      // authoritative than that naming convention.
      if (candidateResult.virtualPackageTargets) {
        queue.push(...candidateResult.virtualPackageTargets.filter((t) => !attempted.includes(t)));
      }
      if (!candidateId.endsWith(".install") && !attempted.includes(`${candidateId}.install`)) {
        queue.push(`${candidateId}.install`);
      }
    }

    if (validResults.length === 0) {
      return textResult(
        `No real install logic found for '${package_id}' after trying ${attempted.map((t) => `'${t}'`).join(", ")} — either it doesn't exist on the Community Repository, its install logic lives under a different id than these, or every candidate found was itself just another redirect.`,
        true
      );
    }

    // Among everything valid this found, prefer whichever candidate
    // actually yields a detected silent-install switch — the whole
    // point of this tool — over just the first one that happened to
    // have real (but not necessarily silentArgs-bearing) install logic.
    const scored = validResults.map((r) => ({ ...r, detectedSilentArgs: extractSilentArgs(r.files["chocolateyInstall.ps1"]) }));
    const best = scored.find((r) => r.detectedSilentArgs) ?? scored[0];

    return textResult(
      JSON.stringify(
        {
          resolvedFrom: best.candidateId,
          ...(best.candidateId !== package_id
            ? { note: `'${package_id}' had no real install logic itself — resolved via: ${attempted.join(" -> ")}` }
            : {}),
          ...(scored.length > 1
            ? { otherCandidatesFound: scored.filter((r) => r !== best).map((r) => r.candidateId) }
            : {}),
          version: best.version,
          detectedSilentArgs: best.detectedSilentArgs ?? "none recognized -- check tools/chocolateyInstall.ps1's text yourself",
          files: best.files,
        },
        null,
        2
      )
    );
  } finally {
    await fs.rm(tempDir, { recursive: true, force: true });
  }
}
