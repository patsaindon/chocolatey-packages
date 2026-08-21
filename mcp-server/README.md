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
| `scaffold_internal_package` | copies `internal/_template/`, fills in placeholders | local working tree only |
| `bootstrap_internalize_package` | `choco download --internalize` → `scripts/scan-package.ps1` → `choco push` | **staging feed only** — requires `STAGING_FEED_URL`/`STAGING_API_KEY` in the server's environment; refuses to run without them, and never receives production credentials |
| `open_pull_request` | `git`/`gh` | opens a PR against `main`; never merges |

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
