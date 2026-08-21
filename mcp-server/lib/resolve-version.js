import { run } from "./exec.js";

export const COMMUNITY_SOURCE = "https://community.chocolatey.org/api/v2/";

/** Shared by search_community_package and bootstrap_internalize_package. */
export async function resolveLatestVersion(packageId) {
  const { code, stdout, stderr } = await run("choco", [
    "search",
    packageId,
    "--exact",
    `--source=${COMMUNITY_SOURCE}`,
    "--limit-output",
  ]);

  if (code !== 0) {
    throw new Error(`choco search failed (exit ${code}): ${stderr || stdout}`);
  }

  const line = stdout.split(/\r?\n/).find((l) => l.trim().length > 0);
  if (!line) {
    return null;
  }

  const [id, version] = line.split("|");
  return { packageId: id, version };
}
