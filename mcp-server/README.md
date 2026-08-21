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
| `search_silent_install_switch` | [manageengine.com](https://www.manageengine.com/products/desktop-central/software-installation) catalog scrape — best-effort, one snapshot page, not exhaustive | none (read-only) |
| `lookup_package_knowledge` | reads `knowledge/<vendor>.yml` — facts already confirmed about a vendor's packages from an earlier one (checksum field name, image-type default, version quirks, silent switch) | none (read-only) |
| `scaffold_internal_package` | copies `internal/_template/`, fills in placeholders; pass `evergreen_app_name`/`silent_args` (from the tools above) to seed a real `au_GetLatest`/silent switch instead of a generic placeholder | local working tree only |
| `write_package_knowledge` | writes/merges `knowledge/<vendor>.yml` with facts learned or corrected this run | local working tree only — never commits or pushes; the agent is expected to hand the file to `open_pull_request` alongside the package it came from, so a human reviews it in the same PR |
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
