/**
 * Bundle the MCP server into a single self-contained dist/index.js.
 *
 * Why: the previous flow ran `npm install --production` on first
 * SessionStart so the runtime SDK was available — which meant new
 * users waited 60–90s+ on a cold network before the plugin could
 * respond. After bundling, dist/index.js carries everything inline
 * and runs immediately. The SessionStart hook + NODE_PATH env are
 * no longer needed.
 *
 * Run:  npm run build
 */

import { build } from "esbuild";
import { writeFileSync, chmodSync } from "fs";
import { resolve } from "path";

const root = resolve(new URL(".", import.meta.url).pathname, "..");

await build({
  entryPoints: [resolve(root, "mcp-server/index.ts")],
  bundle: true,
  platform: "node",
  target: "node18",
  format: "cjs", // package.json has no "type":"module", so CJS is the safe default
  outfile: resolve(root, "mcp-server/dist/index.js"),
  // Source already has `#!/usr/bin/env node` on line 1; esbuild preserves it.
  // No banner config — adding one duplicates the shebang and node chokes on line 2.
  // 'bundle' inlines every dependency into the output so we don't need
  // node_modules at runtime. The SDK (MIT) gets compiled in alongside
  // our own code; the resulting file is ~150KB.
  packages: "bundle",
  legalComments: "linked", // ensures MIT/license blocks are preserved
  minify: false, // keep readable so support can grep stack traces
  sourcemap: false, // smaller install footprint
});

// Make the bundle executable so `node dist/index.js` (and direct invoke)
// both work.
chmodSync(resolve(root, "mcp-server/dist/index.js"), 0o755);

// Drop the .d.ts files that tsc used to emit — they're irrelevant for a
// bundled runtime and just bloat the install. We don't want stale type
// hints from a previous tsc run shipping with the bundle.
writeFileSync(
  resolve(root, "mcp-server/dist/.gitkeep"),
  "# bundled by scripts/build-bundle.mjs\n"
);

console.log("✓ Bundled mcp-server/dist/index.js");
