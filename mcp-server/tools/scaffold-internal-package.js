import fs from "node:fs/promises";
import path from "node:path";
import { z } from "zod";
import { textResult, REPO_ROOT } from "../lib/exec.js";
import { fetchEvergreenVariants, pickPreferredVariant, fetchEvergreenAppIndexEntry } from "../lib/evergreen.js";
import { readKnowledge } from "../lib/knowledge.js";

export const name = "scaffold_internal_package";

export const config = {
  title: "Scaffold Internal Package",
  description:
    "Copies internal/_template/ to internal/<package_id>/ and fills in the placeholders it can (id, owner, description, install script, update.ps1's releases URL, and a coherent title/authors/projectUrl/tags for the nuspec). Pass evergreen_app_name (from search_evergreen_app) to generate a real, working au_GetLatest AND to seed the nuspec's title/authors/projectUrl from evergreen's own app index, instead of a generic placeholder for either. Pass title/vendor_name explicitly to override or to fill these in for a non-evergreen package. Pass vendor (the same slug used with lookup_package_knowledge) to also seed silent_args/source_url from knowledge/<vendor>.yml when you haven't found a fresher value yourself this run — call lookup_package_knowledge first if you want to know what it'll use before scaffolding. Pass silent_args explicitly (e.g. from search_silent_install_switch or a real chocolateyInstall.ps1 via get_community_package_tools) to fill in a real silent-install flag; an explicit value always wins over the knowledge base. Anything left unfilled still needs a human to research before this package updates itself correctly.",
  inputSchema: {
    package_id: z
      .string()
      .regex(/^[a-z0-9][a-z0-9.\-]*$/i, "must be a valid Chocolatey package id")
      .describe("Package id — becomes both the folder name and the nuspec filename"),
    owner_team: z.string().describe("Owning team, for metadata.yml / nuspec owners"),
    title: z
      .string()
      .optional()
      .describe(
        "Human-friendly display name for the nuspec's <title>, e.g. 'Eclipse Temurin 25 (JDK)'. Falls back to evergreen's own app-index name when evergreen_app_name is given, else a prettified package_id."
      ),
    vendor_name: z
      .string()
      .optional()
      .describe(
        "The software's actual publisher/vendor, for the nuspec's <authors> — distinct from owner_team, which is who owns *this Chocolatey package* internally, not who makes the software. Falls back to evergreen's app-index name when evergreen_app_name is given, else owner_team."
      ),
    source_url: z
      .string()
      .url()
      .optional()
      .describe("Where this software publishes releases, and the nuspec's <projectUrl> — falls back to evergreen's own homepage link when evergreen_app_name is given"),
    notes: z.string().optional().describe("Short description / notes"),
    vendor: z
      .string()
      .optional()
      .describe(
        "Vendor/product-family slug (same one used with lookup_package_knowledge/write_package_knowledge) — if given, knowledge/<vendor>.yml's own 'silent_args' and 'source_url' facts (if recorded) fill in for silent_args/source_url when those aren't passed explicitly."
      ),
    evergreen_app_name: z
      .string()
      .optional()
      .describe("Exact 'name' from search_evergreen_app, if this app is evergreen-supported — generates a real au_GetLatest and seeds title/vendor_name/source_url from evergreen's app index"),
    evergreen_image_type: z
      .string()
      .optional()
      .describe(
        "Some evergreen apps (JDKs especially) publish more than one x64 variant distinguished only by ImageType (e.g. 'jdk' vs 'jre') — check get_evergreen_app_info first if unsure; defaults to preferring 'jdk' over 'jre' when both exist and this is omitted"
      ),
    silent_args: z
      .string()
      .optional()
      .describe("Real silent-install switch, e.g. from search_silent_install_switch (falls back to a generic '/S' guess if omitted)"),
    nexus_generic_base_url: z
      .string()
      .url()
      .optional()
      .describe(
        "For paywalled software only: the Nexus base URL (e.g. 'https://nexus.internal') where a human has manually deposited the binary into a generic/raw-format hosted repository, because this automation must never hold the vendor login the real download needs. Requires nexus_generic_repository and nexus_generic_path_prefix too — all three together generate an au_GetLatest that reads the latest asset already uploaded there instead of scraping a vendor page. NOT YET VERIFIED AGAINST A REAL NEXUS INSTANCE — see docs/architecture.md."
      ),
    nexus_generic_repository: z
      .string()
      .optional()
      .describe("The generic/raw-format repository name in Nexus holding this package's manually-uploaded binaries"),
    nexus_generic_path_prefix: z
      .string()
      .optional()
      .describe("Path prefix inside that repository under which every version of this package's binary gets uploaded, e.g. 'acme/licensed-app/'"),
  },
};

/** 'visual-studio-code' / 'visual_studio_code' -> 'Visual Studio Code'. Only
 * used as a last-resort <title> fallback when neither an explicit title
 * nor an evergreen app-index name is available — always prefer one of
 * those when they exist, since this is a mechanical guess, not a real name. */
function prettifyPackageId(packageId) {
  return packageId
    .replace(/[-_.]+/g, " ")
    .split(" ")
    .filter(Boolean)
    .map((word) => (/^\d/.test(word) ? word : word[0].toUpperCase() + word.slice(1)))
    .join(" ");
}

/** 'Adoptium Temurin 25' -> 'adoptium-temurin-25', for an extra nuspec tag. */
function slugifyTag(text) {
  return text
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "");
}

async function replaceInFile(filePath, replacements) {
  let content = await fs.readFile(filePath, "utf8");
  for (const [pattern, replacement] of replacements) {
    // A replacer FUNCTION, not the bare string: found by testing that
    // JS's String.replace() treats a string replacement's own '$' as
    // special-pattern syntax ($&, $`, $', $1..$99, $$) — the generated
    // au_GetLatest body legitimately contains '$' for both PowerShell
    // variable sigils and regex end-anchors, and '$\'' (dollar directly
    // followed by a closing quote) matched the "insert everything after
    // the match" pattern, splicing the rest of the file into the middle
    // of the generated function body. A function's return value is
    // always inserted literally, sidestepping this entirely.
    content = content.replace(pattern, () => replacement);
  }
  await fs.writeFile(filePath, content, "utf8");
}

/**
 * Replaces the placeholder au_GetLatest function body with one that calls
 * evergreen-api directly for a known-supported app, using the exact
 * $Latest.URL32/Checksum32 property names the template's au_SearchReplace
 * already expects — no changes needed there. Returns null (caller keeps
 * the generic placeholder) if evergreen has nothing for this name, else
 * { code, imageType } — imageType is surfaced too so the caller can add
 * it as a nuspec tag without a second, redundant variant fetch.
 */
async function buildEvergreenGetLatest(evergreenAppName, imageType) {
  const variants = await fetchEvergreenVariants(evergreenAppName);
  const preferred = pickPreferredVariant(variants, { imageType });
  if (!preferred) return null;

  // The ImageType condition must be baked into the *generated* filter too,
  // not just used to pick the seed file's initial content — otherwise
  // every subsequent real au_GetLatest run hits the same jdk-vs-jre
  // ambiguity this was written to solve, since evergreen still returns
  // both variants every time. Found by testing against AdoptiumTemurin25,
  // which has exactly two x64 variants with no other distinguishing field.
  const imageTypeCondition = preferred.ImageType
    ? ` -and $_.ImageType -eq '${preferred.ImageType}'`
    : "";

  const code = `function global:au_GetLatest {
    # Seeded from evergreen-api.stealthpuppy.com (https://eucpilots.com/evergreen/api/)
    # for '${evergreenAppName}' — verify the filter below still matches what
    # this package actually wants to ship (was: Architecture=${preferred.Architecture ?? "unknown"}${preferred.ImageType ? `, ImageType=${preferred.ImageType}` : ""}).
    $releases = "https://evergreen-api.stealthpuppy.com/app/${evergreenAppName}"
    $variants = Invoke-RestMethod -Uri $releases -UserAgent "chocolatey-packages-mcp-server"
    $latest = $variants | Where-Object { $_.Architecture -eq '${preferred.Architecture ?? ""}'${imageTypeCondition} } | Select-Object -First 1
    if (-not $latest) { throw "No matching evergreen-api variant found for ${evergreenAppName}." }

    # The checksum field name varies per app — found by testing: 7zip uses
    # 'Sha256', AdoptiumTemurin25 uses 'Checksum'. Try both rather than
    # hardcoding one and silently getting an empty checksum for apps that
    # use the other name.
    $checksum = if ($latest.Sha256) { $latest.Sha256 } else { $latest.Checksum }

    # Evergreen's Version can carry build-metadata syntax NuGet/choco
    # versions don't accept (e.g. '25.0.4.1+1-LTS') — same sanitization
    # already proven to work in production for temurin17's own
    # hand-written au_GetLatest. But found by testing a *different* real
    # app (Temurin25): that replacement isn't always enough on its own —
    # some vendors' version strings have more numeric segments than
    # NuGet/choco's 4-segment limit even after it, which temurin17's
    # version format happened not to hit. Fail loudly here instead of
    # letting choco pack fail later with a more confusing error.
    $version = $latest.Version -replace '\\+', '.'
    if ($version -notmatch '^\\d+(\\.\\d+){0,3}(-.+)?$') {
        throw "Sanitized version '$version' has more than 4 numeric segments (NuGet/choco's limit) — adjust this au_GetLatest's version handling for ${evergreenAppName}'s actual version format."
    }

    return @{
        URL32          = $latest.URI
        Version        = $version
        Checksum32     = $checksum
        ChecksumType32 = 'sha256'
    }
}`;

  return { code, imageType: preferred.ImageType };
}

/**
 * Generates an au_GetLatest that reads the latest asset a human already
 * uploaded to a Nexus generic (raw-format) hosted repository, instead of
 * scraping a vendor page — for software behind a paywall/login this
 * automation must never hold credentials for (same reasoning as every
 * other credential-scoping decision in this repo). `scripts/Get-
 * NexusGenericLatestAsset.ps1`'s own header has the full design rationale
 * and its "not yet verified against a real Nexus" caveat, which the
 * generated comment repeats so a human reviewing this specific package
 * sees it too, not just whoever reads the shared script once.
 */
function buildNexusGenericGetLatest(baseUrl, repository, pathPrefix) {
  return `function global:au_GetLatest {
    # Sourced from a Nexus generic (raw-format) hosted repository, not a
    # vendor page: this software is paywalled, so a human logs in,
    # downloads a new release themselves, and uploads it to this fixed
    # path whenever the vendor ships one — this automation never holds
    # those vendor credentials, only reads what was already deposited.
    # NOT YET VERIFIED AGAINST A REAL NEXUS INSTANCE — see
    # docs/architecture.md and scripts/Get-NexusGenericLatestAsset.ps1's
    # own header before trusting this in production.
    $scriptPath = Join-Path $PSScriptRoot '..' '..' 'scripts' 'Get-NexusGenericLatestAsset.ps1'
    $asset = & $scriptPath -NexusBaseUrl '${baseUrl}' -Repository '${repository}' -PathPrefix '${pathPrefix}'

    return @{
        URL32          = $asset.DownloadUrl
        Version        = $asset.Version
        Checksum32     = $asset.Sha256
        ChecksumType32 = 'sha256'
    }
}`;
}

export async function handler({
  package_id,
  owner_team,
  title,
  vendor_name,
  source_url,
  notes,
  vendor,
  evergreen_app_name,
  evergreen_image_type,
  silent_args,
  nexus_generic_base_url,
  nexus_generic_repository,
  nexus_generic_path_prefix,
}) {
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

  // Fetched once, up front, so both the nuspec (title/authors/projectUrl)
  // and update.ps1 (au_GetLatest) can draw from the same evergreen data —
  // this was already being fetched by search_evergreen_app and then
  // discarded, leaving the nuspec's <title> as the bare package id and
  // <projectUrl> empty even for a well-supported app. A lookup failure
  // here is never fatal: every field it would have seeded still has an
  // explicit-parameter or generic fallback.
  let appIndexEntry = null;
  if (evergreen_app_name) {
    try {
      appIndexEntry = await fetchEvergreenAppIndexEntry(evergreen_app_name);
    } catch {
      // non-fatal — falls back to explicit params / generic defaults below
    }
  }

  // Read once, up front, same reasoning as the evergreen fetch above: this
  // was previously only ever read by the agent calling lookup_package_
  // knowledge itself and manually copying values into silent_args/
  // source_url — easy to forget, and found by testing that it in fact was
  // forgotten (temurin25's real knowledge entry never got a silent_args
  // recorded even though a real one was surely used). A missing/unreadable
  // vendor file is never fatal — every field it would have seeded still
  // has an explicit-parameter, evergreen, or generic fallback.
  let knowledgeFacts = null;
  if (vendor) {
    try {
      knowledgeFacts = await readKnowledge(vendor);
    } catch {
      // non-fatal
    }
  }

  const effectiveTitle = title || appIndexEntry?.Application || prettifyPackageId(package_id);
  // Distinct from effectiveVendorName's owner_team fallback below: a tag
  // should describe the *software*, not who owns the internal package, so
  // it's only set when there's a real vendor/product name to slugify.
  const realVendorName = vendor_name || appIndexEntry?.Application || null;
  const effectiveVendorName = realVendorName || owner_team;
  const effectiveProjectUrl = source_url || appIndexEntry?.Link || knowledgeFacts?.source_url || null;
  const effectiveSilentArgs = silent_args || knowledgeFacts?.silent_args || null;
  const packageSourceUrl = `https://github.com/patsaindon/chocolatey-packages/tree/main/internal/${package_id}`;

  let usedEvergreen = false;
  let evergreenError = null;
  let evergreenImageType = null;
  const usedNexusGeneric = Boolean(
    nexus_generic_base_url && nexus_generic_repository && nexus_generic_path_prefix
  );
  if (usedNexusGeneric) {
    // Takes priority over evergreen_app_name if both were somehow given —
    // an explicit Nexus path is a deliberate signal that this specific
    // software's real releases aren't reachable any other way, which
    // wouldn't be true of anything evergreen-api already tracks.
    await replaceInFile(path.join(targetDir, "update.ps1"), [
      [
        /function global:au_GetLatest \{[\s\S]*?\n\}/,
        buildNexusGenericGetLatest(nexus_generic_base_url, nexus_generic_repository, nexus_generic_path_prefix),
      ],
    ]);
  } else if (evergreen_app_name) {
    try {
      const generated = await buildEvergreenGetLatest(evergreen_app_name, evergreen_image_type);
      if (generated) {
        await replaceInFile(path.join(targetDir, "update.ps1"), [
          [/function global:au_GetLatest \{[\s\S]*?\n\}/, generated.code],
        ]);
        usedEvergreen = true;
        evergreenImageType = generated.imageType ?? null;
      }
    } catch (err) {
      evergreenError = err.message;
    }
  }

  // Extra tags beyond the template's default 'internal': a slug for the
  // vendor/product name (skipped if it wouldn't add anything beyond the
  // package id itself) and, for apps like JDKs where it disambiguates
  // real variants (Section 6.8), the image type.
  const extraTags = [realVendorName ? slugifyTag(realVendorName) : null, evergreenImageType]
    .filter(Boolean)
    .filter((tag) => tag !== package_id.toLowerCase());
  const tags = ["internal", ...new Set(extraTags)].join(" ");

  await replaceInFile(path.join(targetDir, `${package_id}.nuspec`), [
    [/<id>CHANGE_ME<\/id>/, `<id>${package_id}</id>`],
    [/<title>CHANGE_ME<\/title>/, `<title>${effectiveTitle}</title>`],
    [/<authors>CHANGE_ME<\/authors>/, `<authors>${effectiveVendorName}</authors>`],
    [/<owners>CHANGE_ME<\/owners>/, `<owners>${owner_team}</owners>`],
    [/<packageSourceUrl>CHANGE_ME<\/packageSourceUrl>/, `<packageSourceUrl>${packageSourceUrl}</packageSourceUrl>`],
    [/<description>CHANGE_ME<\/description>/, `<description>${description}</description>`],
    [/<tags>internal<\/tags>/, `<tags>${tags}</tags>`],
    ...(effectiveProjectUrl ? [[/<projectUrl><\/projectUrl>/, `<projectUrl>${effectiveProjectUrl}</projectUrl>`]] : []),
  ]);

  await replaceInFile(path.join(targetDir, "metadata.yml"), [
    [/packageId: CHANGE_ME/, `packageId: ${package_id}`],
    [/owner: CHANGE_ME/, `owner: ${owner_team}`],
    [/notes: ""/, `notes: "${description.replace(/"/g, '\\"')}"`],
  ]);

  await replaceInFile(path.join(targetDir, "tools", "chocolateyinstall.ps1"), [
    [/packageName\s*= 'CHANGE_ME'/, `packageName    = '${package_id}'`],
    [/softwareName\s*= 'CHANGE_ME\*'/, `softwareName   = '${package_id}*'`],
    ...(effectiveSilentArgs ? [[/silentArgs\s*= '\/S'(\s*#[^\n]*)?/, `silentArgs     = '${effectiveSilentArgs}'`]] : []),
  ]);

  if (!usedEvergreen && !usedNexusGeneric) {
    await replaceInFile(path.join(targetDir, "update.ps1"), [
      ...(effectiveProjectUrl
        ? [[/\$releases = 'https:\/\/CHANGE_ME\/releases'/, `$releases = '${effectiveProjectUrl}'`]]
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
        au_get_latest_source: usedNexusGeneric
          ? `reads the latest asset from Nexus generic repo '${nexus_generic_repository}' at '${nexus_generic_path_prefix}' (paywalled-software path — NOT yet verified against a real Nexus instance, see docs/architecture.md)`
          : usedEvergreen
            ? `seeded from evergreen-api ('${evergreen_app_name}')`
            : evergreenError
              ? `evergreen_app_name given but lookup failed (${evergreenError}) — fell back to the generic placeholder`
              : "generic placeholder — no evergreen_app_name given",
        silent_args_source: effectiveSilentArgs
          ? `${effectiveSilentArgs}${silent_args ? " (explicit)" : ` (from knowledge/${vendor}.yml — write_package_knowledge if this turns out wrong or missing for the next package)`}`
          : "generic '/S' placeholder — no silent_args given and none recorded in the knowledge base for this vendor",
        nuspec: {
          title: `${effectiveTitle}${title ? " (explicit)" : appIndexEntry ? " (from evergreen's app index)" : " (prettified package_id — pass 'title' explicitly if this doesn't read naturally)"}`,
          authors: `${effectiveVendorName}${vendor_name ? " (explicit)" : appIndexEntry ? " (from evergreen's app index)" : " (fell back to owner_team — pass 'vendor_name' if this software has a different real publisher)"}`,
          projectUrl: effectiveProjectUrl
            ? `${effectiveProjectUrl}${source_url ? " (explicit)" : appIndexEntry ? " (from evergreen's app index)" : ` (from knowledge/${vendor}.yml)`}`
            : "left empty — pass 'source_url', an evergreen_app_name with a homepage link, or record one in the knowledge base",
          tags,
        },
        still_needs_manual_review: usedNexusGeneric
          ? "update.ps1's au_GetLatest reads from Nexus generic repo — confirm a human has actually uploaded a binary under the given path prefix, that NEXUS_GENERIC_READ_TOKEN (or equivalent) is configured wherever this package's AU update runs, and that this whole mechanism has been tested against the real Nexus instance at least once (it hasn't yet — see docs/architecture.md)."
          : "update.ps1's au_GetLatest — verify the architecture/version-matching logic (and the releases URL/regex, if not evergreen-seeded) against this vendor's real release page before merging.",
      },
      null,
      2
    )
  );
}
