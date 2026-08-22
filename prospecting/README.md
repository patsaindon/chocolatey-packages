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
| `AmbiguousMatch` | `True` if this row's `CommunityPackageId` is also claimed by another app with a different real version — see below |
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

Even an exact match can still be wrong, though, when the exact term
tried is a generic single word shared by several unrelated apps — found
by testing against real data: `OBS Studio`, `Microsoft Visual Studio
Code`, `Microsoft Visual Studio`, and three separate SSMS entries all
exact-matched the same `studio` package, which `choco info` shows is
actually an unrelated "Studio 2.0" — none of them. Every run
recomputes, across the *whole* reference (not just that run's batch,
since two colliding entries can easily land in different batches run
days apart), whether a `CommunityPackageId` is claimed by more than one
app that disagrees about the real version — genuinely the same software
wouldn't disagree about its own current version, so disagreement is
proof of a bad match on at least one side, not something to resolve by
picking a winner. Rows like this get `AmbiguousMatch = True` and are
excluded from the candidate list until sorted out by hand; a first pass
over real, already-collected data found 34 such rows across 12 distinct
collisions (`GitHub`, `PowerShell`, `openjdk`, `mysql`, `grafana`,
`fiddler`, `zoom`, `Opera`, `treesize`, and `studio` among them).

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

## A second, broader (and weaker-signal) reference

`Update-CommunityVersionReference.ps1` only covers evergreen-api's ~565
known apps -- a curated, but small, slice of the ~11,654 unique packages
on the Community Repository (confirmed via
[community.chocolatey.org/stats](https://community.chocolatey.org/stats)'
`UniquePackages` field). `scripts/Update-CommunityStalenessReference.ps1`
sweeps the *entire* catalog instead, using only each package's own
`Published` date (`choco info`) -- no evergreen cross-reference, so no
confirmed real-version comparison either. A flagged row here (`StaleDays`
past the threshold) means "hasn't been touched in a while", not
"confirmed behind the real vendor version" the way `VersionMismatch` in
the other reference does -- some software genuinely hasn't changed in
years. Treat it as a lead worth a manual look, or a match against
`community-version-reference.csv` if the same software happens to be
evergreen-tracked, not a ready-made candidate.

It advances by a simple page cursor (`community-staleness-cursor.txt`)
through `choco search --page=N --order-by=Id` rather than a
never-checked-first sort like the evergreen reference uses: confirmed by
testing that `--page` is 0-indexed and hands off cleanly between pages
under the default (Id) ordering, so a plain advancing cursor sweeps the
whole catalog reliably over many small runs, wrapping back to page 0
once it reaches the end to keep refreshing indefinitely. (`choco search
--order-by="LastPublished"` looked promising for this at first, but choco
itself warns that ordering is applied client-side per page only --
useless for a true global sort across a paged catalog this size, so
`Update-CommunityStalenessReference.ps1` sorts within its own reference
itself, using each page's `Published` date it looks up via `choco info`
one package at a time.)

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

## The other discovery direction: what has no Chocolatey package at all

Everything above starts from a package that already exists and asks
whether it's stale. `scripts/Find-PackagingOpportunities.ps1`
(`.github/workflows/prospect-packaging-opportunities.yml`, daily) starts
from the opposite end: real open-source activity on GitHub, and asks
whether Chocolatey has ever heard of it.

"Gaining popularity" is a concrete, reproducible query, not a vague
notion — repos created within the last `-CreatedWithinMonths` (default
12), with more than `-MinStars` (default 300) stars, straight from
GitHub's own `/search/repositories` API. No scraping: GitHub's Trending
page has no official API at all, and an unofficial one would be one more
thing to trust.

A repo having stars doesn't mean it ships anything installable on
Windows, though — confirmed by testing that a looser check (does any
release asset's name contain `win`) is actively misleading: a Node
native-module repo's `win32-x64-msvc.node` file matched that but isn't a
standalone installer at all, while a real desktop app's actual installers
matched a strict `.exe`/`.msi` extension check correctly. Only that
strict check counts as "ships a real Windows installer" here. Survivors
get checked against Community (`choco search --exact`, the same
"only trust an exact match" principle used for evergreen/winget matching
elsewhere in this repo) — a real installer with no Community match is a
genuine candidate for `scaffold_internal_package`, using the repo's own
name directly.

A first real test batch (the top 15 repos by star count) found zero real
candidates — sorting by raw popularity surfaces viral, non-installable
content (agent frameworks, "awesome" lists, skill collections) well
before genuine desktop software. That's expected, not a bug: the same
batched, cursor-advancing design as the other two scripts here means
repeated runs keep working through GitHub's real result set over time,
the same way finding a stale package took patience rather than one
lucky first batch.
