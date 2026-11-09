// device.contacts over a fake transport: what crosses the wire, and how
// replies are read.
import { test } from "node:test";
import assert from "node:assert/strict";
import { createDevice, DeviceError, type DeviceTransport } from "../src/mod.ts";

const METHODS = ["contacts.authorizationStatus", "contacts.requestAuthorization", "contacts.search", "contacts.get", "contacts.all", "contacts.add", "contacts.delete"];

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
const ADA = { id: "1", givenName: "Ada", familyName: "Lovelace", emails: [{ label: "work", value: "ada@example.com" }], birthday: "1815-12-10" };

test("search sends the query and reads contacts, keeping only known fields of the right types", async () => {
  const { device, sent } = host({
    "contacts.search": () => [
      { ...ADA, extra: 1, nickname: 3, phones: [{ value: "+1 555" }, { label: "home" }, "x"], addresses: [{ city: "London", zip: 1 }, "x"] },
    ],
  });
  assert.deepEqual(await device.contacts.search("Ada"), [{ ...ADA, phones: [{ value: "+1 555" }], addresses: [{ city: "London" }] }]);
  assert.deepEqual(sent, [{ method: "contacts.search", params: { query: "Ada" } }]);
});

test("get reads one contact, or null", async () => {
  assert.deepEqual(await host({ "contacts.get": () => ADA }).device.contacts.get("1"), ADA);
  assert.equal(await host({ "contacts.get": () => null }).device.contacts.get("2"), null);
});

test("add sends the contact without an id and answers the new id", async () => {
  const { device, sent } = host({ "contacts.add": () => "new" });
  const { id: _, ...fields } = ADA;
  assert.equal(await device.contacts.add({ ...fields, id: "ignored" } as typeof fields), "new");
  assert.deepEqual(sent, [{ method: "contacts.add", params: { contact: fields } }]);
});

test("delete answers whether a contact was deleted", async () => {
  assert.equal(await host({ "contacts.delete": () => true }).device.contacts.delete("1"), true);
  assert.equal(await host({ "contacts.delete": () => false }).device.contacts.delete("1"), false);
});

test("bad arguments fail before asking the host", async () => {
  const { device, sent } = host({});
  await assert.rejects(device.contacts.search(" "), isCode("failed"));
  await assert.rejects(device.contacts.get(""), isCode("failed"));
  await assert.rejects(device.contacts.delete(3 as unknown as string), isCode("failed"));
  await assert.rejects(device.contacts.add(null as unknown as { givenName: string }), isCode("failed"));
  assert.equal(sent.length, 0);
});

test("malformed replies fail", async () => {
  for (const [method, reply] of [
    ["contacts.all", null],
    ["contacts.all", [{ givenName: "no id" }]],
    ["contacts.get", "x"],
    ["contacts.add", 3],
    ["contacts.delete", "yes"],
  ] as const) {
    const { device } = host({ [method]: () => reply });
    const run = { "contacts.all": () => device.contacts.all(), "contacts.get": () => device.contacts.get("1"), "contacts.add": () => device.contacts.add({ givenName: "a" }), "contacts.delete": () => device.contacts.delete("1") }[method];
    await assert.rejects(run(), isCode("failed"), method);
  }
});
