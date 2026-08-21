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

/**
 * Ensures a git identity is configured before committing. Found by testing:
 * a real agent run failed here with "Author identity unknown" on a runner
 * that had never had git user.name/user.email set — and the agent
 * correctly refused to guess one itself. Uses --local so this never
 * touches the runner's global git config, and only sets what's missing
 * (never overrides a deliberately configured identity).
 */
async function ensureGitIdentity() {
  const email = await run("git", ["config", "--local", "user.email"]);
  if (email.code !== 0 || !email.stdout.trim()) {
    await run("git", ["config", "--local", "user.email", "github-actions[bot]@users.noreply.github.com"]);
  }
  const name = await run("git", ["config", "--local", "user.name"]);
  if (name.code !== 0 || !name.stdout.trim()) {
    await run("git", ["config", "--local", "user.name", "github-actions[bot]"]);
  }
}

/**
 * Found by testing: a request retried after an earlier attempt's PR-create
 * step failed (e.g. the repo's Actions PR-creation setting was off) leaves
 * a pushed branch behind with no PR for it. The next attempt's plain
 * `git checkout -b` then fails with "branch already exists". Handles both
 * cases: an existing PR for this branch is reported back as-is (idempotent
 * success, nothing to redo); a branch with no PR is machine-owned by
 * naming convention (package-request/<id>), so it's safe to drop and
 * recreate rather than fail the whole retry on stale state.
 */
async function reconcileExistingBranch(branch, base) {
  const prList = await run("gh", ["pr", "list", "--head", branch, "--state", "all", "--json", "url,state"]);
  if (prList.code === 0 && prList.stdout.trim()) {
    const prs = JSON.parse(prList.stdout);
    if (prs.length > 0) {
      return { existingPrUrl: prs[0].url };
    }
  }

  // Can't delete a branch that's currently checked out — a prior failed
  // call may have left the working tree on it.
  await run("git", ["checkout", base]).catch(() => {});
  await run("git", ["branch", "-D", branch]).catch(() => {});
  await run("git", ["push", "origin", "--delete", branch]).catch(() => {});
  return {};
}

export async function handler({ branch, title, body, files, base }) {
  if (!process.env.GH_TOKEN && !process.env.GITHUB_TOKEN) {
    return textResult("GH_TOKEN (or GITHUB_TOKEN) is not set — cannot authenticate gh.", true);
  }
  if (files.length === 0) {
    return textResult("No files given to commit.", true);
  }

  const { existingPrUrl } = await reconcileExistingBranch(branch, base);
  if (existingPrUrl) {
    return textResult(existingPrUrl);
  }

  await ensureGitIdentity();

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
