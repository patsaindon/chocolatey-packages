import { z } from "zod";
import { textResult } from "../lib/exec.js";
import { searchWinget, getLatestWingetVersion, wingetManifestPath, listWingetManifestFiles, fetchWingetFile } from "../lib/winget.js";

export const name = "get_winget_package_manifest";

export const config = {
  title: "Get Winget Package Manifest",
  description:
    "Looks up a package in Microsoft's winget-pkgs manifest repository (read-only, public data) and returns its real installer URL(s), SHA256 checksum(s), and silent-install switch per architecture, straight from structured YAML -- not a scrape or a guess. Complements search_silent_install_switch/get_community_package_tools: winget-pkgs' own InstallerSwitches.Silent field is the most reliable silent-switch source of the three when the package is covered there (confirmed against a real package: 7zip.7zip's manifest gives 'Silent: /S' directly, plus a real InstallerUrl/InstallerSha256 per architecture). Pass an exact winget id (e.g. '7zip.7zip', Publisher.Package) if you already know it; otherwise pass a search term and the single confident match is resolved automatically via `winget search` -- multiple or no matches are reported as such, never guessed.",
  inputSchema: {
    query: z.string().describe("An exact winget package id ('7zip.7zip') or a search term ('7-Zip', 'Visual Studio Code') to resolve one from"),
  },
};

const WINGET_ID_PATTERN = /^[A-Za-z0-9][A-Za-z0-9.\-]*\.[A-Za-z0-9][A-Za-z0-9.\-]*$/;

export async function handler({ query }) {
  let id = query;
  let version = WINGET_ID_PATTERN.test(query) ? await getLatestWingetVersion(query) : null;

  if (!version) {
    const matches = await searchWinget(query);
    if (matches.length === 0) {
      return textResult(`No winget package found for '${query}'.`, true);
    }
    if (matches.length > 1) {
      return textResult(
        `'${query}' matched ${matches.length} winget packages, not a confident single one -- pass the exact id instead:\n` +
          matches.map((m) => `  - ${m.id} (${m.name}, ${m.version})`).join("\n"),
        true
      );
    }
    id = matches[0].id;
    version = await getLatestWingetVersion(id);
    if (!version) {
      return textResult(`Found winget id '${id}' via search but couldn't resolve its latest version.`, true);
    }
  }

  const manifestPath = wingetManifestPath(id, version);
  const entries = await listWingetManifestFiles(manifestPath);
  if (!entries) {
    return textResult(`Couldn't list '${manifestPath}' in microsoft/winget-pkgs for '${id}' ${version}.`, true);
  }

  const installerEntry = Array.isArray(entries)
    ? entries.find((e) => e.name.toLowerCase() === `${id.toLowerCase()}.installer.yaml`)
    : null;
  if (!installerEntry) {
    return textResult(`No installer manifest file found under '${manifestPath}' for '${id}'.`, true);
  }

  const yamlText = await fetchWingetFile(installerEntry.download_url);
  if (!yamlText) {
    return textResult(`Found '${installerEntry.name}' but couldn't download it from GitHub.`, true);
  }

  return textResult(
    JSON.stringify(
      { id, version, manifestUrl: installerEntry.html_url, installerManifestYaml: yamlText },
      null,
      2
    )
  );
}
