import { httpGetJson } from "./http-get.js";

const EVERGREEN_APP_URL = "https://evergreen-api.stealthpuppy.com/app";

/** Shared by get_evergreen_app_info and scaffold_internal_package. */
export async function fetchEvergreenVariants(name) {
  const { ok, status, data } = await httpGetJson(`${EVERGREEN_APP_URL}/${encodeURIComponent(name)}`);
  if (!ok || !Array.isArray(data)) {
    throw new Error(`No evergreen data for '${name}' (status ${status}).`);
  }
  return data;
}

/** Prefers x64, falls back to whatever's first if no x64 variant exists. */
export function pickPreferredVariant(variants) {
  const x64 = variants.find((v) => v.Architecture?.toLowerCase() === "x64");
  return x64 ?? variants[0];
}
