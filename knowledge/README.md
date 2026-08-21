# knowledge/

One file per vendor/product family: `<vendor>.yml`, a flat `key: value`
list of facts already confirmed while onboarding or updating a package
sourced from that vendor — checksum field names, image-type/architecture
defaults, version-format quirks, known-good silent-install switches, plus
free-form `notes` and a `last_verified`/`last_verified_via` stamp. Same
flat-YAML convention as `metadata.yml` elsewhere in this repo (see
`scripts/lib/SimpleYaml.ps1`) — no lists, no nested maps, deliberately
simple so a file stays readable in a plain PR diff.

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
