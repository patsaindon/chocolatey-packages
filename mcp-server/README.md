# mcp-server/

An MCP server exposing the tools used to handle package-request Issues (see
[.github/ISSUE_TEMPLATE/package-request.yml](../.github/ISSUE_TEMPLATE/package-request.yml)
and [.github/workflows/handle-package-request.yml](../.github/workflows/handle-package-request.yml)).
Each tool is a thin wrapper around an existing repo script or a small, auditable
file/git operation — no package-management logic is reimplemented here. See
`docs/architecture.md` for how this fits into the overall pipeline.

## Tools

| Tool | Wraps | Write scope |
|---|---|---|
| `search_community_package` | `choco search --exact --limit-output` | none (read-only) |
| `lint_package` | `scripts/lint-nuspec.ps1` | none (read-only) |
| `search_evergreen_app` | [evergreen-api.stealthpuppy.com](https://eucpilots.com/evergreen/api/) `/apps` index | none (read-only) |
| `get_evergreen_app_info` | evergreen-api `/app/{name}` | none (read-only) |
| `get_community_package_tools` | downloads a Community package (read-only, no internalize/push) and returns its real `tools/chocolateyInstall.ps1`/`chocolateyUninstall.ps1`, plus a best-effort `detectedSilentArgs` pulled straight out of the script — tries `<id>.install` automatically if the bare id is a tools-less metapackage, and follows an `Install-VirtualPackage` redirect (preferring whichever target actually has a real `detectedSilentArgs`) if the bare id's own script is just that | none (read-only) |
| `get_winget_package_manifest` | resolves a package against Microsoft's winget-pkgs repo (exact winget id, or a search term with exactly one confident match via `winget search`) and returns its real installer URL/SHA256/silent-install switch per architecture, straight from structured YAML | none (read-only) |
| `download_installer_file` | downloads a direct installer URL (e.g. a `source_url` from the request, or one a discovery tool returned) to a local temp path — the file get_installer_signals needs to analyze, since nothing else in this list produces one | writes only inside the OS temp directory |
| `get_installer_signals` | `scripts/Get-InstallerSignals.ps1` — reads (never executes) a downloaded MSI's real Property table, or an EXE's embedded strings matched against known installer-framework fingerprints (NSIS, Inno Setup, InstallShield, WiX Burn, InstallAware, Squirrel, Advanced Installer), reporting a framework-typical candidate switch. A starting point, not a confirmed answer — see [../docs/silent-switch-verification.md](../docs/silent-switch-verification.md) | none (read-only) |
| `search_silent_install_switch` | [manageengine.com](https://www.manageengine.com/products/desktop-central/software-installation) catalog scrape — best-effort, one snapshot page, not exhaustive | none (read-only) |
| `lookup_package_knowledge` | reads `knowledge/<vendor>.yml` — facts already confirmed about a vendor's packages from an earlier one (checksum field name, image-type default, version quirks, and the standard fields `silent_args`/`source_url`) | none (read-only) |
| `scaffold_internal_package` | copies `internal/_template/`, fills in placeholders; pass `evergreen_app_name` to seed a real `au_GetLatest` instead of a generic placeholder; pass `vendor` (same slug as the two tools above) to auto-fill `silent_args`/`source_url` from `knowledge/<vendor>.yml` when you haven't found a fresher value yourself — an explicit `silent_args`/`source_url` param always wins over the knowledge base. Also seeds the nuspec's `<title>`/`<authors>`/`<projectUrl>`/`<tags>` from evergreen's own app index, or from explicit `title`/`vendor_name`/`source_url` params, instead of leaving them as the bare package id / empty. Pass all three `nexus_generic_base_url`/`nexus_generic_repository`/`nexus_generic_path_prefix` instead, for paywalled software, to generate an `au_GetLatest` that reads the latest binary a human already uploaded to Nexus rather than scraping a vendor page this automation can't log into — see [../scripts/Get-NexusGenericLatestAsset.ps1](../scripts/Get-NexusGenericLatestAsset.ps1) (not yet verified against a real Nexus instance) | local working tree only |
| `write_package_knowledge` | writes/merges `knowledge/<vendor>.yml` with facts learned or corrected this run — always worth calling with `silent_args`/`source_url` once found, so the next package from the same vendor gets them automatically via `scaffold_internal_package`'s `vendor` param | local working tree only — never commits or pushes; the agent is expected to hand the file to `open_pull_request` alongside the package it came from, so a human reviews it in the same PR |
| `bootstrap_internalize_package` | `choco download --internalize` → `scripts/scan-package.ps1` → `choco push` | **staging feed only** — requires `STAGING_FEED_URL`/`STAGING_API_KEY` in the server's environment; refuses to run without them, and never receives production credentials |
| `open_pull_request` | `git`/`gh` | opens a PR against `main`; never merges |

See [../knowledge/README.md](../knowledge/README.md) for the `knowledge/<vendor>.yml` file format and why it exists — in short, `temurin17` and `temurin25` each independently hit the same vendor-specific quirks (checksum field name, `jdk`/`jre` disambiguation, version sanitization), with nothing carrying the finding from one to the next. This closes that gap without giving the agent an unreviewed way to change its own beliefs about a vendor.

## Running it standalone

```powershell
cd mcp-server
npm ci
node index.js
```

It speaks MCP over stdio — point an MCP client (Claude Code, the MCP
Inspector, etc.) at `node mcp-server/index.js` from the repo root, or use
[mcp-config.json](mcp-config.json) directly:

```
npx @modelcontextprotocol/inspector node mcp-server/index.js
```

## Environment variables

- `STAGING_FEED_URL`, `STAGING_API_KEY` — required only for `bootstrap_internalize_package`.
- `GH_TOKEN` (or `GITHUB_TOKEN`) — required only for `open_pull_request`.

Neither is required to run `search_community_package` or `lint_package` — both tools refuse cleanly with a clear message if their required variables are missing, rather than failing halfway through.
