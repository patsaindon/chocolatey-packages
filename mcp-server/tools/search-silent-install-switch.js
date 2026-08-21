import { z } from "zod";
import { httpGetText } from "../lib/http-get.js";
import { textResult } from "../lib/exec.js";

const BASE_URL = "https://www.manageengine.com/products/desktop-central/software-installation/";
const CATALOG_URL = `${BASE_URL}windows-software.html`;

function extractField(html, label) {
  const re = new RegExp(`<b>${label}\\s*</b></td><td>([^<]*)</td>`, "i");
  return html.match(re)?.[1]?.trim() ?? null;
}

// ManageEngine's own naming isn't consistent about separators — found by
// testing: "7-Zip" (a reasonable query) doesn't substring-match the
// catalog's actual label "7 Zip (x64) (26.02)" (a space, not a hyphen).
// Stripping everything but letters/digits before comparing makes "7-Zip",
// "7zip", and "7 Zip" all match each other.
function normalize(s) {
  return s.toLowerCase().replace(/[^a-z0-9]/g, "");
}

export const name = "search_silent_install_switch";

export const config = {
  title: "Search Silent Install Switch",
  description:
    "Best-effort search of ManageEngine's public silent-install-switch reference (manageengine.com/products/desktop-central/software-installation) for an app name, for use when filling in an internal AU package's silentArgs. ManageEngine has no search API — this only scans one catalog snapshot page (a few thousand entries, not exhaustive), so a miss here does NOT mean no silent switch exists; it may just not be on this page. Read-only.",
  inputSchema: {
    query: z.string().describe("App name to search for, e.g. '7-Zip', 'Notepad++'"),
  },
};

export async function handler({ query }) {
  const catalog = await httpGetText(CATALOG_URL);
  if (!catalog.ok) {
    return textResult(`Failed to fetch the ManageEngine catalog page (status ${catalog.status}).`, true);
  }

  const rowRe = /<a href="(silent_install_[^"]+\.html)"[^>]*>([^<]+)<\/a>/gi;
  const q = normalize(query);
  const matches = [];
  for (const m of catalog.text.matchAll(rowRe)) {
    const [, href, label] = m;
    if (normalize(label).includes(q)) matches.push({ href, label: label.trim() });
  }

  if (matches.length === 0) {
    return textResult(
      JSON.stringify(
        {
          query,
          found: false,
          note: "No match on this one catalog snapshot page — not exhaustive. Absence here doesn't confirm no silent switch exists; a general web search may still find it.",
        },
        null,
        2
      )
    );
  }

  const results = [];
  for (const match of matches.slice(0, 5)) {
    const detail = await httpGetText(`${BASE_URL}${match.href}`);
    if (!detail.ok) continue;
    results.push({
      label: match.label,
      softwareName: extractField(detail.text, "Software Name"),
      version: extractField(detail.text, "Version"),
      architecture: extractField(detail.text, "Architecture"),
      silentInstallSwitch: extractField(detail.text, "Silent Installation Switch"),
      silentUninstallSwitch: extractField(detail.text, "Silent Uninstallation Switch"),
    });
  }

  return textResult(
    JSON.stringify(
      {
        query,
        found: true,
        matchCount: matches.length,
        results,
        note:
          matches.length > results.length
            ? `${matches.length} matches found; showing the first ${results.length}.`
            : undefined,
      },
      null,
      2
    )
  );
}
