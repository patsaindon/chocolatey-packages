# chocolatey-packages

Enterprise lifecycle management for Chocolatey packages — internalized from the Chocolatey Community Repository and internally authored — governed by GitHub Actions and promoted through a staging → production feed.

See [docs/architecture.md](docs/architecture.md) for the full architecture design.

## Layout

- [internal/](internal/) — internally authored packages (see [internal/README.md](internal/README.md))
- [internalized/](internalized/) — Community packages internalized for offline install (see [internalized/README.md](internalized/README.md))
- [.github/workflows/](.github/workflows/) — CI/CD: internalize, publish, promote, and scheduled update-check workflows
- [scripts/](scripts/) — supporting scripts called by the workflows (scan, promote, version-check — currently Phase 1 placeholders, see TODOs in each file)

## Status

Phase 1 (pipeline foundation) scaffold — see [docs/architecture.md](docs/architecture.md) section 14 for the full roadmap. The workflow skeletons and scripts here are illustrative; scan/promote logic and feed credentials still need to be filled in before this pipeline is production-ready.
