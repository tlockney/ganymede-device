// The engine transport (src/host.ts): test/device.test.ts's end-to-end
// tests again, installed through a host function instead of the Worker,
// then what is particular to it.
import { test } from "node:test";
import assert from "node:assert/strict";
import { getEventListeners } from "node:events";
import { hostFunctionTransport, installHostDevice } from "../src/host.ts";
import { DeviceError } from "../src/errors.ts";

(globalThis as { deviceTestTransport?: string }).deviceTestTransport = "host";
await import("./device.test.ts");

type Message = { id?: number; owner?: number; method?: string; params?: Record<string, unknown>; cancel?: true; release?: true };

function engine(answer: (msg: Message) => unknown) {
  const sent: Message[] = [];
  const post = async (text: string) => {
    assert.equal(typeof text, "string", "messages cross as JSON text");
    const msg = JSON.parse(text) as Message;
    sent.push(msg);
    return JSON.stringify(await answer(msg));
  };
  return { sent, post };
}

test("each transport counts its own ids, and release names no call", async () => {
  const { sent, post } = engine(() => ({ result: "x" }));
  const one = hostFunctionTransport(post);
  const two = hostFunctionTransport(post);
  await one.call("clipboard.readText", {});
  await two.call("clipboard.readText", {});
  await one.call("clipboard.readText", {});
  assert.deepEqual(sent.map((m) => m.id), [1, 1, 2], "Swift keeps each context's ids apart");
  one.release();
  await new Promise((resolve) => setTimeout(resolve, 0));
  assert.deepEqual(sent.at(-1), { owner: 1, release: true });
});

test("a reply that isn't JSON fails the call", async () => {
  const transport = hostFunctionTransport(async () => "<html>");
  await assert.rejects(transport.call("info", {}), (err) => err instanceof DeviceError && err.code === "failed");
});

test("an abort rejects at once, even if the host never answers", async () => {
  const { sent, post } = engine((msg) => (msg.cancel ? null : new Promise(() => {})));
  const transport = hostFunctionTransport(post);
  const controller = new AbortController();
  const pending = transport.call("ui.alert", { message: "hi" }, { signal: controller.signal });
  await new Promise((resolve) => setTimeout(resolve, 0));
  controller.abort();
  await assert.rejects(pending, (err) => err instanceof DeviceError && err.code === "cancelled");
  assert.deepEqual(sent.at(-1), { id: 1, cancel: true });
  // What AbortSignal.timeout() aborts with (its own timer doesn't keep
  // Node's event loop alive).
  const timer = new AbortController();
  const timeout = transport.call("ui.alert", { message: "hi" }, { signal: timer.signal });
  timer.abort(new DOMException("timed out", "TimeoutError"));
  await assert.rejects(timeout, (err) => err instanceof DeviceError && err.code === "timeout");
});

test("a call takes its listeners off a shared signal once it settles", async () => {
  const { post } = engine(() => ({ result: "x" }));
  const transport = hostFunctionTransport(post);
  const cell = new AbortController();
  for (let i = 0; i < 5; i++) await transport.call("clipboard.readText", {}, { signal: cell.signal });
  assert.equal(getEventListeners(cell.signal, "abort").length, 0);
});

test("without a host function, nothing is installed", async () => {
  delete (globalThis as { device?: unknown }).device;
  assert.equal(await installHostDevice(undefined), undefined);
  assert.equal((globalThis as { device?: unknown }).device, undefined);
});

test("the cell's signal reaches every call", async () => {
  const hello = { result: { platform: "ipados", appVersion: "0.1", capabilities: ["ui.alert"] } };
  const { sent, post } = engine((msg) => (msg.method === "hello" ? hello : msg.cancel ? null : new Promise(() => {})));
  const cell = new AbortController();
  const device = await installHostDevice(post, { cellSignal: () => cell.signal });
  assert.ok(device);
  const pending = device.ui.alert("hi");
  await new Promise((resolve) => setTimeout(resolve, 0));
  cell.abort();
  await assert.rejects(pending, (err) => err instanceof DeviceError && err.code === "cancelled");
  assert.equal(sent.at(-1)?.cancel, true);
});
