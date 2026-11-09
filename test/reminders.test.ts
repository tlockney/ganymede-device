// device.reminders over a fake transport: what crosses the wire, and how
// replies are read.
import { test } from "node:test";
import assert from "node:assert/strict";
import { createDevice, DeviceError, type DeviceTransport } from "../src/mod.ts";

const METHODS = ["reminders.calendars", "reminders.list", "reminders.add", "reminders.complete", "reminders.uncomplete", "reminders.delete"];

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
  return { device: createDevice(transport, { platform: "macos", appVersion: "", capabilities: METHODS }), sent };
}

const isCode = (code: string) => (err: unknown) => err instanceof DeviceError && err.code === code;
const MILK = { id: "r1", title: "Buy milk", calendar: "inbox", completed: false, due: "2026-11-10", priority: 1 };

test("calendars reads the lists", async () => {
  const { device } = host({ "reminders.calendars": () => [{ id: "inbox", title: "Reminders", isDefault: true, extra: 1 }, { id: "shop", title: "Shopping" }] });
  assert.deepEqual(await device.reminders.calendars(), [
    { id: "inbox", title: "Reminders", isDefault: true },
    { id: "shop", title: "Shopping", isDefault: false },
  ]);
});

test("list sends its filters and reads reminders, keeping only known parts of the right types", async () => {
  const { device, sent } = host({ "reminders.list": () => [{ ...MILK, notes: 3, extra: "x", priority: 1.5 }] });
  assert.deepEqual(await device.reminders.list({ calendar: "inbox", completed: false }), [{ id: "r1", title: "Buy milk", calendar: "inbox", completed: false, due: "2026-11-10" }], "a fractional priority is dropped");
  await device.reminders.list();
  assert.deepEqual(
    sent.map((m) => m.params),
    [{ calendar: "inbox", completed: false }, {}],
  );
});

test("add sends the reminder, a Date due as ISO 8601", async () => {
  const { device, sent } = host({ "reminders.add": () => "r2" });
  assert.equal(await device.reminders.add({ title: "Call", due: new Date(Date.UTC(2026, 10, 10, 17, 30)), priority: 5 }), "r2");
  assert.deepEqual(sent[0]!.params, { reminder: { title: "Call", due: "2026-11-10T17:30:00.000Z", priority: 5 } });
});

test("complete, uncomplete and delete answer whether there was a reminder", async () => {
  const { device, sent } = host({ "reminders.complete": () => true, "reminders.uncomplete": () => false, "reminders.delete": () => true });
  assert.equal(await device.reminders.complete("r1"), true);
  assert.equal(await device.reminders.uncomplete("r1"), false);
  assert.equal(await device.reminders.delete("r1"), true);
  assert.deepEqual(sent.map((m) => m.params), [{ id: "r1" }, { id: "r1" }, { id: "r1" }]);
});

test("bad arguments fail before asking the host", async () => {
  const { device, sent } = host({});
  await assert.rejects(device.reminders.list({ completed: "yes" as unknown as boolean }), isCode("failed"));
  await assert.rejects(device.reminders.list({ calendar: "" }), isCode("failed"));
  await assert.rejects(device.reminders.add(null as unknown as { title: string }), isCode("failed"));
  await assert.rejects(device.reminders.complete(""), isCode("failed"));
  await assert.rejects(device.reminders.delete(1 as unknown as string), isCode("failed"));
  assert.equal(sent.length, 0);
});

test("malformed replies fail", async () => {
  await assert.rejects(host({ "reminders.calendars": () => [{ id: 1 }] }).device.reminders.calendars(), isCode("failed"));
  await assert.rejects(host({ "reminders.list": () => [{ id: "r", title: "t" }] }).device.reminders.list(), isCode("failed"));
  await assert.rejects(host({ "reminders.add": () => null }).device.reminders.add({ title: "a" }), isCode("failed"));
  await assert.rejects(host({ "reminders.delete": () => "yes" }).device.reminders.delete("r"), isCode("failed"));
});
