# internal/

Internally authored Chocolatey packages, maintained as [AU](https://github.com/majkinetor/AU) (Chocolatey Automatic Packages) — each package checks its own release source and updates itself, the same "diff and push" model used for [internalized/](../internalized/) packages.

Each package lives in its own folder, **named exactly after its package id** — this matters for two reasons: `choco pack`/`<id>` conventions, and because AU discovers a package by its `.nuspec` **filename** matching the containing folder (confirmed by testing: a mismatched filename makes AU report "No nuspec file found", even if the `<id>` element inside is correct).

```
internal/<package-id>/
├── <package-id>.nuspec
├── metadata.yml            # owner/lifecycle fields AU doesn't track
├── update.ps1               # AU update script: au_GetLatest + au_SearchReplace
└── tools/
    ├── chocolateyinstall.ps1   # url/checksum left empty — au_SearchReplace fills them in
    └── chocolateyuninstall.ps1 # if applicable
```

To onboard a new internal package, copy [internal/_template/](_template/) to `internal/<your-package-id>/`, **rename `CHANGE_ME.nuspec` to `<your-package-id>.nuspec`** (filename *and* the `<id>` element inside, plus `metadata.yml`'s `packageId`), and fill in `update.ps1`'s `au_GetLatest` to point at wherever this software actually publishes releases. Run [scripts/lint-nuspec.ps1](../scripts/lint-nuspec.ps1) `-PackageDir` against it before opening a PR — it checks all of the above, plus catches any leftover `CHANGE_ME` placeholder.

**When the software is paywalled** (a vendor login gates the real download, which this automation must never hold credentials for), `au_GetLatest` can instead read the latest binary a human already uploaded to a Nexus generic/raw-format hosted repository — see [scripts/Get-NexusGenericLatestAsset.ps1](../scripts/Get-NexusGenericLatestAsset.ps1) and `scaffold_internal_package`'s `nexus_generic_*` parameters ([mcp-server/README.md](../mcp-server/README.md)). Not yet verified against a real Nexus instance — see [docs/architecture.md § 6.8](../docs/architecture.md#68-mcp-server--agent-driven-package-creation).

**When the release is a standalone CLI binary, not an installer** (confirmed by real testing — trying to run one through `Install-ChocolateyPackage` silently "installs" something with no install wizard at all, and hangs or behaves unpredictably instead), `chocolateyinstall.ps1` should use `Get-ChocolateyWebFile` with a `fileFullPath` under `tools\` instead — Chocolatey auto-shims any `.exe` it finds there onto PATH, no separate shim-creation code needed, and no `chocolateyuninstall.ps1` either (removing the package removes the shim and everything under `tools\` automatically). `scaffold_internal_package`'s `package_kind: 'portable'` (plus optional `binary_name`, for when the real upstream command name differs from the package id) generates exactly this — verified end-to-end against a real binary (CodeGraphContext's `cgc-windows.exe`: real download, checksum match, and the placed binary actually runs and reports its own version).

## How updates happen

- **On a PR** touching `internal/**`: [.github/workflows/test-internal-packages.yml](../.github/workflows/test-internal-packages.yml) lints the changed package(s) and force-tests them via AU's `test_all.ps1` — never pushes anywhere.
- **On a schedule**: [.github/workflows/update-internal-packages.yml](../.github/workflows/update-internal-packages.yml) lints every package, then runs `update_all.ps1` (AU's `updateall`) with push disabled — AU only packs anything with a newer version locally. [scripts/Internalize-InternalPackages.ps1](../scripts/Internalize-InternalPackages.ps1) then internalizes each of those local packages and pushes only the internalized result to staging — the vendor-URL-referencing package AU produced never touches a shared feed.
- Promotion from staging to production is still a separate, human-approved step, gated by a PR rather than a GitHub Environment reviewer — see [.github/workflows/propose-package-promotion.yml](../.github/workflows/propose-package-promotion.yml), [.github/workflows/promote-approved-packages.yml](../.github/workflows/promote-approved-packages.yml), and `docs/architecture.md` section 9.4.

`update_vars_default.ps1` (repo root) is a template for the environment variables `update_all.ps1`/`test_all.ps1` read (gist/mail/GitHub reporting settings) for a **local, interactive** run by a developer — copy it to `update_vars.ps1` (already gitignored) and fill in real values there. CI never uses `update_vars.ps1`; the scheduled workflow gets its staging feed URL/API key directly from GitHub Secrets.

## AU helper functions

[scripts/au-helpers/](../scripts/au-helpers/) holds small AU-authoring helpers (e.g. `Set-DescriptionFromReadme.ps1`, used from a package's `au_AfterUpdate` hook) meant to be dot-sourced in bulk via `au-helpers/all.ps1`. It's kept separate from the rest of `scripts/`, which holds standalone CI scripts with required parameters — `all.ps1` blindly dot-sources every `.ps1` beside it, which would break against a script expecting arguments.
