// device.notifications over a fake transport: what crosses the wire, and
// how replies are read.
import { test } from "node:test";
import assert from "node:assert/strict";
import { createDevice, DeviceError, type DeviceTransport, SUPPORT } from "../src/mod.ts";

const METHODS = [
  "notifications.authorizationStatus",
  "notifications.requestAuthorization",
  "notifications.schedule",
  "notifications.pending",
  "notifications.cancel",
  "notifications.cancelAll",
];

function host(answers: Record<string, (params: Record<string, unknown>) => unknown>, capabilities = METHODS) {
  const sent: { method: string; params: Record<string, unknown> }[] = [];
  const transport: DeviceTransport = {
    async call(method, params) {
      sent.push({ method, params });
      const answer = answers[method];
      if (!answer) throw new DeviceError("unavailable", `no ${method}`);
      return answer(params);
    },
  };
  return { device: createDevice(transport, { platform: "macos", appVersion: "", capabilities }), sent };
}

const isCode = (code: string) => (err: unknown) => err instanceof DeviceError && err.code === code;

test("schedule sends body, delay and title, and resolves with the id", async () => {
  const { device, sent } = host({ "notifications.schedule": () => "abc" });
  assert.equal(await device.notifications.schedule("Drink water", { delay: 60, title: "Break" }), "abc");
  assert.equal(await device.notifications.schedule("No title", { delay: 0.5 }), "abc");
  assert.deepEqual(sent, [
    { method: "notifications.schedule", params: { body: "Drink water", delay: 60, title: "Break" } },
    { method: "notifications.schedule", params: { body: "No title", delay: 0.5 } },
  ]);
});

test("schedule checks its arguments before asking the host", async () => {
  const { device, sent } = host({ "notifications.schedule": () => "abc" });
  const n = device.notifications;
  await assert.rejects(n.schedule("", { delay: 1 }), isCode("failed"));
  await assert.rejects(n.schedule(42 as unknown as string, { delay: 1 }), isCode("failed"));
  await assert.rejects(n.schedule("x", { delay: 0 }), isCode("failed"));
  await assert.rejects(n.schedule("x", { delay: -5 }), isCode("failed"));
  await assert.rejects(n.schedule("x", { delay: Infinity }), isCode("failed"));
  await assert.rejects(n.schedule("x", {} as { delay: number }), isCode("failed"));
  await assert.rejects(n.schedule("x", undefined as unknown as { delay: number }), isCode("failed"));
  await assert.rejects(n.schedule("x", { delay: 1, title: 3 as unknown as string }), isCode("failed"));
  await assert.rejects(n.cancel(""), isCode("failed"));
  assert.equal(sent.length, 0);
});

test("a malformed schedule reply fails", async () => {
  const { device } = host({ "notifications.schedule": () => 7 });
  await assert.rejects(device.notifications.schedule("x", { delay: 1 }), isCode("failed"));
});

test("a refusal arrives as denied", async () => {
  const { device } = host({
    "notifications.schedule": () => {
      throw new DeviceError("denied", "not allowed");
    },
  });
  await assert.rejects(device.notifications.schedule("x", { delay: 1 }), isCode("denied"));
});

test("pending reads ids, bodies, titles and dates", async () => {
  const { device } = host({
    "notifications.pending": () => [
      { id: "a", body: "one", title: "T", date: "2026-11-09T10:00:00Z" },
      { id: "b", body: "two", date: "not a date" },
    ],
  });
  assert.deepEqual(await device.notifications.pending(), [
    { id: "a", body: "one", title: "T", date: new Date("2026-11-09T10:00:00Z") },
    { id: "b", body: "two" },
  ]);
});

test("a malformed pending reply fails", async () => {
  for (const reply of [null, {}, [{ id: 1, body: "x" }], [{ id: "a" }]]) {
    const { device } = host({ "notifications.pending": () => reply });
    await assert.rejects(device.notifications.pending(), isCode("failed"), JSON.stringify(reply));
  }
});

test("cancel and cancelAll send what the host needs", async () => {
  const { device, sent } = host({ "notifications.cancel": () => null, "notifications.cancelAll": () => null });
  await device.notifications.cancel("abc");
  await device.notifications.cancelAll();
  assert.deepEqual(sent, [
    { method: "notifications.cancel", params: { id: "abc" } },
    { method: "notifications.cancelAll", params: {} },
  ]);
});

test("notifications has the permission trio", async () => {
  const { device, sent } = host({
    "notifications.authorizationStatus": () => "notDetermined",
    "notifications.requestAuthorization": () => "authorized",
  });
  assert.equal(await device.notifications.authorizationStatus(), "notDetermined");
  assert.equal(await device.notifications.requestAuthorization(), "authorized");
  assert.deepEqual(sent.map((s) => s.method), ["notifications.authorizationStatus", "notifications.requestAuthorization"]);
});

test("on a host without notifications every call is unavailable", async () => {
  const { device, sent } = host({}, []);
  await assert.rejects(device.notifications.schedule("x", { delay: 1 }), isCode("unavailable"));
  await assert.rejects(device.notifications.pending(), isCode("unavailable"));
  await assert.rejects(device.notifications.authorizationStatus(), isCode("unavailable"));
  assert.equal(sent.length, 0);
});

test("only schedule needs the permission; all are on-device only", () => {
  const rows = Object.entries(SUPPORT).filter(([method]) => method.startsWith("notifications."));
  assert.deepEqual(rows.map(([m]) => m).sort(), ["notifications.cancel", "notifications.cancelAll", "notifications.pending", "notifications.schedule"]);
  for (const [method, row] of rows) {
    assert.equal(row.remote, "no", method);
    assert.equal(row.browser, "no", method);
    assert.equal("permission" in row ? row.permission : undefined, method === "notifications.schedule" ? "notifications" : undefined, method);
  }
});
