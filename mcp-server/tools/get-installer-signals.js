import { z } from "zod";
import { runPwshScript, textResult } from "../lib/exec.js";

export const name = "get_installer_signals";

export const config = {
  title: "Get Installer Signals",
  description:
    "Runs scripts/Get-InstallerSignals.ps1 against a downloaded installer file (.msi or .exe) already on disk -- never executes it, only reads it. For an MSI, returns its real Property table (ProductName/ProductCode/ALLUSERS/REBOOT/etc.) straight from the Windows Installer database. For an EXE, scans its embedded strings for known installer-framework fingerprints (NSIS, Inno Setup, InstallShield, WiX Burn, InstallAware, Squirrel, Advanced Installer) and reports a candidate silent-switch syntax for whichever framework matched, plus any other switch-like strings found. Use this when search_silent_install_switch/get_community_package_tools/get_winget_package_manifest found nothing for a package -- a real signal read from the installer's own bytes beats guessing from the vendor/product name alone. The candidate switches returned are a starting point, not a confirmed answer; a human still verifies the final switch before it ships (e.g. with the project's Silent-Test Kit) the same way every other candidate in this pipeline gets reviewed before merge.",
  inputSchema: {
    installer_path: z
      .string()
      .describe("Absolute path (or path relative to the repo root) to the downloaded .msi/.exe file to analyze"),
  },
};

export async function handler({ installer_path }) {
  const { code, stdout, stderr } = await runPwshScript(
    "scripts/Get-InstallerSignals.ps1",
    ["-Path", installer_path, "-Json"]
  );

  if (code !== 0) {
    return textResult(stderr || stdout || `Get-InstallerSignals.ps1 exited with code ${code}.`, true);
  }

  return textResult(stdout);
}
