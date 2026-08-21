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

## How updates happen

- **On a PR** touching `internal/**`: [.github/workflows/test-internal-packages.yml](../.github/workflows/test-internal-packages.yml) lints the changed package(s) and force-tests them via AU's `test_all.ps1` — never pushes anywhere.
- **On a schedule**: [.github/workflows/update-internal-packages.yml](../.github/workflows/update-internal-packages.yml) lints every package, then runs `update_all.ps1` (AU's `updateall`), which checks each package's `au_GetLatest` and pushes anything with a newer version straight to the staging feed.
- Promotion from staging to production is still a separate, human-approved step — see [.github/workflows/promote-package.yml](../.github/workflows/promote-package.yml) and `docs/architecture.md` section 9.4.

`update_vars_default.ps1` (repo root) is a template for the environment variables `update_all.ps1`/`test_all.ps1` read (gist/mail/GitHub reporting settings) for a **local, interactive** run by a developer — copy it to `update_vars.ps1` (already gitignored) and fill in real values there. CI never uses `update_vars.ps1`; the scheduled workflow gets its staging feed URL/API key directly from GitHub Secrets.

## AU helper functions

[scripts/au-helpers/](../scripts/au-helpers/) holds small AU-authoring helpers (e.g. `Set-DescriptionFromReadme.ps1`, used from a package's `au_AfterUpdate` hook) meant to be dot-sourced in bulk via `au-helpers/all.ps1`. It's kept separate from the rest of `scripts/`, which holds standalone CI scripts with required parameters — `all.ps1` blindly dot-sources every `.ps1` beside it, which would break against a script expecting arguments.
