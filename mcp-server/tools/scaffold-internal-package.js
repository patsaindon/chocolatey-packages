import fs from "node:fs/promises";
import path from "node:path";
import { z } from "zod";
import { textResult, REPO_ROOT } from "../lib/exec.js";
import { fetchEvergreenVariants, pickPreferredVariant } from "../lib/evergreen.js";

export const name = "scaffold_internal_package";

export const config = {
  title: "Scaffold Internal Package",
  description:
    "Copies internal/_template/ to internal/<package_id>/ and fills in the placeholders it can (id, owner, description, install script, update.ps1's releases URL). Pass evergreen_app_name (from search_evergreen_app) to generate a real, working au_GetLatest instead of a generic placeholder, and/or silent_args (from search_silent_install_switch) to fill in a real silent-install flag. Without either, both still need a human to research and fill in before this package updates itself correctly.",
  inputSchema: {
    package_id: z
      .string()
      .regex(/^[a-z0-9][a-z0-9.\-]*$/i, "must be a valid Chocolatey package id")
      .describe("Package id — becomes both the folder name and the nuspec filename"),
    owner_team: z.string().describe("Owning team, for metadata.yml / nuspec authors+owners"),
    source_url: z
      .string()
      .url()
      .optional()
      .describe("Where this software publishes releases, if known yet"),
    notes: z.string().optional().describe("Short description / notes"),
    evergreen_app_name: z
      .string()
      .optional()
      .describe("Exact 'name' from search_evergreen_app, if this app is evergreen-supported — generates a real au_GetLatest"),
    silent_args: z
      .string()
      .optional()
      .describe("Real silent-install switch, e.g. from search_silent_install_switch (falls back to a generic '/S' guess if omitted)"),
  },
};

async function replaceInFile(filePath, replacements) {
  let content = await fs.readFile(filePath, "utf8");
  for (const [pattern, replacement] of replacements) {
    content = content.replace(pattern, replacement);
  }
  await fs.writeFile(filePath, content, "utf8");
}

/**
 * Replaces the placeholder au_GetLatest function body with one that calls
 * evergreen-api directly for a known-supported app, using the exact
 * $Latest.URL32/Checksum32 property names the template's au_SearchReplace
 * already expects — no changes needed there. Returns null (caller keeps
 * the generic placeholder) if evergreen has nothing for this name.
 */
async function buildEvergreenGetLatest(evergreenAppName) {
  const variants = await fetchEvergreenVariants(evergreenAppName);
  const preferred = pickPreferredVariant(variants);
  if (!preferred) return null;

  return `function global:au_GetLatest {
    # Seeded from evergreen-api.stealthpuppy.com (https://eucpilots.com/evergreen/api/)
    # for '${evergreenAppName}' — verify the architecture filter below still
    # matches what this package actually wants to ship (was: ${preferred.Architecture ?? "unknown"}).
    $releases = "https://evergreen-api.stealthpuppy.com/app/${evergreenAppName}"
    $variants = Invoke-RestMethod -Uri $releases -UserAgent "chocolatey-packages-mcp-server"
    $latest = $variants | Where-Object { $_.Architecture -eq '${preferred.Architecture ?? ""}' } | Select-Object -First 1
    if (-not $latest) { throw "No matching evergreen-api variant found for ${evergreenAppName}." }

    return @{
        URL32          = $latest.URI
        Version        = $latest.Version
        Checksum32     = $latest.Sha256
        ChecksumType32 = 'sha256'
    }
}`;
}

export async function handler({ package_id, owner_team, source_url, notes, evergreen_app_name, silent_args }) {
  const templateDir = path.join(REPO_ROOT, "internal", "_template");
  const targetDir = path.join(REPO_ROOT, "internal", package_id);

  try {
    await fs.access(targetDir);
    return textResult(`internal/${package_id}/ already exists — refusing to overwrite.`, true);
  } catch {
    // doesn't exist yet, good
  }

  await fs.cp(templateDir, targetDir, { recursive: true });

  // The .nuspec filename itself must match the folder name — see
  // internal/README.md and the check added to lint-nuspec.ps1 after this
  // was found (by testing) to be a hard AU requirement, not just a
  // convention.
  await fs.rename(
    path.join(targetDir, "CHANGE_ME.nuspec"),
    path.join(targetDir, `${package_id}.nuspec`)
  );

  const description = notes || `Internal package for ${package_id}.`;

  await replaceInFile(path.join(targetDir, `${package_id}.nuspec`), [
    [/<id>CHANGE_ME<\/id>/, `<id>${package_id}</id>`],
    [/<title>CHANGE_ME<\/title>/, `<title>${package_id}</title>`],
    [/<authors>CHANGE_ME<\/authors>/, `<authors>${owner_team}</authors>`],
    [/<owners>CHANGE_ME<\/owners>/, `<owners>${owner_team}</owners>`],
    [/<description>CHANGE_ME<\/description>/, `<description>${description}</description>`],
    ...(source_url ? [[/<projectUrl><\/projectUrl>/, `<projectUrl>${source_url}</projectUrl>`]] : []),
  ]);

  await replaceInFile(path.join(targetDir, "metadata.yml"), [
    [/packageId: CHANGE_ME/, `packageId: ${package_id}`],
    [/owner: CHANGE_ME/, `owner: ${owner_team}`],
    [/notes: ""/, `notes: "${description.replace(/"/g, '\\"')}"`],
  ]);

  await replaceInFile(path.join(targetDir, "tools", "chocolateyinstall.ps1"), [
    [/packageName\s*= 'CHANGE_ME'/, `packageName    = '${package_id}'`],
    [/softwareName\s*= 'CHANGE_ME\*'/, `softwareName   = '${package_id}*'`],
    ...(silent_args ? [[/silentArgs\s*= '\/S'(\s*#[^\n]*)?/, `silentArgs     = '${silent_args}'`]] : []),
  ]);

  let usedEvergreen = false;
  let evergreenError = null;
  if (evergreen_app_name) {
    try {
      const generated = await buildEvergreenGetLatest(evergreen_app_name);
      if (generated) {
        await replaceInFile(path.join(targetDir, "update.ps1"), [
          [/function global:au_GetLatest \{[\s\S]*?\n\}/, generated],
        ]);
        usedEvergreen = true;
      }
    } catch (err) {
      evergreenError = err.message;
    }
  }

  if (!usedEvergreen) {
    await replaceInFile(path.join(targetDir, "update.ps1"), [
      ...(source_url
        ? [[/\$releases = 'https:\/\/CHANGE_ME\/releases'/, `$releases = '${source_url}'`]]
        : []),
      // Best-effort default assuming release filenames start with the
      // package id — a human still needs to verify this against the real
      // release page (see the au_GetLatest TODO left in the file).
      [/'CHANGE_ME-\(\?<version>\[\\d\.\]\+\)\\\.exe'/, `'${package_id}-(?<version>[\\d.]+)\\.exe'`],
    ]);
  }

  return textResult(
    JSON.stringify(
      {
        created: `internal/${package_id}/`,
        files: [
          `internal/${package_id}/${package_id}.nuspec`,
          `internal/${package_id}/metadata.yml`,
          `internal/${package_id}/update.ps1`,
          `internal/${package_id}/tools/chocolateyinstall.ps1`,
        ],
        au_get_latest_source: usedEvergreen
          ? `seeded from evergreen-api ('${evergreen_app_name}')`
          : evergreenError
            ? `evergreen_app_name given but lookup failed (${evergreenError}) — fell back to the generic placeholder`
            : "generic placeholder — no evergreen_app_name given",
        silent_args_source: silent_args ? `seeded ('${silent_args}')` : "generic '/S' placeholder — no silent_args given",
        still_needs_manual_review:
          "update.ps1's au_GetLatest — verify the architecture/version-matching logic (and the releases URL/regex, if not evergreen-seeded) against this vendor's real release page before merging.",
      },
      null,
      2
    )
  );
}
