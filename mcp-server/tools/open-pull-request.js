import { z } from "zod";
import { run, textResult } from "../lib/exec.js";

export const name = "open_pull_request";

export const config = {
  title: "Open Pull Request",
  description:
    "Commits already-written working-tree changes (e.g. from scaffold_internal_package) to a new branch, pushes it, and opens a PR against the base branch via gh. Never merges — a human still reviews and merges. Requires GH_TOKEN (or GITHUB_TOKEN) in the server's environment.",
  inputSchema: {
    branch: z.string().describe("New branch name, e.g. 'package-request/foo'"),
    title: z.string().describe("Commit message and PR title"),
    body: z.string().describe("PR description"),
    files: z
      .array(z.string())
      .describe("Paths (relative to repo root) to stage for this commit"),
    base: z.string().optional().default("main"),
  },
};

export async function handler({ branch, title, body, files, base }) {
  if (!process.env.GH_TOKEN && !process.env.GITHUB_TOKEN) {
    return textResult("GH_TOKEN (or GITHUB_TOKEN) is not set — cannot authenticate gh.", true);
  }
  if (files.length === 0) {
    return textResult("No files given to commit.", true);
  }

  const steps = [
    ["git", ["checkout", "-b", branch]],
    ["git", ["add", ...files]],
    ["git", ["commit", "-m", title]],
    ["git", ["push", "origin", branch]],
  ];

  for (const [cmd, args] of steps) {
    const result = await run(cmd, args);
    if (result.code !== 0) {
      // Best-effort return to base so the working tree doesn't stay
      // stranded on a half-finished branch for whatever call comes next.
      await run("git", ["checkout", base]).catch(() => {});
      return textResult(
        `'${cmd} ${args.join(" ")}' failed (exit ${result.code}):\n${result.stderr || result.stdout}`,
        true
      );
    }
  }

  const pr = await run("gh", [
    "pr",
    "create",
    "--base",
    base,
    "--head",
    branch,
    "--title",
    title,
    "--body",
    body,
  ]);

  await run("git", ["checkout", base]).catch(() => {});

  if (pr.code !== 0) {
    return textResult(`gh pr create failed (exit ${pr.code}):\n${pr.stderr || pr.stdout}`, true);
  }

  return textResult(pr.stdout.trim());
}
