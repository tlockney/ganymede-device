// A run's input and output, and device.widget, over a fake transport.
import { test } from "node:test";
import assert from "node:assert/strict";
import { createDevice, DeviceError, type DeviceTransport } from "../src/mod.ts";
import { installHostDevice } from "../src/host.ts";

function host(answers: Record<string, (params: Record<string, unknown>) => unknown>, capabilities = Object.keys(answers)) {
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

test("a notebook has no input, and output is unavailable", async () => {
  const { device, sent } = host({});
  assert.equal(device.input, null);
  await assert.rejects(device.output({ text: "a" }), isCode("unavailable"));
  assert.equal(sent.length, 0);
});

test("output sends text, a url and files as bytes", async () => {
  const { device, sent } = host({ "output": () => null });
  await device.output({ text: "sum", url: new URL("https://example.com/"), files: [{ name: "a.txt", data: new Uint8Array([1, 2]) }] });
  assert.deepEqual(sent[0], { method: "output", params: { text: "sum", url: "https://example.com/", files: [{ name: "a.txt", data: new Uint8Array([1, 2]) }] } });
  await assert.rejects(device.output({}), isCode("failed"));
  await assert.rejects(device.output({ files: [{ name: "a/b", data: new Uint8Array() }] }), isCode("failed"));
});

test("the engine preload reads the run's input after hello", async () => {
  const replies: Record<string, unknown> = {
    hello: { platform: "ios", appVersion: "1", capabilities: ["input", "output"] },
    "input": { text: "hi", url: "https://example.com/", files: [{ name: "p.png", type: "image/png", data: { base64: "AQI=" } }] },
  };
  const post = async (message: string) => {
    const { method } = JSON.parse(message) as { method: string };
    return JSON.stringify({ result: replies[method] ?? null });
  };
  const device = await installHostDevice(post);
  assert.deepEqual(device?.input, { text: "hi", url: "https://example.com/", files: [{ name: "p.png", type: "image/png", data: new Uint8Array([1, 2]) }] });
  delete (globalThis as { device?: unknown }).device;
});

test("a context without input gets null", async () => {
  const post = async () => JSON.stringify({ result: { platform: "ios", appVersion: "1", capabilities: [] } });
  const device = await installHostDevice(post);
  assert.equal(device?.input, null);
  delete (globalThis as { device?: unknown }).device;
});

test("widget.update sends the checked content and drops unknown parts", async () => {
  const { device, sent } = host({ "widget.update": () => null });
  await device.widget.update("weather", {
    title: "Oslo",
    rows: [{ label: "Now", value: 4, unit: "°C" }, { text: "Rain" }],
    tint: "blue",
    sparkline: [1, 2, 3],
    extra: true,
  } as never);
  assert.deepEqual(sent[0].params, {
    kind: "weather",
    content: { title: "Oslo", rows: [{ label: "Now", value: 4, unit: "°C" }, { text: "Rain" }], tint: "blue", sparkline: [1, 2, 3] },
  });
});

test("bad widget kinds and content fail before asking the host", async () => {
  const { device, sent } = host({ "widget.update": () => null });
  const bad = [
    () => device.widget.update("", {}),
    () => device.widget.update("a b", {}),
    () => device.widget.update("a", null as never),
    () => device.widget.update("a", { title: "x".repeat(65) }),
    () => device.widget.update("a", { rows: Array(7).fill({ text: "a" }) }),
    () => device.widget.update("a", { rows: [{ value: Infinity }] }),
    () => device.widget.update("a", { rows: [{}] as never }),
    () => device.widget.update("a", { tint: "chartreuse" as never }),
    () => device.widget.update("a", { sparkline: Array(65).fill(1) }),
    () => device.widget.update("a", { sparkline: [Number.NaN] }),
  ];
  for (const call of bad) await assert.rejects(call(), isCode("failed"));
  assert.equal(sent.length, 0);
});
