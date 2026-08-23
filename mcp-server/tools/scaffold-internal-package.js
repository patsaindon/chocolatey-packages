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
      .describe("Real silent-install switch, e.g. from search_silent_install_switch (falls back to a generic '/S' guess if omitted). Ignored when package_kind is 'portable' — there's no installer to run silently."),
    package_kind: z
      .enum(["installer", "portable"])
      .optional()
      .describe(
        "'installer' (default): the release ships a real installer (.exe/.msi) that runs silently via Install-ChocolateyPackage — the only kind this tool supported until this parameter was added. 'portable': the release is just a standalone CLI binary with no install wizard at all (confirmed by real testing: running one through the installer path would try to silently \"install\" a binary that isn't an installer, hanging or behaving unpredictably) — generates a chocolateyinstall.ps1 using Get-ChocolateyWebFile to place the binary under tools\\ instead, which Chocolatey auto-shims onto PATH."
      ),
    binary_name: z
      .string()
      .optional()
      .describe(
        "Portable packages only: the real upstream command name users should type to run this tool, e.g. 'cgc' for a package whose id is 'codegraphcontext' — this becomes the shimmed executable's name, which matters more than the package id for a CLI tool's actual usability. Defaults to package_id if omitted."
      ),
    nexus_generic_base_url: z
      .string()
      .url()
      .optional()
      .describe(
        "For paywalled software only: the Nexus base URL (e.g. 'https://nexus.internal') where a human has manually deposited the binary into a generic/raw-format hosted repository, because this automation must never hold the vendor login the real download needs. Requires nexus_generic_repository and nexus_generic_path_prefix too — all three together generate an au_GetLatest that reads the latest asset already uploaded there instead of scraping a vendor page. Verified end-to-end against a real Nexus instance — see docs/architecture.md. Note the Nexus-side requirement this testing surfaced: the generated au_GetLatest's download step needs the target repository to be readable by whatever runs it (anonymous read scoped to just that repository, not Nexus's broader default, is the tested approach — see docs/architecture.md)."
      ),
    nexus_generic_repository: z
      .string()
      .optional()
      .describe("The generic/raw-format repository name in Nexus holding this package's manually-uploaded binaries"),
    nexus_generic_path_prefix: z
      .string()
      .optional()
      .describe("Path prefix inside that repository under which every version of this package's binary gets uploaded, e.g. 'acme/licensed-app/'"),
    dependencies: z
      .array(
        z.object({
          id: z.string().describe("The dependency's own Chocolatey package id — must already exist in staging/production, e.g. from an earlier internalize/scaffold"),
          version: z.string().optional().describe("Minimum version, e.g. '1.0.0' — omit for 'any version'"),
        })
      )
      .optional()
      .describe(
        "Real package dependencies for the nuspec's <dependencies> element — e.g. this internal package needs a runtime that's itself packaged separately. Promotion (Get-PromotionCandidates.ps1) already reads this element and recursively includes missing dependencies when promoting a batch, so a real dependency declared here gets carried to production correctly instead of silently missing."
      ),
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

/** Minimal XML attribute-value escaping -- dependency ids/versions are
 * normally safe identifiers, but a stray '&'/'"' shouldn't be able to
 * produce a malformed nuspec. */
function escapeXmlAttr(value) {
  return String(value).replace(/&/g, "&amp;").replace(/"/g, "&quot;").replace(/</g, "&lt;");
}

/** Builds the <dependencies>...</dependencies> block Get-PromotionCandidates.ps1
 * already knows how to read (package.metadata.dependencies.dependency[].id) --
 * this is the write side of that same, already-tested shape. */
function buildDependenciesXml(dependencies) {
  const entries = dependencies
    .map((dep) => {
      const versionAttr = dep.version ? ` version="${escapeXmlAttr(dep.version)}"` : "";
      return `      <dependency id="${escapeXmlAttr(dep.id)}"${versionAttr} />`;
    })
    .join("\n");
  return `<dependencies>\n${entries}\n    </dependencies>`;
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
async function buildEvergreenGetLatest(evergreenAppName, imageType, packageKind) {
  const variants = await fetchEvergreenVariants(evergreenAppName);
  const preferred = pickPreferredVariant(variants, { imageType, packageKind });
  if (!preferred) return null;

  // Both conditions must be baked into the *generated* filter too, not
  // just used to pick the seed file's initial content — otherwise every
  // subsequent real au_GetLatest run hits the same ambiguity this was
  // written to solve, since evergreen still returns every variant every
  // time. ImageType: found by testing against AdoptiumTemurin25, which has
  // exactly two x64 variants with no other distinguishing field.
  // InstallerType: found by testing against Alacritty, which publishes
  // both a real installer (.msi, InstallerType 'Default') and a portable
  // single-binary variant (.exe, InstallerType 'Portable') side by side —
  // without this, a future run could silently drift onto the wrong one
  // the moment evergreen's own array order changes.
  const imageTypeCondition = preferred.ImageType
    ? ` -and $_.ImageType -eq '${preferred.ImageType}'`
    : "";
  const installerTypeCondition = preferred.InstallerType
    ? ` -and $_.InstallerType -eq '${preferred.InstallerType}'`
    : "";

  const code = `function global:au_GetLatest {
    # Seeded from evergreen-api.stealthpuppy.com (https://eucpilots.com/evergreen/api/)
    # for '${evergreenAppName}' — verify the filter below still matches what
    # this package actually wants to ship (was: Architecture=${preferred.Architecture ?? "unknown"}${preferred.ImageType ? `, ImageType=${preferred.ImageType}` : ""}${preferred.InstallerType ? `, InstallerType=${preferred.InstallerType}` : ""}).
    $releases = "https://evergreen-api.stealthpuppy.com/app/${evergreenAppName}"
    $variants = Invoke-RestMethod -Uri $releases -UserAgent "chocolatey-packages-mcp-server"
    $latest = $variants | Where-Object { $_.Architecture -eq '${preferred.Architecture ?? ""}'${imageTypeCondition}${installerTypeCondition} } | Select-Object -First 1
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

  return { code, imageType: preferred.ImageType, fileType: preferred.Type };
}

/**
 * Generates an au_GetLatest that reads the latest asset a human already
 * uploaded to a Nexus generic (raw-format) hosted repository, instead of
 * scraping a vendor page — for software behind a paywall/login this
 * automation must never hold credentials for (same reasoning as every
 * other credential-scoping decision in this repo). `scripts/Get-
 * NexusGenericLatestAsset.ps1`'s own header has the full design rationale
 * and its real-Nexus verification notes, which the generated comment
 * repeats so a human reviewing this specific package sees them too, not
 * just whoever reads the shared script once.
 */
function buildNexusGenericGetLatest(baseUrl, repository, pathPrefix) {
  return `function global:au_GetLatest {
    # Sourced from a Nexus generic (raw-format) hosted repository, not a
    # vendor page: this software is paywalled, so a human logs in,
    # downloads a new release themselves, and uploads it to this fixed
    # path whenever the vendor ships one — this automation never holds
    # those vendor credentials, only reads what was already deposited.
    # Verified against a real Nexus instance (docs/architecture.md) —
    # NEXUS_GENERIC_READ_TOKEN must be set wherever this runs (a
    # 'username:password' or Nexus User Token pair), and the target
    # repository needs to be readable by whatever downloads the file this
    # returns (Get-ChocolateyWebFile has no credential of its own to send
    # — see docs/architecture.md's note on scoping anonymous read to just
    # this one repository, not Nexus's broader default).
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
  dependencies,
  package_kind,
  binary_name,
}) {
  const effectivePackageKind = package_kind || "installer";
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
  let evergreenFileType = null;
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
      const generated = await buildEvergreenGetLatest(evergreen_app_name, evergreen_image_type, effectivePackageKind);
      if (generated) {
        await replaceInFile(path.join(targetDir, "update.ps1"), [
          [/function global:au_GetLatest \{[\s\S]*?\n\}/, generated.code],
        ]);
        usedEvergreen = true;
        evergreenImageType = generated.imageType ?? null;
        evergreenFileType = generated.fileType ?? null;
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
    // <projectUrl> specifically always gets *some* value, even when no
    // real vendor page was found anywhere -- found by testing (a real
    // package-request run for a paywalled package with no source_url
    // passed) that `choco pack` hard-fails ("CHCR0001: The projectUrl
    // element in the package nuspec file cannot be empty") long after
    // scaffolding, in CI rather than at scaffold time. Falling back to
    // this repo's own packageSourceUrl (always set, needs no input)
    // guarantees `choco pack` never fails on this specifically -- it's
    // not a substitute for a real vendor URL, just a safe placeholder
    // that's honestly reported as such below, unlike effectiveProjectUrl
    // itself (used elsewhere as a real scraping source), which stays
    // null rather than silently claiming this fallback is a real source.
    [/<projectUrl><\/projectUrl>/, `<projectUrl>${effectiveProjectUrl || packageSourceUrl}</projectUrl>`],
    ...(dependencies && dependencies.length > 0
      ? [[/<dependencies \/>/, buildDependenciesXml(dependencies)]]
      : []),
  ]);

  await replaceInFile(path.join(targetDir, "metadata.yml"), [
    [/packageId: CHANGE_ME/, `packageId: ${package_id}`],
    [/owner: CHANGE_ME/, `owner: ${owner_team}`],
    [/notes: ""/, `notes: "${description.replace(/"/g, '\\"')}"`],
  ]);

  const effectiveBinaryName = binary_name || package_id;
  if (effectivePackageKind === "portable") {
    // A full overwrite, not the field-by-field replaceInFile used below --
    // found by testing that a portable CLI binary (CodeGraphContext's
    // cgc-windows.exe) has no installer at all, so the installer
    // template's whole shape (Install-ChocolateyPackage, softwareName for
    // an Add/Remove Programs lookup, a silent switch) doesn't apply, not
    // just one or two of its fields. Chocolatey auto-shims any .exe it
    // finds under tools\ onto PATH (see internal/README.md) -- naming the
    // downloaded file after the tool's own real command (binary_name),
    // not necessarily the package id, is what actually determines what a
    // user types to run it day to day.
    await fs.writeFile(
      path.join(targetDir, "tools", "chocolateyinstall.ps1"),
      `$ErrorActionPreference = 'Stop'

$toolsDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
# url/checksum are left empty here on purpose: update.ps1's au_SearchReplace
# fills them in from au_GetLatest's result at update time. Committing this
# file with empty url/checksum is the normal, expected state for an AU
# package — do not fill them in by hand.
$packageArgs = @{
  packageName  = '${package_id}'
  url          = ''
  checksum     = ''
  checksumType = 'sha256'
  # Renames the downloaded binary to this stable filename -- Chocolatey
  # auto-shims any .exe under tools\\ onto PATH, so this is also the
  # command name '${effectiveBinaryName}' users get after install.
  fileFullPath = "$toolsDir\\${effectiveBinaryName}.exe"
}

Get-ChocolateyWebFile @packageArgs
`,
      "utf8"
    );
  } else {
    // fileType/a sensible silentArgs default both need to match whichever
    // file evergreen actually selected (Section 6.8) -- found by testing
    // against a real app (Alacritty) whose preferred variant is an .msi:
    // the template's own fileType='exe'/silentArgs='/S' defaults are both
    // wrong for an MSI (msiexec, not a silent-switch-driven EXE), and
    // nothing was propagating the real Type before this fix, silently
    // generating a package that would try to run an MSI as if it were a
    // self-silencing EXE installer.
    const msiDefaultSilentArgs = evergreenFileType === "msi" ? "/qn /norestart" : null;
    const finalSilentArgs = effectiveSilentArgs || msiDefaultSilentArgs;

    await replaceInFile(path.join(targetDir, "tools", "chocolateyinstall.ps1"), [
      [/packageName\s*= 'CHANGE_ME'/, `packageName    = '${package_id}'`],
      [/softwareName\s*= 'CHANGE_ME\*'/, `softwareName   = '${package_id}*'`],
      ...(evergreenFileType && evergreenFileType !== "exe"
        ? [[/fileType\s*= 'exe'(\s*#[^\n]*)?/, `fileType       = '${evergreenFileType}'`]]
        : []),
      ...(finalSilentArgs ? [[/silentArgs\s*= '\/S'(\s*#[^\n]*)?/, `silentArgs     = '${finalSilentArgs}'`]] : []),
    ]);
  }

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
          ? `reads the latest asset from Nexus generic repo '${nexus_generic_repository}' at '${nexus_generic_path_prefix}' (paywalled-software path — verified against a real Nexus instance, see docs/architecture.md)`
          : usedEvergreen
            ? `seeded from evergreen-api ('${evergreen_app_name}')`
            : evergreenError
              ? `evergreen_app_name given but lookup failed (${evergreenError}) — fell back to the generic placeholder`
              : "generic placeholder — no evergreen_app_name given",
        package_kind: effectivePackageKind,
        binary_name: effectivePackageKind === "portable" ? effectiveBinaryName : undefined,
        file_type: effectivePackageKind === "portable" ? undefined : evergreenFileType || "exe (default)",
        silent_args_source:
          effectivePackageKind === "portable"
            ? "not applicable — portable binary, no installer to run silently, tools/chocolateyinstall.ps1 uses Get-ChocolateyWebFile instead of Install-ChocolateyPackage"
            : effectiveSilentArgs
              ? `${effectiveSilentArgs}${silent_args ? " (explicit)" : ` (from knowledge/${vendor}.yml — write_package_knowledge if this turns out wrong or missing for the next package)`}`
              : evergreenFileType === "msi"
                ? "/qn /norestart (standard MSI default — evergreen's selected variant is an .msi; still verify locally before trusting)"
                : "generic '/S' placeholder — no silent_args given and none recorded in the knowledge base for this vendor",
        nuspec: {
          title: `${effectiveTitle}${title ? " (explicit)" : appIndexEntry ? " (from evergreen's app index)" : " (prettified package_id — pass 'title' explicitly if this doesn't read naturally)"}`,
          authors: `${effectiveVendorName}${vendor_name ? " (explicit)" : appIndexEntry ? " (from evergreen's app index)" : " (fell back to owner_team — pass 'vendor_name' if this software has a different real publisher)"}`,
          projectUrl: effectiveProjectUrl
            ? `${effectiveProjectUrl}${source_url ? " (explicit)" : appIndexEntry ? " (from evergreen's app index)" : ` (from knowledge/${vendor}.yml)`}`
            : `fell back to this package's own packageSourceUrl (${packageSourceUrl}) — not a real vendor page; pass 'source_url' for a real one`,
          tags,
        },
        dependencies:
          dependencies && dependencies.length > 0
            ? `${dependencies.map((d) => `${d.id}${d.version ? ` >= ${d.version}` : ""}`).join(", ")} — carried into the nuspec's <dependencies>, which promotion (Get-PromotionCandidates.ps1) already reads`
            : "none declared",
        still_needs_manual_review: usedNexusGeneric
          ? "update.ps1's au_GetLatest reads from Nexus generic repo — confirm a human has actually uploaded a binary under the given path prefix, that NEXUS_GENERIC_READ_TOKEN (a 'username:password' or Nexus User Token pair) is configured wherever this package's AU update runs, and that the target repository is readable by whatever downloads the returned URL (anonymous read scoped to just this one repository is the tested approach — see docs/architecture.md)."
          : "update.ps1's au_GetLatest — verify the architecture/version-matching logic (and the releases URL/regex, if not evergreen-seeded) against this vendor's real release page before merging.",
      },
      null,
      2
    )
  );
}
