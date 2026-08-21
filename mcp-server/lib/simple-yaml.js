// Minimal reader/writer for the flat, single-line-value YAML convention
// already used elsewhere in this repo (metadata.yml, via
// scripts/lib/SimpleYaml.ps1) -- key: value pairs, '#' comments, quoted
// scalars when a value needs it. Deliberately not a general YAML
// implementation: no lists, no nested maps, no multi-line block scalars.
// Used for knowledge/<vendor>.yml (see lib/knowledge.js) so those files
// stay readable in a plain PR diff without pulling in a real YAML
// dependency for something this small.

const NEEDS_QUOTING = /^\s|\s$|[:#'"]/;

/** Strips a trailing '# comment', but only a '#' that isn't inside a
 * quoted value -- a naive `replace(/#.*$/, '')` (as this repo's
 * PowerShell SimpleYaml.ps1 also does) truncates any quoted value that
 * itself contains '#', e.g. `notes: "see PR #6"` silently loses
 * everything from '#6' onward. Found by testing against a real
 * knowledge file whose notes referenced a PR number this way. */
function stripComment(line) {
  let quote = null;
  for (let i = 0; i < line.length; i++) {
    const ch = line[i];
    if (quote) {
      if (ch === quote) quote = null;
    } else if (ch === "'" || ch === '"') {
      quote = ch;
    } else if (ch === "#") {
      return line.slice(0, i);
    }
  }
  return line;
}

export function parseSimpleYaml(text) {
  const result = {};
  for (const rawLine of text.split(/\r?\n/)) {
    const line = stripComment(rawLine);
    if (!line.trim()) continue;
    const match = line.match(/^([^:\s][^:]*):\s*(.*)$/);
    if (!match) continue;
    const key = match[1].trim();
    let value = match[2].trim();
    const quoted = value.match(/^"(.*)"$/) ?? value.match(/^'(.*)'$/);
    if (quoted) value = quoted[1];
    result[key] = value;
  }
  return result;
}

export function stringifySimpleYaml(obj, headerLines = []) {
  const lines = [...headerLines];
  for (const [key, value] of Object.entries(obj)) {
    const str = String(value);
    const quoted = NEEDS_QUOTING.test(str) ? `"${str.replace(/"/g, '\\"')}"` : str;
    lines.push(`${key}: ${quoted}`);
  }
  return lines.join("\n") + "\n";
}
