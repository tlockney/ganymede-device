// Bundles the modules a page loads: dist/preload.js (for cdp-kernel's
// `preload` option, imported by the Worker) and dist/webkit.js (the page's
// host handler). Both are ES modules.
//
//   node scripts/build.mjs [outdir]

import { build } from "esbuild";

const outdir = process.argv[2] ?? "dist";
await build({
  entryPoints: { preload: "src/preload.ts", webkit: "src/webkit.ts", mod: "src/mod.ts" },
  outdir,
  bundle: true,
  format: "esm",
  platform: "browser",
  target: "es2022",
  sourcemap: true,
  logLevel: "warning",
});
console.log(`built ${outdir}/preload.js, webkit.js and mod.js`);
