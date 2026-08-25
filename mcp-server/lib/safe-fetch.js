import dns from "node:dns/promises";
import net from "node:net";

/**
 * Blocks SSRF: any tool that fetches a URL a human (or an agent acting on
 * an issue form) supplied, rather than a hardcoded API host this repo
 * already trusts, needs to make sure that URL -- and every redirect it
 * follows -- actually points somewhere public. Without this, a
 * package-request's source_url field reaching a plain fetch() is a
 * textbook SSRF: point it at http://169.254.169.254/ (cloud instance
 * metadata) or http://localhost:<internal-port>/ and the runner fetches
 * it on the requester's behalf. Confirmed by real testing (see PR #88's
 * review) that Node's own fetch()  follows redirects by default even
 * when the original URL was already validated -- a public URL can still
 * 302 to an internal one, so this has to check every hop, not just the
 * first.
 *
 * HTTPS-only, not http+https: every real vendor download page this repo
 * has dealt with is HTTPS already, and dropping plain HTTP removes an
 * entire class of on-path tampering for free.
 */

const MAX_REDIRECTS = 5;

function ipToUint32(parts) {
  return parts.reduce((acc, part) => (acc << 8) + part, 0) >>> 0;
}

/** IPv4 ranges that never point at a legitimate public vendor server:
 * loopback, RFC 1918 private space, link-local (includes the
 * 169.254.169.254 cloud-metadata address most SSRF exploits actually
 * want), carrier-grade NAT, multicast, and the various reserved/
 * documentation-only blocks. */
const BLOCKED_IPV4_RANGES = [
  ["0.0.0.0", 8],
  ["10.0.0.0", 8],
  ["100.64.0.0", 10],
  ["127.0.0.0", 8],
  ["169.254.0.0", 16],
  ["172.16.0.0", 12],
  ["192.0.0.0", 24],
  ["192.0.2.0", 24],
  ["192.168.0.0", 16],
  ["198.18.0.0", 15],
  ["198.51.100.0", 24],
  ["203.0.113.0", 24],
  ["224.0.0.0", 4],
  ["240.0.0.0", 4],
];

function isBlockedIPv4(address) {
  const parts = address.split(".").map(Number);
  if (parts.length !== 4 || parts.some((p) => Number.isNaN(p))) return true; // malformed -- fail closed
  const value = ipToUint32(parts);
  return BLOCKED_IPV4_RANGES.some(([base, prefix]) => {
    const baseValue = ipToUint32(base.split(".").map(Number));
    const mask = prefix === 0 ? 0 : (0xffffffff << (32 - prefix)) >>> 0;
    return (value & mask) === (baseValue & mask);
  });
}

/** IPv6: loopback, unspecified, unique-local (fc00::/7, the private-
 * network equivalent), link-local (fe80::/10), and multicast (ff00::/8)
 * -- plus unwrapping an IPv4-mapped address (::ffff:a.b.c.d) to run the
 * same IPv4 check against it, since that mapping is exactly how an IPv4
 * private target can hide inside a technically-IPv6 literal. */
function isBlockedIPv6(address) {
  const normalized = address.toLowerCase();
  if (normalized === "::1" || normalized === "::") return true;
  const mapped = normalized.match(/^::ffff:(\d+\.\d+\.\d+\.\d+)$/);
  if (mapped) return isBlockedIPv4(mapped[1]);
  const firstGroup = normalized.split(":")[0];
  const firstHextet = parseInt(firstGroup || "0", 16) || 0;
  if ((firstHextet & 0xfe00) === 0xfc00) return true; // fc00::/7
  if ((firstHextet & 0xffc0) === 0xfe80) return true; // fe80::/10
  if ((firstHextet & 0xff00) === 0xff00) return true; // ff00::/8
  return false;
}

function isBlockedAddress(address) {
  return net.isIP(address) === 6 ? isBlockedIPv6(address) : isBlockedIPv4(address);
}

async function assertPublicHttpsUrl(urlString) {
  let url;
  try {
    url = new URL(urlString);
  } catch {
    throw new Error(`'${urlString}' is not a valid URL.`);
  }
  if (url.protocol !== "https:") {
    throw new Error(`'${urlString}' must be https:// -- refusing to fetch a non-HTTPS URL.`);
  }
  let addresses;
  try {
    addresses = await dns.lookup(url.hostname, { all: true, verbatim: true });
  } catch (err) {
    throw new Error(`Could not resolve '${url.hostname}': ${err.message}`);
  }
  if (addresses.length === 0 || addresses.some((a) => isBlockedAddress(a.address))) {
    throw new Error(
      `'${url.hostname}' resolves to a private, loopback, link-local, multicast, or reserved address -- refusing to fetch it.`
    );
  }
  return url;
}

/**
 * Fetches a fully user/agent-supplied URL safely: HTTPS only, every
 * hostname (the original URL and every redirect target) resolved and
 * checked against public-address space before connecting, redirects
 * followed manually up to MAX_REDIRECTS rather than left to fetch()'s
 * own default (which offers no hook to validate a hop before following
 * it).
 */
export async function safeFetchText(urlString) {
  const USER_AGENT = "chocolatey-packages-mcp-server/1.0 (+https://github.com/patsaindon/chocolatey-packages)";
  let currentUrl = urlString;
  for (let redirectCount = 0; redirectCount <= MAX_REDIRECTS; redirectCount++) {
    const url = await assertPublicHttpsUrl(currentUrl);
    const res = await fetch(url, { headers: { "User-Agent": USER_AGENT }, redirect: "manual" });
    if (res.status >= 300 && res.status < 400 && res.headers.get("location")) {
      currentUrl = new URL(res.headers.get("location"), url).toString();
      continue;
    }
    const text = await res.text();
    return { ok: res.ok, status: res.status, text, finalUrl: url.toString() };
  }
  throw new Error(`Too many redirects (>${MAX_REDIRECTS}) fetching '${urlString}'.`);
}
