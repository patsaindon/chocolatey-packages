# knowledge/

One file per vendor/product family: `<vendor>.yml`, a flat `key: value`
list of facts already confirmed while onboarding or updating a package
sourced from that vendor — checksum field names, image-type/architecture
defaults, version-format quirks, known-good silent-install switches, plus
free-form `notes` and a `last_verified`/`last_verified_via` stamp. Same
flat-YAML convention as `metadata.yml` elsewhere in this repo (see
`scripts/lib/SimpleYaml.ps1`) — no lists, no nested maps, deliberately
simple so a file stays readable in a plain PR diff.

**`product_description`** — a real, one-or-two-sentence description of
what this vendor's software actually *does*, distinct from any package's
own packaging-rationale `notes` (why this package exists, which
issue/PR, staleness numbers). Found the same way as the binary facts
below: most `internal/*/*.nuspec` files onboarded before this had their
`<description>` — shown to anyone browsing or installing the package —
literally reading as packaging trivia ("Surfaced by the version-mismatch
triage of prospecting/community-version-reference.csv...") because
`scaffold_internal_package` only ever had one field doing double duty as
both. `scaffold_internal_package`'s own `vendor` parameter now reads
`product_description` back automatically for its `description`
parameter, the same way it already does for `silent_args`/`source_url` —
worth recording once so the next package from the same vendor doesn't
need its description rewritten from scratch (most useful for a vendor
family like Adoptium/LibreOffice where multiple internal packages share
the same underlying product).

**Standard field names for the binary itself** — found by auditing every
vendor file to date: this information was already being discovered and
written down for each vendor (which installer format it ships, which
framework built it, how sure we are of the silent switch), but almost
every file before this buried it as free prose inside `notes` instead of
a consistent field, which makes it easy to find by reading one file and
impossible to grep/compare across all of them. Record these alongside
`silent_args`/`source_url` whenever the discovery chain in
`handle-package-request.yml` (or a human, on review) establishes them —
`notes` still carries the free-form "how we know this" story, these are
just its structured summary:

| Field | Values | Meaning |
|---|---|---|
| `installer_type` | `msi` / `exe` / `portable` | What `chocolateyinstall.ps1`'s `fileType` (or `package_kind`) should be — a portable binary has no installer at all, confirmed by testing that running one through the installer path hangs or behaves unpredictably (see `handle-package-request.yml`). |
| `installer_framework` | `MSI` / `NSIS` / `WiX` / `InstallShield` / `none` | The installer-building toolkit, when known — `none` for `portable`. `MSI` alone (not `WiX`) means it's a real Windows Installer package but the specific authoring tool wasn't identified; `WiX` means `get_installer_signals` (or direct inspection) found WiX-specific markers (e.g. `WixUI` properties) in the MSI's own tables. |
| `silent_args_source` | `winget` / `community_script` / `installer_signals` / `catalog_search` / `generic_default` | Where `silent_args` actually came from — mirrors the discovery chain's own trust tiers in `handle-package-request.yml`: `winget`/`community_script` read a real, working source; `installer_signals` is a framework-typical guess from the file itself (an MSI's own `RecommendedCommandLine` property is stronger evidence than a bare NSIS/WiX fingerprint, but still not execution-tested); `catalog_search` is a best-effort snapshot-page match (see `prospecting/README.md`'s own caveat on this same tier for `search_silent_install_switch`); `generic_default` means nothing vendor-specific was found and `scaffold_internal_package`'s own framework-generic fallback was used as-is. |
| `silent_args_verified` | `true` / `false` | Whether a human has actually run the installer unattended locally (`scripts/New-SilentTestKit.ps1`, `docs/silent-switch-verification.md`) and confirmed `silent_args` really works — as opposed to just being sourced from somewhere plausible. Every file recorded before this had this at `false` in practice (none had been through that check yet) — flip to `true` only after someone actually does it, and say so in `notes`/`last_verified_via`. |

Omit `installer_framework`/`silent_args_source`/`silent_args_verified`
entirely for a `portable` vendor — there's no installer and no silent
switch to source or verify.

The package-request agent (`.github/workflows/handle-package-request.yml`)
calls `lookup_package_knowledge` before scaffolding a package, so an
already-solved quirk (e.g. "this vendor's evergreen-api entries use
`Checksum`, not `Sha256`") isn't rediscovered by trial and error on the
next package from the same vendor. When it learns something new or
corrects something here, it calls `write_package_knowledge` — which only
writes to the local working tree — and includes the file in the same PR
`open_pull_request` opens for the package itself. **A human reviews every
change here exactly like a code change; the agent never commits or
pushes to this directory on its own.** See `docs/architecture.md` section
6.8.

Vendor slugs are freeform (the agent picks one, e.g. `adoptium`) — reuse
the same slug across every package from that vendor so knowledge
accumulates under it instead of scattering across near-duplicate files.
