import { z } from "zod";
import { readKnowledge } from "../lib/knowledge.js";
import { textResult } from "../lib/exec.js";

export const name = "lookup_package_knowledge";

export const config = {
  title: "Lookup Package Knowledge",
  description:
    "Reads knowledge/<vendor>.yml -- facts already confirmed about a vendor's packages from onboarding or updating an earlier package from the same vendor: checksum field name, image-type/architecture default, version-format quirks, the binary's own installer_type/installer_framework, and (standard field names, if recorded) 'silent_args' plus 'silent_args_source'/'silent_args_verified' (don't present an unverified silent_args as confirmed just because it's recorded here), 'source_url', and 'product_description' (a real description of what this vendor's software does -- pass straight through as scaffold_internal_package's own 'description' parameter if this package needs the same product description, e.g. a second package from the same underlying product). Call this before scaffolding a package -- scaffold_internal_package's own 'vendor' parameter also reads these two automatically, but check here first if you want to know what it'll use, or if you're about to look either one up yourself (get_community_package_tools, search_silent_install_switch) and want to skip that work when it's already known. It's normal to get nothing back for a vendor's first package -- that just means there's nothing recorded yet. Read-only.",
  inputSchema: {
    vendor: z
      .string()
      .describe(
        "Normalized vendor/product-family slug you choose, e.g. 'adoptium'. Reuse the same slug across packages from the same vendor so knowledge accumulates under it."
      ),
  },
};

export async function handler({ vendor }) {
  const knowledge = await readKnowledge(vendor);
  if (!knowledge) {
    return textResult(
      `No prior knowledge recorded for '${vendor}' yet -- this looks like the first package from this vendor.`
    );
  }
  return textResult(JSON.stringify(knowledge, null, 2));
}
