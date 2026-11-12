// The Swift bridge keeps its own list of the remote subset
// (DeviceBridge.remoteMethods, swift/Sources/DeviceBridge/Remote.swift);
// this checks it against SUPPORT, the one source of truth, so the two
// can't drift.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readdirSync, readFileSync } from "node:fs";
import { REMOTE_METHODS } from "../src/comm.ts";
import { SUPPORT, type SupportRow } from "../src/support.ts";

test("DeviceBridge.remoteMethods is SUPPORT's remote subset", () => {
  const source = readFileSync(new URL("../swift/Sources/DeviceBridge/Remote.swift", import.meta.url), "utf8");
  const list = source.match(/remoteMethods: Set<String> = \[([^\]]*)\]/);
  assert.ok(list, "remoteMethods not found in Remote.swift");
  const swift = [...list[1].matchAll(/"([^"]+)"/g)].map((m) => m[1]).sort();
  assert.deepEqual(swift, [...REMOTE_METHODS].sort());
});

test("the methods a headless run can't call are Swift's dialogs and foreground methods, as SUPPORT says", () => {
  const dir = new URL("../swift/Sources/DeviceBridge/", import.meta.url);
  const bridge = readFileSync(new URL("DeviceBridge.swift", dir), "utf8");
  const list = bridge.match(/dialogMethods: Set<String> = \[([^\]]*)\]/);
  assert.ok(list, "dialogMethods not found in DeviceBridge.swift");
  const swift = new Set([...list[1].matchAll(/"([^"]+)"/g)].map((m) => m[1]));
  // And the dialogs a namespace adds (addDialog, addPermissionedDialog),
  // and the methods that bring another app forward (foregroundMethods).
  for (const file of readdirSync(dir).filter((name) => name.endsWith(".swift"))) {
    const source = readFileSync(new URL(file, dir), "utf8");
    for (const m of source.matchAll(/add(?:Permissioned)?Dialog\("([^"]+)"/g)) swift.add(m[1]);
    for (const m of source.matchAll(/foregroundMethods\.insert\("([^"]+)"\)/g)) swift.add(m[1]);
  }
  const support = Object.entries(SUPPORT)
    .filter(([, row]) => (row as SupportRow).headless === "no")
    .map(([method]) => method);
  assert.deepEqual([...swift].sort(), support.sort());
});
