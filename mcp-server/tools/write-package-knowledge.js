import { z } from "zod";
import { writeKnowledge } from "../lib/knowledge.js";
import { textResult } from "../lib/exec.js";

export const name = "write_package_knowledge";

export const config = {
  title: "Write Package Knowledge",
  description:
    "Writes or updates knowledge/<vendor>.yml locally with facts learned or corrected while scaffolding/updating a package for this vendor. Merges into whatever's already recorded rather than overwriting it wholesale. Only writes to the local working tree -- never commits or pushes. Include the returned path in open_pull_request's `files` list so a human reviews this change in the same PR as the package it came from, exactly like a code change -- never write here without also doing that. Always call this with 'silent_args' and/or 'source_url' after a package from a vendor you don't already have both recorded for, whenever you found either one this run (get_community_package_tools' detectedSilentArgs, search_silent_install_switch, a working install script you read yourself, the releases page you scaffolded against) -- these two are easy to find once and then never write down, leaving the next package from the same vendor to rediscover them from scratch.",
  inputSchema: {
    vendor: z.string().describe("Same vendor slug used with lookup_package_knowledge."),
    facts: z
      .record(z.string())
      .describe(
        "Flat key/value facts to record or correct. Standard field names: 'checksum_field', 'image_type_default', 'architecture_default', 'version_sanitize' (au_GetLatest concerns); 'silent_args' / 'source_url' (scaffold_internal_package reads these two back automatically via its own 'vendor' parameter); 'product_description' (a real one-or-two-sentence description of what this vendor's software actually does -- scaffold_internal_package's own 'vendor' parameter reads this back automatically too, for its 'description' parameter, i.e. the nuspec's <description> -- distinct from any package's own packaging-rationale notes, and worth recording once so the next package from this vendor doesn't need it rewritten from scratch); and, for the binary itself, 'installer_type' ('msi'/'exe'/'portable'), 'installer_framework' ('MSI'/'NSIS'/'WiX'/'InstallShield'/'none'), 'silent_args_source' (where silent_args came from: 'winget'/'community_script'/'installer_signals'/'catalog_search'/'generic_default') and 'silent_args_verified' (true only once a human has actually run scripts/New-SilentTestKit.ps1 against it -- false otherwise, never guess true) -- see knowledge/README.md's table for exactly what each value means. Omit the last three for a portable package (package_kind: 'portable') -- there's no installer or silent switch. Include a 'notes' key (free text: what was learned and how it was confirmed) and a 'last_verified_via' key (the package id or PR this came from)."
      ),
  },
};

export async function handler({ vendor, facts }) {
  const relPath = await writeKnowledge(vendor, {
    ...facts,
    last_verified: new Date().toISOString().slice(0, 10),
  });
  return textResult(`Wrote ${relPath}. Include it in open_pull_request's files list so a human reviews it.`);
}
