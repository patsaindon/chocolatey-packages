import { httpGetJson } from "./http-get.js";

const EVERGREEN_APPS_URL = "https://evergreen-api.stealthpuppy.com/apps";
const EVERGREEN_APP_URL = "https://evergreen-api.stealthpuppy.com/app";

/**
 * Looks up one entry in evergreen's /apps index by its exact 'Name' (the
 * same field search_evergreen_app matches against) — { Name, Application,
 * Link }, confirmed by testing against a real entry (AdoptiumTemurin25 ->
 * Application "Adoptium Temurin 25", Link "https://adoptium.net/"). Used
 * by scaffold_internal_package to seed a real nuspec <title>/<projectUrl>
 * instead of leaving them as the package id / empty — this data was
 * already being fetched by search_evergreen_app and then discarded.
 * Returns null if nothing matches (caller falls back to its own default).
 */
export async function fetchEvergreenAppIndexEntry(name) {
  const { ok, data } = await httpGetJson(EVERGREEN_APPS_URL);
  if (!ok || !Array.isArray(data)) return null;
  return data.find((app) => app.Name === name) ?? null;
}

/** Shared by get_evergreen_app_info and scaffold_internal_package. */
export async function fetchEvergreenVariants(name) {
  const { ok, status, data } = await httpGetJson(`${EVERGREEN_APP_URL}/${encodeURIComponent(name)}`);
  if (!ok || !Array.isArray(data)) {
    throw new Error(`No evergreen data for '${name}' (status ${status}).`);
  }
  return data;
}

/**
 * Prefers x64. Some apps (JDKs in particular) publish more than one x64
 * variant distinguished only by ImageType (e.g. 'jdk' vs 'jre') — found by
 * testing against a real request for AdoptiumTemurin25, which has exactly
 * two x64 variants and nothing else to tell them apart. Pass imageType to
 * pick explicitly; otherwise defaults to 'jdk' over 'jre' when both exist,
 * since that's almost always what's actually wanted for a package named
 * after the runtime. Apps with no ImageType field at all (most of them)
 * are unaffected either way.
 */
export function pickPreferredVariant(variants, { imageType } = {}) {
  const x64Variants = variants.filter((v) => v.Architecture?.toLowerCase() === "x64");
  const pool = x64Variants.length > 0 ? x64Variants : variants;

  if (imageType) {
    const explicit = pool.find((v) => v.ImageType?.toLowerCase() === imageType.toLowerCase());
    if (explicit) return explicit;
  }

  const jdk = pool.find((v) => v.ImageType?.toLowerCase() === "jdk");
  if (jdk) return jdk;

  return pool[0];
}
