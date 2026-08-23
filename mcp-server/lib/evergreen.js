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
 *
 * Also filters by InstallerType vs. the requested packageKind ('installer'
 * or 'portable') when both exist — found by testing against real evergreen
 * data for Alacritty, which publishes *both* a real installer
 * (InstallerType 'Default', an .msi) and a portable single-binary variant
 * (InstallerType 'Portable', an .exe) side by side, with Portable listed
 * *first*. Picking pool[0] blindly would hand an 'installer'-kind package
 * (the default) a binary with no install wizard to silently run at all —
 * the exact bug already found and fixed for CodeGraphContext via
 * package_kind, resurfacing here through the evergreen path instead of a
 * prospecting one. Most apps only publish one InstallerType, so this is a
 * no-op for them.
 */
export function pickPreferredVariant(variants, { imageType, packageKind } = {}) {
  // x64, then x86, then whatever's left -- found by testing against real
  // data for Rufus, which publishes no x64 variant at all (only ARM64 and
  // several x86 builds). The original fallback ("x64, else everything
  // unfiltered") would silently hand back whichever variant happened to
  // be listed first among ALL architectures once x64 was absent -- for
  // Rufus that's the ARM64 build, which wouldn't run at all on the
  // Intel/AMD endpoints the vast majority of a typical fleet actually
  // has. x86 is the much safer broad-compatibility fallback (it runs
  // everywhere x64 does too), so it's tried before falling through to
  // whatever architecture-specific builds remain (ARM64 and similar).
  let pool = variants;
  for (const arch of ["x64", "x86"]) {
    const matches = variants.filter((v) => v.Architecture?.toLowerCase() === arch);
    if (matches.length > 0) {
      pool = matches;
      break;
    }
  }

  const wantsPortable = packageKind === "portable";
  const matchingKind = pool.filter((v) =>
    wantsPortable ? v.InstallerType?.toLowerCase() === "portable" : v.InstallerType?.toLowerCase() !== "portable"
  );
  if (matchingKind.length > 0) pool = matchingKind;

  if (imageType) {
    const explicit = pool.find((v) => v.ImageType?.toLowerCase() === imageType.toLowerCase());
    if (explicit) return explicit;
  }

  const jdk = pool.find((v) => v.ImageType?.toLowerCase() === "jdk");
  if (jdk) return jdk;

  return pool[0];
}
