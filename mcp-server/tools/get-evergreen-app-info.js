import { z } from "zod";
import { fetchEvergreenVariants } from "../lib/evergreen.js";
import { textResult } from "../lib/exec.js";

export const name = "get_evergreen_app_info";

export const config = {
  title: "Get Evergreen App Info",
  description:
    "Fetches release variants (version, download URL, checksum, architecture, file type — field names vary a little app to app) for one app from evergreen-api.stealthpuppy.com, given the exact 'name' from search_evergreen_app. Returns every variant (per architecture/installer type) — pick the one matching what the package needs (e.g. x64 + msi) when writing au_GetLatest. Read-only.",
  inputSchema: {
    name: z.string().describe("Exact app name from search_evergreen_app, e.g. 'AdoptiumTemurin17'"),
  },
};

export async function handler({ name }) {
  let variants;
  try {
    variants = await fetchEvergreenVariants(name);
  } catch (err) {
    return textResult(`${err.message} Double check the exact name via search_evergreen_app.`, true);
  }
  return textResult(JSON.stringify(variants, null, 2));
}
