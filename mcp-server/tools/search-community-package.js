import { z } from "zod";
import { textResult } from "../lib/exec.js";
import { resolveLatestVersion } from "../lib/resolve-version.js";

export const name = "search_community_package";

export const config = {
  title: "Search Community Package",
  description:
    "Looks up an exact package id in the Chocolatey Community Repository and returns whether it exists and its latest version. Read-only.",
  inputSchema: {
    package_id: z.string().describe("Exact Chocolatey package id to look up"),
  },
};

export async function handler({ package_id }) {
  let result;
  try {
    result = await resolveLatestVersion(package_id);
  } catch (err) {
    return textResult(String(err.message ?? err), true);
  }

  if (!result) {
    return textResult(JSON.stringify({ found: false, packageId: package_id }, null, 2));
  }

  return textResult(JSON.stringify({ found: true, ...result }, null, 2));
}
