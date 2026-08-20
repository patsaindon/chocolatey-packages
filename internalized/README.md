# internalized/

Packages sourced from the Chocolatey Community Repository and internalized so installers never depend on the public internet at deploy time.

Each package lives in its own folder, named after its package ID, containing an `internalize.yml` manifest:

```
internalized/<package-id>/
└── internalize.yml
```

Example:

```yaml
# internalized/7zip/internalize.yml
packageId: 7zip
pinnedVersion: "23.1.0"          # or "latest" to always re-check
source: https://community.chocolatey.org/api/v2/
internalizeOptions:
  recursive: true                 # pull dependencies too (C4B feature)
owner: platform-engineering
autoUpdateCheck: true             # opt into the scheduled update-check workflow
notes: "Approved for general use, no special restrictions"
```

Merging a new `internalize.yml` (or a version bump to an existing one) triggers `.github/workflows/internalize-community-package.yml`, which downloads, scans, smoke-tests, and pushes the result to the staging feed. See [docs/architecture.md](../docs/architecture.md) sections 6.1, 9.1, and 9.2 for the full design.
