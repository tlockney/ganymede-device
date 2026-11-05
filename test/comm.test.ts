// The remote transport against a fake `jupyter.comm` and a fake app
// frontend: the announce, the calls comm the app opens back, replies,
// cancels, a second app turned away, and the app going away.
import { test } from "node:test";
import assert from "node:assert/strict";
import {
  ANNOUNCE_TARGET,
  CALLS_TARGET,
  type CommApiLike,
  type CommLike,
  type CommMessageLike,
  connectDevice,
  REMOTE_METHODS,
} from "../src/comm.ts";
import { DeviceError } from "../src/errors.ts";

class FakeComm implements CommLike {
  closed = false;
  sent: Record<string, unknown>[] = [];
  closedWith: Record<string, unknown> | undefined;
  #onMsg: ((msg: CommMessageLike) => void)[] = [];
  #onClose: ((msg: CommMessageLike) => void)[] = [];
  /** What the other end gets: the app's handler for kernel sends. */
  peer: ((data: Record<string, unknown>) => void) | undefined;

  send(data: Record<string, unknown> = {}): void {
    if (this.closed) throw new Error("send on a closed comm");
    this.sent.push(data);
    this.peer?.(data);
  }
  close(data: Record<string, unknown> = {}): void {
    if (this.closed) return;
    this.closed = true;
    this.closedWith = data;
  }
  onMsg(handler: (msg: CommMessageLike) => void): void {
    this.#onMsg.push(handler);
  }
  onClose(handler: (msg: CommMessageLike) => void): void {
    this.#onClose.push(handler);
  }
  /** A message from the other end. */
  receive(data: Record<string, unknown>): void {
    for (const h of this.#onMsg) h({ data });
  }
  /** The other end closes it. */
  remoteClose(): void {
    this.closed = true;
    for (const h of this.#onClose) h({ data: {} });
  }
}

const HELLO = { platform: "ipados", appVersion: "0.3", capabilities: ["clipboard.readText", "clipboard.writeText", "secrets.get", "sound.player"] };

/**
 * cdp-kernel's comm API with an app on the other side: on each announce it
 * opens a calls comm back (when `answer` is on), and answers calls with
 * `reply`, from a microtask, as a websocket would.
 */
function fakeKernel(options: { answer?: boolean; reply?: (msg: Record<string, unknown>) => Record<string, unknown> | null } = {}) {
  let target: ((comm: CommLike, msg: CommMessageLike) => void) | undefined;
  const announces: FakeComm[] = [];
  const calls: FakeComm[] = [];
  const state = { answer: options.answer ?? true, pong: true, registered: 0 };
  const api: CommApiLike = {
    open(name, data) {
      assert.equal(name, ANNOUNCE_TARGET);
      assert.deepEqual(data, { protocol: 1 });
      const announce = new FakeComm();
      announces.push(announce);
      if (state.answer) queueMicrotask(() => openCalls());
      return announce;
    },
    registerTarget(name, handler) {
      assert.equal(name, CALLS_TARGET);
      state.registered++;
      target = handler;
    },
  };
  function openCalls(hello: Record<string, unknown> = HELLO): FakeComm {
    const comm = new FakeComm();
    comm.peer = (data) => {
      if (data.cancel) return;
      if (typeof data.ping === "number") {
        if (state.pong) queueMicrotask(() => comm.receive({ pong: data.ping }));
        return;
      }
      const answer = options.reply?.(data);
      if (answer) queueMicrotask(() => comm.receive({ id: data.id, ...answer }));
    };
    calls.push(comm);
    target!(comm, { data: hello });
    return comm;
  }
  return { api, announces, calls, state, openCalls };
}

test("connectDevice announces, takes the app's calls comm, and offers only the remote subset", async () => {
  const kernel = fakeKernel({ reply: (msg) => (msg.method === "clipboard.readText" ? { result: "from the iPad" } : { result: null }) });
  const device = await connectDevice(kernel.api);
  assert.equal(kernel.announces.length, 1);
  assert.equal(kernel.announces[0].closed, true, "the announce closes once answered");
  assert.equal(device.has("clipboard.readText"), true);
  assert.equal(device.has("secrets.get"), false, "not in SUPPORT, so not remote");
  assert.equal(device.has("sound.player"), false);
  assert.equal(await device.clipboard.readText(), "from the iPad");
  assert.deepEqual(kernel.calls[0].sent[0], { id: 1, method: "clipboard.readText", params: {} });
  assert.equal((await device.info()).platform, "ipados");
  assert.ok(REMOTE_METHODS.has("clipboard.readText") && !REMOTE_METHODS.has("hello"));
});

test("with no app answering, connectDevice gives a device whose calls reject unavailable", async () => {
  const kernel = fakeKernel({ answer: false });
  const device = await connectDevice(kernel.api, { timeoutMs: 20 });
  assert.equal(kernel.announces[0].closed, true);
  await assert.rejects(device.clipboard.readText(), (err) => err instanceof DeviceError && err.code === "unavailable");
});

test("errors carry their code, binary results decode, and a late or second app is turned away", async () => {
  const kernel = fakeKernel({
    reply: (msg) =>
      msg.method === "clipboard.readImage" ? { result: { base64: "AQI=" } } : { error: { code: "denied", message: "no" } },
  });
  const device = await connectDevice(kernel.api);
  await assert.rejects(device.clipboard.writeText("x"), (err) => err instanceof DeviceError && err.code === "denied" && err.message === "no");
  const second = kernel.openCalls();
  assert.deepEqual(second.closedWith, { error: "taken" });
  kernel.calls[0].peer = (data) => {
    if (typeof data.ping === "number") return;
    queueMicrotask(() => kernel.calls[0].receive(data.id === 3 ? { id: 3, error: "denied" } : { id: data.id, result: { base64: "!!" } }));
  };
  await assert.rejects(device.clipboard.readText(), (err) => err instanceof DeviceError && err.code === "failed", "a result that fails to decode rejects");
  await assert.rejects(device.clipboard.readText(), (err) => err instanceof DeviceError && err.code === "failed" && err.message === "denied");
  const bad = kernel.openCalls({ nonsense: true });
  assert.equal(bad.closed, true);
});

test("an abort sends a cancel and rejects at once; a late reply is dropped", async () => {
  const kernel = fakeKernel({ reply: () => null });
  const device = await connectDevice(kernel.api);
  const controller = new AbortController();
  const pending = device.clipboard.readText({ signal: controller.signal });
  await new Promise((resolve) => setTimeout(resolve, 0));
  controller.abort();
  await assert.rejects(pending, (err) => err instanceof DeviceError && err.code === "cancelled");
  assert.deepEqual(kernel.calls[0].sent.at(-1), { id: 1, cancel: true });
  kernel.calls[0].receive({ id: 1, result: "late" });
  // What AbortSignal.timeout() aborts with; its own timer doesn't keep the test alive.
  const timeout = new AbortController();
  setTimeout(() => timeout.abort(new DOMException("timed out", "TimeoutError")), 5);
  await assert.rejects(
    device.clipboard.readText({ signal: timeout.signal }),
    (err) => err instanceof DeviceError && err.code === "timeout",
  );
});

test("when the app goes away, calls in flight reject disconnected and the next call announces again", async () => {
  const kernel = fakeKernel({ reply: (msg) => (msg.method === "clipboard.readText" && msg.id !== 1 ? { result: "back" } : null) });
  const device = await connectDevice(kernel.api, { timeoutMs: 20 });
  const pending = device.clipboard.readText();
  await new Promise((resolve) => setTimeout(resolve, 0));
  kernel.calls[0].remoteClose();
  await assert.rejects(pending, (err) => err instanceof DeviceError && err.code === "disconnected");
  assert.equal(await device.clipboard.readText(), "back");
  assert.equal(kernel.announces.length, 2);
  assert.equal(kernel.calls.length, 2);
  kernel.calls[1].remoteClose();
  kernel.state.answer = false;
  await assert.rejects(device.clipboard.readText(), (err) => err instanceof DeviceError && err.code === "disconnected");
});

const tick = (ms = 0) => new Promise((resolve) => setTimeout(resolve, ms));

test("connecting again from another cell reuses the link and its calls target", async () => {
  const kernel = fakeKernel({ reply: () => ({ result: "ok" }) });
  const first = await connectDevice(kernel.api);
  const second = await connectDevice(kernel.api);
  assert.equal(kernel.state.registered, 1);
  assert.equal(kernel.announces.length, 1, "the open calls comm is reused");
  assert.equal(await first.clipboard.readText(), "ok");
  assert.equal(await second.clipboard.readText(), "ok");
});

test("an app that answers pings keeps a slow call alive; one that goes silent is dropped", async () => {
  const kernel = fakeKernel({ reply: () => null });
  const device = await connectDevice(kernel.api, { pingMs: 25 });
  const slow = device.clipboard.readText();
  let settled = false;
  slow.catch(() => {}).finally(() => (settled = true));
  await tick(150);
  assert.equal(settled, false, "pongs keep it waiting");
  assert.ok(kernel.calls[0].sent.some((m) => typeof m.ping === "number"));
  kernel.state.pong = false;
  await assert.rejects(slow, (err) => err instanceof DeviceError && err.code === "disconnected");
  assert.equal(kernel.calls[0].closed, true);
});

test("after a failed reconnect, calls fail at once until the retry window passes", async () => {
  const kernel = fakeKernel({ reply: () => ({ result: "ok" }) });
  const device = await connectDevice(kernel.api, { timeoutMs: 10, retryMs: 30 });
  kernel.state.answer = false;
  kernel.calls[0].remoteClose();
  await assert.rejects(device.clipboard.readText(), (err) => err instanceof DeviceError && err.code === "disconnected");
  assert.equal(kernel.announces.length, 2);
  await assert.rejects(device.clipboard.readText(), (err) => err instanceof DeviceError && err.code === "disconnected");
  assert.equal(kernel.announces.length, 2, "no second announce inside the window");
  await tick(35);
  kernel.state.answer = true;
  assert.equal(await device.clipboard.readText(), "ok");
  assert.equal(kernel.announces.length, 3);
});

test("a reconnect stops waiting when the caller's signal aborts", async () => {
  const kernel = fakeKernel({ reply: () => ({ result: "ok" }) });
  const device = await connectDevice(kernel.api, { timeoutMs: 1000 });
  kernel.state.answer = false;
  kernel.calls[0].remoteClose();
  const controller = new AbortController();
  const call = device.clipboard.readText({ signal: controller.signal });
  await tick(5);
  controller.abort();
  await assert.rejects(call, (err) => err instanceof DeviceError && err.code === "cancelled");
  // Let the announce run out so the test ends cleanly.
  kernel.openCalls();
});
