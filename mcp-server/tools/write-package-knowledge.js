import { z } from "zod";
import { writeKnowledge } from "../lib/knowledge.js";
import { textResult } from "../lib/exec.js";

export const name = "write_package_knowledge";

export const config = {
  title: "Write Package Knowledge",
  description:
    "Writes or updates knowledge/<vendor>.yml locally with facts learned or corrected while scaffolding/updating a package for this vendor. Merges into whatever's already recorded rather than overwriting it wholesale. Only writes to the local working tree -- never commits or pushes. Include the returned path in open_pull_request's `files` list so a human reviews this change in the same PR as the package it came from, exactly like a code change -- never write here without also doing that.",
  inputSchema: {
    vendor: z.string().describe("Same vendor slug used with lookup_package_knowledge."),
    facts: z
      .record(z.string())
      .describe(
        "Flat key/value facts to record or correct, e.g. { checksum_field: 'Checksum', image_type_default: 'jdk' }. Include a 'notes' key (free text: what was learned and how it was confirmed) and a 'last_verified_via' key (the package id or PR this came from)."
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
