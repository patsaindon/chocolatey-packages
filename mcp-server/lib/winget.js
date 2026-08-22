import { run } from "./exec.js";

const USER_AGENT = "chocolatey-packages-mcp-server/1.0 (+https://github.com/patsaindon/chocolatey-packages)";
const WINGET_PKGS_API = "https://api.github.com/repos/microsoft/winget-pkgs";

// A winget id is Publisher.Package(.More), at least one dot -- but real
// ids aren't limited to letters/digits/dot/hyphen the way a first version
// of this pattern assumed: found by testing a real package (Notepad++'s
// own id is literally 'Notepad++.Notepad++') that a plain `+` sign is a
// real, unremarkable character in a real id, not an edge case. Exported
// so both this file's own row-validation and the tool's "does this query
// already look like an exact id" check use the same definition instead of
// two copies quietly drifting apart, which is exactly how this bug
// happened the first time.
export const WINGET_ID_PATTERN = /^[\w+-]+(\.[\w+-]+)+$/;

function githubHeaders() {
  const headers = { "User-Agent": USER_AGENT };
  const token = process.env.GH_TOKEN || process.env.GITHUB_TOKEN;
  if (token) headers.Authorization = `Bearer ${token}`;
  return headers;
}

/**
 * Parses `winget search <term>` table output into candidate rows,
 * splitting each data line on runs of 2+ spaces (winget's own column
 * padding) rather than depending on locale-specific header text -- found
 * by testing that this runner's own winget reports in French ("Nom",
 * "ID", "Correspondance"), so parsing by header label would break here
 * and might break differently elsewhere. IDs and versions are never
 * translated regardless of locale, only the header/label text is.
 */
export async function searchWinget(term) {
  const result = await run("winget", ["search", term, "--source", "winget"]);
  if (result.code !== 0) return [];

  const lines = result.stdout.split(/\r?\n/);
  const separatorIndex = lines.findIndex((l) => /^-{5,}/.test(l.trim()));
  if (separatorIndex === -1) return [];

  const rows = [];
  for (const line of lines.slice(separatorIndex + 1)) {
    if (!line.trim()) continue;
    const cells = line.trim().split(/\s{2,}/);
    if (cells.length < 3) continue;
    const [name, id, version] = cells;
    // Used to distinguish the id cell from the name/version/match cells
    // without relying on column position, in case a locale reorders them.
    if (!WINGET_ID_PATTERN.test(id)) continue;
    rows.push({ name, id, version });
  }
  return rows;
}

/**
 * Latest version string for an exact winget package id -- confirmed by
 * testing that `winget show --versions` lists newest-first, so the first
 * non-empty data line after the header separator is the latest. Parsed
 * the same locale-independent way as searchWinget: by position relative
 * to the dashed separator line, never by a label's text.
 */
export async function getLatestWingetVersion(id) {
  const result = await run("winget", ["show", "--id", id, "--exact", "--versions"]);
  if (result.code !== 0) return null;

  const lines = result.stdout.split(/\r?\n/);
  const separatorIndex = lines.findIndex((l) => /^-{3,}/.test(l.trim()));
  if (separatorIndex === -1) return null;

  for (const line of lines.slice(separatorIndex + 1)) {
    const trimmed = line.trim();
    if (trimmed) return trimmed;
  }
  return null;
}

/** manifests/<first-char-lowercased>/<Publisher>/<Package>/<version> --
 * confirmed by testing against two real ids with a different number of
 * dot-segments (7zip.7zip -> manifests/7/7zip/7zip; Microsoft.
 * VisualStudioCode -> manifests/m/Microsoft/VisualStudioCode). */
export function wingetManifestPath(id, version) {
  return `manifests/${id[0].toLowerCase()}/${id.split(".").join("/")}/${version}`;
}

/** Lists a manifest version folder's files via GitHub's Contents API
 * (not the Search API -- confirmed by testing that unauthenticated code
 * search on this repo returns 401, while authenticated code search
 * against a path: filter returned zero results even for a package known
 * to exist; the Contents API, the same mechanism
 * Draft-CommunityPackageUpdate.ps1 already uses against Chocolatey's own
 * Community package sources, just works). Auth is optional -- adds a
 * GH_TOKEN/GITHUB_TOKEN bearer header when present (raises the rate
 * limit) but unauthenticated requests work too, same as
 * get_community_package_tools' GitHub calls. */
export async function listWingetManifestFiles(path) {
  const res = await fetch(`${WINGET_PKGS_API}/contents/${path}`, { headers: githubHeaders() });
  if (!res.ok) return null;
  return res.json();
}

export async function fetchWingetFile(downloadUrl) {
  const res = await fetch(downloadUrl, { headers: githubHeaders() });
  if (!res.ok) return null;
  return res.text();
}
