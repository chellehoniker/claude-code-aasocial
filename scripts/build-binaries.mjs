/**
 * Local equivalent of .github/workflows/release.yml — bun-compiles per-
 * platform binaries from mcp-server/index.ts. Useful for canary testing
 * a release before tagging, or running the build pipeline by hand if
 * Actions is unavailable.
 *
 * Output: dist/ at repo root with aa-mcp-* binaries + checksums.txt.
 *
 * Run:  bun run build  (or: node scripts/build-binaries.mjs)
 *
 * Note this is NOT the runtime path — production users get binaries via
 * GitHub Releases. This script exists for local verification only.
 */

import { spawnSync } from "child_process";
import { mkdirSync, readdirSync, statSync } from "fs";
import { resolve } from "path";

const root = resolve(new URL(".", import.meta.url).pathname, "..");
const distDir = resolve(root, "dist");
mkdirSync(distDir, { recursive: true });

const targets = [
  { name: "bun-darwin-arm64", out: "aa-mcp-darwin-arm64" },
  { name: "bun-darwin-x64", out: "aa-mcp-darwin-x64" },
  { name: "bun-windows-x64", out: "aa-mcp-windows-x64.exe" },
  { name: "bun-linux-x64", out: "aa-mcp-linux-x64" },
];

for (const t of targets) {
  const outPath = resolve(distDir, t.out);
  console.log(`▶ Building ${t.name} → ${outPath}`);
  const result = spawnSync(
    "bun",
    [
      "build",
      "--compile",
      `--target=${t.name}`,
      resolve(root, "mcp-server/index.ts"),
      "--outfile",
      outPath,
    ],
    { stdio: "inherit" }
  );
  if (result.status !== 0) {
    console.error(`✗ Failed to build ${t.name}`);
    process.exit(result.status ?? 1);
  }
}

// Generate checksums.txt — same format as the GH Actions step so the
// SessionStart hook's parser works identically against either source.
const sums = spawnSync(
  "shasum",
  ["-a", "256", ...targets.map((t) => t.out)],
  { cwd: distDir, stdio: ["ignore", "pipe", "inherit"] }
);
if (sums.status !== 0) {
  console.error("✗ shasum failed");
  process.exit(sums.status ?? 1);
}
const sumsPath = resolve(distDir, "checksums.txt");
spawnSync("sh", ["-c", `cd "${distDir}" && shasum -a 256 aa-mcp-* > checksums.txt`], {
  stdio: "inherit",
});

console.log("\nBuilt:");
for (const f of readdirSync(distDir)) {
  const stat = statSync(resolve(distDir, f));
  console.log(`  ${f}  ${(stat.size / 1024 / 1024).toFixed(1)} MB`);
}
console.log(`\nDist directory: ${distDir}`);
