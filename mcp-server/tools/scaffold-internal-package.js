import fs from "node:fs/promises";
import path from "node:path";
import { z } from "zod";
import { textResult, REPO_ROOT } from "../lib/exec.js";

export const name = "scaffold_internal_package";

export const config = {
  title: "Scaffold Internal Package",
  description:
    "Copies internal/_template/ to internal/<package_id>/ and fills in the placeholders it can (id, owner, description, install script, update.ps1's releases URL). au_GetLatest's actual scraping logic still needs a human to verify/adjust — this only seeds it.",
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
  },
};

async function replaceInFile(filePath, replacements) {
  let content = await fs.readFile(filePath, "utf8");
  for (const [pattern, replacement] of replacements) {
    content = content.replace(pattern, replacement);
  }
  await fs.writeFile(filePath, content, "utf8");
}

export async function handler({ package_id, owner_team, source_url, notes }) {
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
  ]);

  await replaceInFile(path.join(targetDir, "update.ps1"), [
    ...(source_url
      ? [[/\$releases = 'https:\/\/CHANGE_ME\/releases'/, `$releases = '${source_url}'`]]
      : []),
    // Best-effort default assuming release filenames start with the
    // package id — a human still needs to verify this against the real
    // release page (see the au_GetLatest TODO left in the file).
    [/'CHANGE_ME-\(\?<version>\[\\d\.\]\+\)\\\.exe'/, `'${package_id}-(?<version>[\\d.]+)\\.exe'`],
  ]);

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
        still_needs_manual_review:
          "update.ps1's au_GetLatest — verify the releases URL and the filename regex actually match this vendor's real release page before merging.",
      },
      null,
      2
    )
  );
}
