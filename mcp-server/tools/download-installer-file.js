import { z } from "zod";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import crypto from "node:crypto";
import { textResult } from "../lib/exec.js";

export const name = "download_installer_file";

export const config = {
  title: "Download Installer File",
  description:
    "Downloads a file from a direct URL (typically the package request's own source_url, or an installer URL a discovery tool already returned) to a local temp path, for read-only static analysis only -- never installs, runs, or elevates it. This is the missing link that makes get_installer_signals reachable when nothing else found a silent switch: without a local file, there's nothing for that tool to read. Writes only inside the OS temp directory; reads only the single public URL given.",
  inputSchema: {
    url: z.string().url().describe("Direct download URL for the installer file (.msi/.exe)"),
  },
};

export async function handler({ url }) {
  let response;
  try {
    response = await fetch(url);
  } catch (err) {
    return textResult(`Failed to fetch '${url}': ${err.message}`, true);
  }
  if (!response.ok) {
    return textResult(`Fetching '${url}' failed: HTTP ${response.status} ${response.statusText}.`, true);
  }

  const buffer = Buffer.from(await response.arrayBuffer());
  const extMatch = url.match(/\.(msi|exe)(?:$|[?#])/i);
  const ext = extMatch ? extMatch[1].toLowerCase() : "bin";
  const fileName = `installer-${crypto.randomBytes(6).toString("hex")}.${ext}`;
  const destDir = path.join(os.tmpdir(), "chocolatey-packages-mcp");
  fs.mkdirSync(destDir, { recursive: true });
  const destPath = path.join(destDir, fileName);
  fs.writeFileSync(destPath, buffer);

  return textResult(
    JSON.stringify({ path: destPath, bytes: buffer.length, sourceUrl: url }, null, 2)
  );
}
