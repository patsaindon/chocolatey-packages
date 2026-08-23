# Verifying a silent-install switch before it ships

Every silent switch this repo's tooling finds — from `get_winget_package_manifest`,
`get_community_package_tools`, `search_silent_install_switch`, or the newer
`get_installer_signals` (Section 6.9 of [docs/architecture.md](architecture.md)) —
comes with a different level of confidence. winget-pkgs and a real Community
`chocolateyInstall.ps1` are working sources someone else already deployed;
`get_installer_signals` only reports what's *typical* for the installer
framework it detected, not a guarantee this particular vendor didn't customize
it. The package-request agent is told to flag that difference in a PR body
(`.github/workflows/handle-package-request.yml`), but flagging it is only
useful if there's an actual, cheap way for the human reviewing that PR to
close the gap before approving it.

## The check: `scripts/New-SilentTestKit.ps1`

Runs the installer, with the exact switch string a PR proposes, inside a
disposable Windows Sandbox — network-isolated by default — and hands back
hard evidence: the real process exit code, and whether a new entry actually
appeared in Add/Remove Programs. Nothing persists once the sandbox closes;
your real machine is never touched.

```powershell
./scripts/New-SilentTestKit.ps1 -InstallerPath "C:\Downloads\setup.exe" -Switches "/S"
```

Add `-AllowNetwork` if the installer is a bootstrapper that downloads files
mid-install.

A sandbox window opens automatically, runs the install, and closes on its
own once the result is written. Read the result at
`%TEMP%\SilentTestKit\result.txt`.

**This is a human, local, pre-merge step, not something the package-request
pipeline calls itself.** Windows Sandbox needs `Enable-WindowsOptionalFeature
-Online -FeatureName "Containers-DisposableClientVM" -All` (one-time,
Pro/Enterprise/Education only) and a real interactive desktop session to open
its GUI — the self-hosted runner behind `handle-package-request.yml` runs as
a Windows service account with no interactive session, so it genuinely can't
launch one. That's exactly why the agent's job stops at *proposing* a switch
and flagging its confidence level, and a human's job is running this script
before approving a PR that carries an unverified one.

## Exit code cheat sheet

| Code | Meaning | What to do |
|---|---|---|
| `0` | Success | Switch confirmed — safe to use. |
| `3010` / `1641` | Success, reboot required/initiating | Switch works — flag as reboot-required in the deployment. |
| `1603` | Fatal error during install | Try a different switch set, or check for missing prerequisites. |
| `1618` | Another install already in progress | Re-run — a Windows Installer mutex was locked. |
| `1619` | Install package could not be opened | File is corrupt, blocked, or not a real MSI — re-download it. |
| `1638` | A newer version is already installed | Expected on re-runs; not a switch failure. |
| `5100` | Hardware/software requirements not met | Not a switch problem — check OS/prereqs in the sandbox. |

`result.txt`'s "no new Add/Remove Programs entry" case isn't automatically a
failure either — drivers, runtimes, and background services commonly don't
register there at all. Treat the exit code as authoritative in that case.

## Before approving a package-request PR that carries a new switch

- [ ] Ran `New-SilentTestKit.ps1` with the exact switch string the PR proposes
- [ ] `result.txt` shows exit code `0`, `3010`, or `1641`
- [ ] A new Add/Remove Programs entry appeared (or the exit code alone is
      trusted, for a switch-type known not to register one)
- [ ] Re-ran once to confirm the result is repeatable, not a fluke
- [ ] If the switch came from `get_installer_signals` rather than a known
      working source, this checklist is *why* the PR is trusted, not the
      agent's own note

## Narrowing down a switch by hand, when the pipeline found nothing

When `handle-package-request.yml`'s agent exhausts every automated source
(winget-pkgs, a real Community script, `get_installer_signals`, a best-effort
web search) and still comes up empty, a human is going to be doing the same
kind of lookup by hand anyway — a vendor doc, a forum thread, or an AI chat
of their own. A small set of structured prompts for exactly that situation
(extracting switches from vendor prose, reconciling conflicting forum
answers, identifying an installer framework from a product name alone,
turning a confirmed switch into a `chocolateyInstall.ps1`) is worth keeping
next to this doc rather than re-deriving each time — ask whoever requested
the package if they already have a copy, or write your own following the
same shape: one prompt per situation, each ending in a concrete, checkable
question rather than an open-ended one.
