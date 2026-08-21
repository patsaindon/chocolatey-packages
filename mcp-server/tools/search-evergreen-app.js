import { z } from "zod";
import { httpGetJson } from "../lib/http-get.js";
import { textResult } from "../lib/exec.js";

const EVERGREEN_APPS_URL = "https://evergreen-api.stealthpuppy.com/apps";

export const name = "search_evergreen_app";

export const config = {
  title: "Search Evergreen App",
  description:
    "Searches the evergreen-api.stealthpuppy.com app index (https://eucpilots.com/evergreen/api/) for apps whose name matches the query, for use when authoring an internal AU package's au_GetLatest. Read-only. Follow up with get_evergreen_app_info using the exact 'name' field from a match.",
  inputSchema: {
    query: z.string().describe("Substring to search for, e.g. 'temurin', '7zip', 'firefox'"),
  },
};

export async function handler({ query }) {
  const { ok, status, data } = await httpGetJson(EVERGREEN_APPS_URL);
  if (!ok || !Array.isArray(data)) {
    return textResult(`Failed to fetch the evergreen app index (status ${status}).`, true);
  }

  const q = query.toLowerCase();
  const matches = data
    .filter((app) => app.Name?.toLowerCase().includes(q) || app.Application?.toLowerCase().includes(q))
    .slice(0, 20)
    .map((app) => ({ name: app.Name, application: app.Application, link: app.Link }));

  return textResult(JSON.stringify({ query, count: matches.length, matches }, null, 2));
}
