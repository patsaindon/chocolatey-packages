# prospecting/

Proactive discovery, as opposed to everything else in this repo (which
reacts to a specific request or a specific already-onboarded package).
`scripts/Update-CommunityVersionReference.ps1` builds and maintains
`community-version-reference.csv`: for a batch of apps drawn from
[evergreen-api.stealthpuppy.com](https://eucpilots.com/evergreen/api/)'s
`/apps` index (currently ~565 entries — real, well-known, evergreen-
trackable desktop software), it looks for a matching Chocolatey Community
Repository package and records:

| Column | Meaning |
|---|---|
| `EvergreenName` / `Application` | The evergreen-api slug and friendly name |
| `CommunityPackageId` / `CommunityVersion` | The Community package it matched to, if any, and that package's current version |
| `EvergreenVersion` | The real current version, from evergreen-api directly |
| `Published` | The Community package's own `Published` date (`choco info`) |
| `VersionMismatch` | `True` if `CommunityVersion` doesn't match `EvergreenVersion` (after stripping build-metadata suffixes) |
| `StaleDays` | Days since `Published` |
| `LastChecked` | When this row was last refreshed |

**Why this exists:** an internal AU package is usually made *because* a
Community equivalent already lags the vendor's own release cadence
(`temurin17` tracking Eclipse Adoptium directly instead of Community's own
`temurin17` — see `docs/architecture.md` section 6.1). Until now, noticing
that gap meant a human happening to compare versions by hand. This turns
that into a standing, queryable reference: `VersionMismatch = True` or a
large `StaleDays` is a candidate worth considering for
`scaffold_internal_package`, using the row's own `EvergreenName` directly
as `scaffold_internal_package`'s `evergreen_app_name`.

**Why batches, not one full pass:** evergreen-api's index is large enough
(~565 apps) that checking it all in one run would be slow and put
needless load on both evergreen-api and the Community Repository for
information that rarely changes minute to minute. Each run advances
through the index a batch at a time (`-BatchSize`, default 30) —
never-checked apps first, then whichever checked apps have gone longest
since their last check — so repeated runs eventually cycle through the
whole index rather than needing one long run to cover it.

**Matching an evergreen app to a Community package id is a heuristic, not
a lookup** — evergreen's own naming (`AdoptiumTemurin25`, a
vendor+product+version slug) rarely matches Chocolatey's own id
conventions directly. The script only trusts an **exact** `choco search`
match (tried against a few candidate terms derived from the app's name),
never the first result of a broader search — confirmed by testing that a
plain substring search for "Firefox" returns dozens of loosely related
packages (`adblockplusfirefox`, `allbrowsers`, …) before the real
`firefox` package. An app with no confident match isn't an error — it's
reported separately, and just means there's nothing on Community to
compare against for that app (which is itself useful: it means
`scaffold_internal_package` is the *only* path for that software, not a
choice between two).

**This never writes to `internal/` or any feed.** It only maintains its
own CSV — a human (or the package-request agent, if this ever gets wired
into that flow) still decides what to actually do with a flagged
candidate.

## Running it

```powershell
./scripts/Update-CommunityVersionReference.ps1 -Verbose
```

Then, to see what's worth a look right now without waiting for the next
batch's console summary:

```powershell
Import-Csv prospecting/community-version-reference.csv |
    Where-Object { $_.VersionMismatch -eq 'True' -or [int]$_.StaleDays -gt 180 }
```

## Drafting an update for a stale package's own maintainer

`scripts/Draft-CommunityPackageUpdate.ps1 -CommunityPackageId <id>` fetches
that package's real files (nuspec, `tools/chocolateyInstall.ps1`) straight
from its own `Chocolatey Package Source` repo (a field `choco info`
already reports), plus the real current version/URL/checksum from
evergreen-api, and writes `prospecting/drafts/<id>/` with the originals
under `original/` and an `UPDATE-NOTES.md` summarizing what to change and
where to submit it.

**It never auto-edits the maintainer's script or opens a PR.** Unlike
this repo's own AU templates, an arbitrary Community package's script
structure is unknown — a wrong auto-edit wastes the maintainer's review
time worse than no PR at all — and submitting to someone else's repo is
an outward-facing action representing you to a stranger, not something
to automate away entirely. A human forks, makes the actual edit (informed
by real, correct data this script already looked up), tests it locally,
and opens the PR themselves. `prospecting/drafts/` is gitignored — it's
someone else's files plus a proposed edit, staged for review, never
something that belongs committed to this repo.
