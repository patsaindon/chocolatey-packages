import { z } from "zod";
import { readKnowledge } from "../lib/knowledge.js";
import { textResult } from "../lib/exec.js";

export const name = "lookup_package_knowledge";

export const config = {
  title: "Lookup Package Knowledge",
  description:
    "Reads knowledge/<vendor>.yml -- facts already confirmed about a vendor's packages (checksum field name, image-type/architecture default, version-format quirks, known-good silent-install switch) from onboarding or updating an earlier package from the same vendor. Call this before scaffolding a package, so an already-solved quirk isn't rediscovered by trial and error. It's normal to get nothing back for a vendor's first package -- that just means there's nothing recorded yet. Read-only.",
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
