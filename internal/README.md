# internal/

Internally authored Chocolatey packages — software built in-house, wrapped as a `.nupkg` from scratch rather than internalized from the Community Repository.

Each package lives in its own folder, named after its package ID:

```
internal/<package-id>/
├── <package-id>.nuspec
├── metadata.yml
└── tools/
    ├── chocolateyinstall.ps1
    └── chocolateyuninstall.ps1   # if applicable
```

`metadata.yml` carries maintainer/owner-team and lifecycle tags, e.g.:

```yaml
packageId: acme-launcher
owner: platform-engineering
notes: "Internal deployment tool, not for external distribution"
```

Pushing to `internal/<package-id>/**` triggers the publish workflow (`.github/workflows/publish-internal-package.yml`), which packs, scans, smoke-tests, and pushes to the staging feed. See [docs/architecture.md](../docs/architecture.md) sections 6.1 and 9.3 for the full design.
