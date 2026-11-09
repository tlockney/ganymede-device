import { test } from "node:test";
import assert from "node:assert/strict";
import { join } from "node:path";
import ts from "typescript";
import { generate, root, stale } from "../scripts/reference.ts";

// docs/reference.md is generated from the doc comments on the `device`
// types and from SUPPORT (#85): it must be current, cover every member and
// every SUPPORT row, and every example must type-check against the types.

const result = generate();

test("the reference page matches the doc comments", () => {
  assert.equal(stale(result), false, "run node scripts/reference.ts --write");
});

test("every member has a summary, its parameters and an example", () => {
  assert.deepEqual(result.problems, []);
  assert.ok(result.examples.length > 25, `only ${result.examples.length} examples`);
});

test("every example type-checks against the device types", () => {
  // Each example is its own module (top-level await is allowed). The page
  // says examples skip the `device` check and use a `player`, so those are
  // declared here.
  const dir = join(root, "docs", ".reference-examples");
  const prelude = [
    'import type { Device, SoundPlayer } from "../../src/device.ts";',
    "declare const device: Device;",
    "declare const player: SoundPlayer;",
  ].join("\n");
  const files = new Map(result.examples.map((e, i) => [join(dir, `example-${i}.ts`), `${prelude}\n${e.code}\nexport {};\n`]));
  const options: ts.CompilerOptions = {
    target: ts.ScriptTarget.ESNext,
    module: ts.ModuleKind.NodeNext,
    moduleResolution: ts.ModuleResolutionKind.NodeNext,
    lib: ["lib.esnext.d.ts", "lib.dom.d.ts"],
    strict: true,
    noEmit: true,
    allowImportingTsExtensions: true,
    erasableSyntaxOnly: true,
    skipLibCheck: true,
    types: ["node"],
  };
  const host = ts.createCompilerHost(options);
  const { fileExists, readFile, getSourceFile } = host;
  host.fileExists = (f) => files.has(f) || fileExists.call(host, f);
  host.readFile = (f) => files.get(f) ?? readFile.call(host, f);
  host.getSourceFile = (f, lang, ...rest) => {
    const text = files.get(f);
    return text === undefined ? getSourceFile.call(host, f, lang, ...rest) : ts.createSourceFile(f, text, lang);
  };
  const program = ts.createProgram([join(root, "src", "globals.ts"), ...files.keys()], options, host);
  const errors = ts.getPreEmitDiagnostics(program).map((d) => {
    const file = d.file?.fileName ?? "";
    const i = [...files.keys()].indexOf(file);
    const where = i >= 0 ? result.examples[i].where : file;
    return `${where}: ${ts.flattenDiagnosticMessageText(d.messageText, "\n")}`;
  });
  assert.deepEqual(errors, []);
});
