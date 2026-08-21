# internalized/

Packages sourced from the Chocolatey Community Repository and internalized so installers never depend on the public internet at deploy time.

There is no manifest file to maintain here — presence in the **staging feed** *is* the record of what's currently onboarded. Keeping already-onboarded packages up to date is handled by [scripts/Get-UpdatedPackage.ps1](../scripts/Get-UpdatedPackage.ps1), run on a schedule by [.github/workflows/refresh-internalized-packages.yml](../.github/workflows/refresh-internalized-packages.yml): it diffs every package currently in the staging feed against the Community Repository and re-internalizes anything with a newer remote version.

Onboarding a package for the **first time** (nothing to diff against yet) still goes through [.github/workflows/internalize-community-package.yml](../.github/workflows/internalize-community-package.yml) (`workflow_dispatch`, or triggered by a package-request issue — see `docs/architecture.md`). Once that first push lands in staging, the scheduled refresh picks it up automatically going forward.

This folder is kept only as a place for any package-specific notes that don't belong anywhere else (e.g. why a package was internalized, known caveats) — nothing under it is read by the workflows.
