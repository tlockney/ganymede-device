// device.shortcuts over a fake transport: what crosses the wire, and how
// replies are read.
import { test } from "node:test";
import assert from "node:assert/strict";
import { createDevice, DeviceError, type DeviceTransport } from "../src/mod.ts";

const METHODS = ["shortcuts.run", "shortcuts.authorizationStatus", "shortcuts.requestAuthorization"];

function host(answers: Record<string, (params: Record<string, unknown>) => unknown>) {
  const sent: { method: string; params: Record<string, unknown> }[] = [];
  const transport: DeviceTransport = {
    async call(method, params) {
      sent.push({ method, params });
      const answer = answers[method];
      if (!answer) throw new DeviceError("unavailable", `no ${method}`);
      return answer(params);
    },
  };
  return { device: createDevice(transport, { platform: "ios", appVersion: "", capabilities: METHODS }), sent };
}

const isCode = (code: string) => (err: unknown) => err instanceof DeviceError && err.code === code;

test("run sends the name and input and returns the Shortcut's output", async () => {
  const { device, sent } = host({ "shortcuts.run": ({ input }) => (typeof input === "string" ? input.toUpperCase() : null) });
  assert.equal(await device.shortcuts.run("Make Uppercase", { input: "hi" }), "HI");
  assert.equal(await device.shortcuts.run("Ping"), null);
  assert.deepEqual(sent, [
    { method: "shortcuts.run", params: { name: "Make Uppercase", input: "hi" } },
    { method: "shortcuts.run", params: { name: "Ping" } },
  ]);
});

test("a cancel or failure from the host rejects with its code", async () => {
  const cancelled = host({ "shortcuts.run": () => { throw new DeviceError("cancelled", "shortcuts.run: the Shortcut was cancelled"); } });
  await assert.rejects(cancelled.device.shortcuts.run("A"), isCode("cancelled"));
  const failed = host({ "shortcuts.run": () => { throw new DeviceError("failed", "shortcuts.run: No such shortcut"); } });
  await assert.rejects(failed.device.shortcuts.run("A"), (err) => isCode("failed")(err) && /No such shortcut/.test((err as Error).message));
});

test("bad names and inputs fail before asking the host", async () => {
  const { device, sent } = host({});
  await assert.rejects(device.shortcuts.run(""), isCode("failed"));
  await assert.rejects(device.shortcuts.run(3 as unknown as string), isCode("failed"));
  await assert.rejects(device.shortcuts.run("x".repeat(257)), isCode("failed"));
  await assert.rejects(device.shortcuts.run("A", { input: 4 as unknown as string }), isCode("failed"));
  await assert.rejects(device.shortcuts.run("A", { input: "x".repeat(64 * 1024 + 1) }), isCode("failed"));
  assert.equal(sent.length, 0);
});

test("a malformed reply fails", async () => {
  await assert.rejects(host({ "shortcuts.run": () => 3 }).device.shortcuts.run("A"), isCode("failed"));
});
