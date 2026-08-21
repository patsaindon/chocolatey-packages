import fs from "node:fs/promises";
import path from "node:path";
import { REPO_ROOT } from "./exec.js";
import { parseSimpleYaml, stringifySimpleYaml } from "./simple-yaml.js";

const KNOWLEDGE_DIR = "knowledge";

const HEADER = [
  "# Facts learned about this vendor's packages while onboarding or",
  "# updating them -- checksum field names, image-type/architecture",
  "# defaults, version-format quirks, known-good silent-install switches.",
  "# Read by the package-request agent before scaffolding (see",
  "# lookup_package_knowledge) so an already-solved quirk isn't",
  "# rediscovered by trial and error on the next package from the same",
  "# vendor. Written only locally by write_package_knowledge -- a human",
  "# reviews every change here in the same PR as the package it came",
  "# from, never a silent agent write. See docs/architecture.md section 6.8.",
  "",
];

export function knowledgeRelativePath(vendor) {
  return path.join(KNOWLEDGE_DIR, `${vendor}.yml`);
}

export async function readKnowledge(vendor) {
  try {
    const raw = await fs.readFile(path.join(REPO_ROOT, knowledgeRelativePath(vendor)), "utf8");
    return parseSimpleYaml(raw);
  } catch (err) {
    if (err.code === "ENOENT") return null;
    throw err;
  }
}

/** Merges `facts` into whatever's already recorded for `vendor` and writes
 * the result to the local working tree only. Never commits or pushes --
 * the caller (write_package_knowledge's handler) is expected to hand the
 * returned path to open_pull_request alongside the package files it came
 * from, so a human reviews it in the same PR. */
export async function writeKnowledge(vendor, facts) {
  const existing = (await readKnowledge(vendor)) ?? {};
  const merged = { ...existing, ...facts };
  const relPath = knowledgeRelativePath(vendor);
  const fullPath = path.join(REPO_ROOT, relPath);
  await fs.mkdir(path.dirname(fullPath), { recursive: true });
  await fs.writeFile(fullPath, stringifySimpleYaml(merged, HEADER), "utf8");
  return relPath;
}
