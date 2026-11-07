// The Swift bridge keeps its own list of the remote subset
// (DeviceBridge.remoteMethods, swift/Sources/DeviceBridge/Remote.swift);
// this checks it against SUPPORT, the one source of truth, so the two
// can't drift.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { REMOTE_METHODS } from "../src/comm.ts";

test("DeviceBridge.remoteMethods is SUPPORT's remote subset", () => {
  const source = readFileSync(new URL("../swift/Sources/DeviceBridge/Remote.swift", import.meta.url), "utf8");
  const list = source.match(/remoteMethods: Set<String> = \[([^\]]*)\]/);
  assert.ok(list, "remoteMethods not found in Remote.swift");
  const swift = [...list[1].matchAll(/"([^"]+)"/g)].map((m) => m[1]).sort();
  assert.deepEqual(swift, [...REMOTE_METHODS].sort());
});
