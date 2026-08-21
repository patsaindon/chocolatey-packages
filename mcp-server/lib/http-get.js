/**
 * Both evergreen-api.stealthpuppy.com and manageengine.com block requests
 * without a browser-like User-Agent (confirmed: curl with no UA got a
 * Cloudflare block from evergreen-api; a default one worked for both once
 * set). Node's built-in fetch (global since Node 18) is enough — no extra
 * HTTP dependency needed.
 */
const USER_AGENT = "chocolatey-packages-mcp-server/1.0 (+https://github.com/patsaindon/chocolatey-packages)";

export async function httpGetText(url) {
  const res = await fetch(url, { headers: { "User-Agent": USER_AGENT } });
  const text = await res.text();
  return { ok: res.ok, status: res.status, text };
}

export async function httpGetJson(url) {
  const { ok, status, text } = await httpGetText(url);
  if (!ok) {
    return { ok, status, data: null, raw: text };
  }
  try {
    return { ok, status, data: JSON.parse(text), raw: text };
  } catch {
    return { ok: false, status, data: null, raw: text };
  }
}
