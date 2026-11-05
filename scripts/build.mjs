// Builds what the package exports: dist/preload.js (for cdp-kernel's
// `preload` option, imported by the Worker), dist/webkit.js (the page's
// host handler) and dist/mod.js, all ES modules, plus a .d.ts for each
// source module. `prepare` runs it, so a git dependency gets dist/ too.
//
//   node scripts/build.mjs [outdir]

import { execFileSync } from "node:child_process";
import { readdirSync, readFileSync, writeFileSync } from "node:fs";
import { createRequire } from "node:module";
import { join } from "node:path";
import { build } from "esbuild";

const outdir = process.argv[2] ?? "dist";
await build({
  entryPoints: { preload: "src/preload.ts", webkit: "src/webkit.ts", mod: "src/mod.ts", remote: "src/comm.ts" },
  outdir,
  bundle: true,
  format: "esm",
  platform: "browser",
  target: "es2022",
  sourcemap: true,
  logLevel: "warning",
});

const tsc = createRequire(import.meta.url).resolve("typescript/bin/tsc");
execFileSync(process.execPath, [tsc, "-p", "tsconfig.build.json", "--outDir", outdir], { stdio: "inherit" });
// The sources import "./x.ts"; consumers resolve the declarations as "./x.js".
for (const file of readdirSync(outdir).filter(f => f.endsWith(".d.ts"))) {
  const path = join(outdir, file);
  writeFileSync(path, readFileSync(path, "utf8").replace(/(from\s+"\.\/[\w-]+)\.ts"/g, '$1.js"'));
}
console.log(`built ${outdir}/preload.js, webkit.js, mod.js, remote.js and their .d.ts`);
