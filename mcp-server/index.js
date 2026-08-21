#!/usr/bin/env node
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";

import * as searchCommunityPackage from "./tools/search-community-package.js";
import * as lintPackage from "./tools/lint-package.js";
import * as scaffoldInternalPackage from "./tools/scaffold-internal-package.js";
import * as bootstrapInternalizePackage from "./tools/bootstrap-internalize-package.js";
import * as openPullRequest from "./tools/open-pull-request.js";

// Package-creation tools for the issue-triggered package request flow.
// See docs/architecture.md and .github/workflows/handle-package-request.yml.
// Each tool is a thin wrapper around an existing repo script or a small,
// auditable file/git operation — no package-management logic is
// reimplemented here.

const server = new McpServer({
  name: "chocolatey-packages",
  version: "1.0.0",
});

for (const tool of [
  searchCommunityPackage,
  lintPackage,
  scaffoldInternalPackage,
  bootstrapInternalizePackage,
  openPullRequest,
]) {
  server.registerTool(tool.name, tool.config, tool.handler);
}

const transport = new StdioServerTransport();
await server.connect(transport);
