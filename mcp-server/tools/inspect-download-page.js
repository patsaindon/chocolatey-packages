import { z } from "zod";
import { safeFetchText } from "../lib/safe-fetch.js";
import { textResult } from "../lib/exec.js";

export const name = "inspect_download_page";

// Common real-world installer/archive extensions seen across this repo's
// already-onboarded packages (.exe, .msi) plus a few more that show up on
// vendor download pages generally (.msix/.msixbundle -- WSL; .zip -- a
// portable tool shipped as an archive rather than an installer). Kept as
// a real, bounded allowlist rather than "any href" -- a download page
// links to plenty of things (privacy policy, other products, social
// media) that would just be noise for this tool's one purpose.
const ASSET_EXTENSION_PATTERN = /\.(exe|msi|msix|msixbundle|zip)(?:[?#]|$)/i;

export const config = {
  title: "Inspect Download Page",
  description:
    "Fetches a vendor download/release page's real HTML (no JavaScript execution -- a page whose real download links only appear after client-side rendering will come back with zero matches, same limitation as this repo's earlier GitHub-HTML-scrape attempts, see scaffold_internal_package's own buildGitHubReleasesGetLatest doc comment for that history) and returns every link on it whose href looks like a real installer/archive (.exe/.msi/.msix/.msixbundle/.zip), plus the page's own visible text (scripts/styles stripped, truncated) so version numbers or dates sitting next to a link are still readable. This is the tool to reach for when a package has no evergreen-api coverage and its source_url isn't a github.com repo -- read the returned links and text yourself, work out the real filename/URL pattern this vendor uses across versions (a single page snapshot is one data point, not a history -- treat an inferred pattern as a hypothesis, not a confirmed fact), and pass what you found to scaffold_internal_package's au_getlatest_page_url/au_getlatest_link_pattern parameters instead of leaving it as an unfilled placeholder. Always say in the PR body that this came from reading one page, not a vendor API, and still needs a human to confirm it holds across a real future version bump. HTTPS only, and refuses to fetch (or follow a redirect to) a private/loopback/link-local/reserved address -- a plain-HTTP-only vendor page or one that bounces through an internal host will fail with an explicit error rather than being fetched anyway; that's expected, not a bug to work around. Read-only -- fetches the given URL (and validates each redirect) only, writes nothing.",
  inputSchema: {
    url: z.string().url().describe("The vendor's download or release page URL (typically the package request's own source_url)"),
  },
};

function extractTitle(html) {
  const match = html.match(/<title[^>]*>([\s\S]*?)<\/title>/i);
  return match ? decodeEntities(match[1]).trim() : null;
}

function decodeEntities(text) {
  return text
    .replace(/&amp;/g, "&")
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&quot;/g, '"')
    .replace(/&#0?39;/g, "'")
    .replace(/&nbsp;/g, " ");
}

function extractLinks(html, baseUrl) {
  const links = [];
  const seen = new Set();
  const anchorPattern = /<a\b[^>]*\bhref\s*=\s*["']([^"']+)["'][^>]*>([\s\S]*?)<\/a>/gi;
  let match;
  while ((match = anchorPattern.exec(html))) {
    const [, href, innerHtml] = match;
    if (!ASSET_EXTENSION_PATTERN.test(href)) continue;
    let absolute;
    try {
      // href comes straight from raw HTML source, where a literal '&' in a
      // real query string is legally written as '&amp;' -- decode before
      // resolving, or a signed/tokenized download URL's query string comes
      // out corrupted (confirmed by testing: '&amp;' left undecoded stays
      // a literal 4-character substring instead of becoming '&').
      absolute = new URL(decodeEntities(href), baseUrl).toString();
    } catch {
      continue;
    }
    if (seen.has(absolute)) continue;
    seen.add(absolute);
    const text = decodeEntities(innerHtml.replace(/<[^>]+>/g, " ").replace(/\s+/g, " ")).trim();
    links.push({ href: absolute, text: text || null });
  }
  return links;
}

function extractTextExcerpt(html, maxLength = 4000) {
  const withoutScripts = html
    .replace(/<script[\s\S]*?<\/script>/gi, " ")
    .replace(/<style[\s\S]*?<\/style>/gi, " ");
  const text = decodeEntities(withoutScripts.replace(/<[^>]+>/g, " "))
    .replace(/[ \t]+/g, " ")
    .replace(/\n\s*\n+/g, "\n")
    .trim();
  return text.length > maxLength ? `${text.slice(0, maxLength)}\n... (truncated)` : text;
}

export async function handler({ url }) {
  let fetched;
  try {
    fetched = await safeFetchText(url);
  } catch (err) {
    return textResult(`Failed to fetch '${url}': ${err.message}`, true);
  }
  if (!fetched.ok) {
    return textResult(`Fetching '${url}' failed: HTTP ${fetched.status}.`, true);
  }

  // Relative links resolve against wherever the page actually ended up
  // (fetched.finalUrl) after any redirects, not the URL originally
  // requested -- a redirect to a different path/host would otherwise
  // resolve a relative href against the wrong base.
  const links = extractLinks(fetched.text, fetched.finalUrl);
  return textResult(
    JSON.stringify(
      {
        url,
        title: extractTitle(fetched.text),
        assetLinks: links,
        note:
          links.length === 0
            ? "No .exe/.msi/.msix/.msixbundle/.zip links found in the static HTML -- this page may render its real download links via client-side JavaScript (common on modern vendor sites), which this tool can't execute. Check textExcerpt for a 'latest'/'download' alias URL instead, or fall back to the generic placeholder and flag it for human research."
            : `${links.length} candidate asset link(s) found -- read their href/text below and, if a second real version isn't visible on this one page to compare against, treat any inferred version-position pattern as an untested hypothesis.`,
        textExcerpt: extractTextExcerpt(fetched.text),
      },
      null,
      2
    )
  );
}
