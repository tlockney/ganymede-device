// device.secrets over a fake transport: what crosses the wire, and how
// replies are read.
import { test } from "node:test";
import assert from "node:assert/strict";
import { createDevice, DeviceError, type DeviceTransport } from "../src/mod.ts";

const METHODS = ["secrets.get", "secrets.set", "secrets.delete", "secrets.list", "secrets.authorizationStatus", "secrets.requestAuthorization"];

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

test("get, set, delete and list send the name and value and read the replies", async () => {
  const saved = new Map<string, string>();
  const { device, sent } = host({
    "secrets.get": ({ name }) => saved.get(name as string) ?? null,
    "secrets.set": ({ name, value }) => (saved.set(name as string, value as string), null),
    "secrets.delete": ({ name }) => saved.delete(name as string),
    "secrets.list": () => [...saved.keys()].sort(),
  });
  assert.equal(await device.secrets.get("github"), null);
  assert.equal(await device.secrets.set("github", "tok"), undefined);
  assert.equal(await device.secrets.get("github"), "tok");
  assert.deepEqual(await device.secrets.list(), ["github"]);
  assert.equal(await device.secrets.delete("github"), true);
  assert.equal(await device.secrets.delete("github"), false);
  assert.deepEqual(sent[1], { method: "secrets.set", params: { name: "github", value: "tok" } });
});

test("bad names and values fail before asking the host", async () => {
  const { device, sent } = host({});
  await assert.rejects(device.secrets.get(""), isCode("failed"));
  await assert.rejects(device.secrets.get("x".repeat(129)), isCode("failed"));
  await assert.rejects(device.secrets.get("a\0b"), isCode("failed"));
  await assert.rejects(device.secrets.get("a\uD800"), isCode("failed"), "a lone surrogate");
  await assert.rejects(device.secrets.get("\uDC00a"), isCode("failed"));
  await assert.rejects(device.secrets.delete(1 as unknown as string), isCode("failed"));
  await assert.rejects(device.secrets.set("a", 1 as unknown as string), isCode("failed"));
  await assert.rejects(device.secrets.set("a", "é".repeat(32 * 1024 + 1)), isCode("failed"), "64 KiB counts UTF-8 bytes");
  assert.equal(sent.length, 0);
  await assert.rejects(device.secrets.get("😀"), isCode("unavailable"), "a pair is fine");
  await assert.rejects(device.secrets.set("a", "x".repeat(64 * 1024)), isCode("unavailable"), "exactly 64 KiB reaches the host");
});

test("malformed replies fail", async () => {
  await assert.rejects(host({ "secrets.get": () => 3 }).device.secrets.get("a"), isCode("failed"));
  await assert.rejects(host({ "secrets.delete": () => null }).device.secrets.delete("a"), isCode("failed"));
  await assert.rejects(host({ "secrets.list": () => ["a", 1] }).device.secrets.list(), isCode("failed"));
});

test("the permission trio asks the host", async () => {
  const { device } = host({ "secrets.authorizationStatus": () => "notDetermined", "secrets.requestAuthorization": () => "authorized" });
  assert.equal(await device.secrets.authorizationStatus(), "notDetermined");
  assert.equal(await device.secrets.requestAuthorization(), "authorized");
});
