// Bounded streams (src/stream.ts) against a fake transport that answers as
// the Swift bridge's Streams does: `{ stream }` on open, batches from a
// drop-oldest queue on `stream.next`, and a cancelled `stream.next` or a
// `stream.close` ends the stream.
import { test } from "node:test";
import assert from "node:assert/strict";
import { type CallOptions, DeviceError, type DeviceTransport, openStream } from "../src/mod.ts";
import { webkitHost } from "../src/webkit.ts";

type Sent = { method: string; params: Record<string, unknown> };

/** One stream's host side: `push` queues a value, `end` ends it. */
class FakeHost implements DeviceTransport {
  readonly sent: Sent[] = [];
  readonly queue: unknown[] = [];
  dropped = 0;
  ended = false;
  stopped = false;
  failure: DeviceError | null = null;
  #waiting: { resolve(v: unknown): void; reject(e: unknown): void } | null = null;

  readonly capacity: number;

  constructor(capacity = 4) {
    this.capacity = capacity;
  }

  push(...values: unknown[]): void {
    for (const value of values) {
      if (this.queue.length >= this.capacity) {
        this.queue.shift();
        this.dropped++;
      }
      this.queue.push(value);
    }
    this.#answer();
  }

  end(failure?: DeviceError): void {
    this.ended = true;
    this.failure = failure ?? null;
    this.#answer();
  }

  #answer(): void {
    const waiting = this.#waiting;
    if (!waiting || (this.queue.length === 0 && !this.ended)) return;
    this.#waiting = null;
    if (this.queue.length === 0 && this.failure) return waiting.reject(this.failure);
    waiting.resolve({ values: this.queue.splice(0), dropped: this.dropped, ...(this.ended && !this.failure ? { end: true } : {}) });
  }

  call(method: string, params: Record<string, unknown>, options: CallOptions = {}): Promise<unknown> {
    this.sent.push({ method, params });
    if (method === "test.ticks") return Promise.resolve({ stream: 7 });
    if (method === "stream.close") {
      this.stopped = true;
      this.ended = true;
      this.#answer();
      return Promise.resolve(null);
    }
    if (method !== "stream.next") return Promise.reject(new DeviceError("unavailable", `no ${method}`));
    assert.equal(params.stream, 7);
    assert.equal(this.#waiting, null, "one stream.next at a time");
    return new Promise((resolve, reject) => {
      this.#waiting = { resolve, reject };
      options.signal?.addEventListener("abort", () => {
        // The bridge ends a stream whose stream.next is cancelled.
        this.#waiting = null;
        this.stopped = true;
        this.ended = true;
        reject(options.signal!.reason);
      }, { once: true });
      this.#answer();
    });
  }
}

const methods = (host: FakeHost) => host.sent.map((s) => s.method);

test("a stream yields the host's values in order and ends when the host does", async () => {
  const host = new FakeHost(10);
  const stream = openStream<number>(host, "test.ticks", { every: 1 });
  host.push(1, 2, 3);
  const seen: number[] = [];
  for await (const value of stream) {
    seen.push(value);
    if (value === 3) {
      host.push(4, 5);
      host.end();
    }
  }
  assert.deepEqual(seen, [1, 2, 3, 4, 5]);
  assert.deepEqual(host.sent[0], { method: "test.ticks", params: { every: 1 } });
  // Ended by the host: nothing to close.
  assert.ok(!methods(host).includes("stream.close"));
});

test("nothing is sent until the first next()", async () => {
  const host = new FakeHost();
  const stream = openStream(host, "test.ticks", {});
  assert.deepEqual(host.sent, []);
  await stream.return();
  assert.deepEqual(host.sent, []);
});

test("break stops the host's source with stream.close", async () => {
  const host = new FakeHost();
  host.push("a", "b");
  for await (const value of openStream(host, "test.ticks", {})) {
    assert.equal(value, "a");
    break;
  }
  assert.deepEqual(host.sent.at(-1), { method: "stream.close", params: { stream: 7 } });
  assert.ok(host.stopped);
});

test("aborting while the cell waits rejects cancelled and ends the stream on the host", async () => {
  const host = new FakeHost();
  const controller = new AbortController();
  const stream = openStream(host, "test.ticks", {}, { signal: controller.signal });
  const waiting = stream.next();
  await new Promise((r) => setTimeout(r, 5));
  controller.abort();
  await assert.rejects(waiting, (err: DeviceError) => err instanceof DeviceError && err.code === "cancelled");
  assert.ok(host.stopped);
  // A quiet close follows, in case the cancel didn't reach the host's read; the stream is done.
  assert.deepEqual(host.sent.at(-1), { method: "stream.close", params: { stream: 7 } });
  assert.equal(methods(host).filter((m) => m === "stream.close").length, 1);
  assert.deepEqual(await stream.next(), { done: true, value: undefined });
});

test("AbortSignal.timeout() rejects timeout", async () => {
  const host = new FakeHost();
  const stream = openStream(host, "test.ticks", {}, { signal: AbortSignal.timeout(20) });
  // AbortSignal.timeout's timer doesn't keep the process alive.
  const alive = setTimeout(() => {}, 1000);
  await assert.rejects(stream.next(), (err: DeviceError) => err.code === "timeout");
  clearTimeout(alive);
});

test("an interrupt between reads (the cell signal) closes the stream at once", async () => {
  const host = new FakeHost();
  const cell = new AbortController();
  const stream = openStream(host, "test.ticks", {}, { cellSignal: cell.signal });
  host.push(1, 2);
  assert.deepEqual(await stream.next(), { done: false, value: 1 });
  // The cell is busy with the value when the interrupt comes.
  cell.abort(new DOMException("Execution interrupted", "AbortError"));
  assert.deepEqual(host.sent.at(-1), { method: "stream.close", params: { stream: 7 } });
  await assert.rejects(stream.next(), (err: DeviceError) => err.code === "cancelled");
});

test("a slow reader sees dropped grow and holds only the newest values", async () => {
  const host = new FakeHost(3);
  const stream = openStream<number>(host, "test.ticks", {});
  host.push(1);
  assert.deepEqual(await stream.next(), { done: false, value: 1 });
  host.push(2, 3, 4, 5, 6);
  assert.deepEqual(await stream.next(), { done: false, value: 4 });
  assert.equal(stream.dropped, 2);
  assert.deepEqual(await stream.next(), { done: false, value: 5 });
  assert.deepEqual(await stream.next(), { done: false, value: 6 });
  await stream.return();
});

test("a host error after some values is thrown once they're read", async () => {
  const host = new FakeHost();
  const stream = openStream(host, "test.ticks", {});
  host.push(1);
  assert.deepEqual(await stream.next(), { done: false, value: 1 });
  host.end(new DeviceError("denied", "no location for you"));
  await assert.rejects(stream.next(), (err: DeviceError) => err.code === "denied");
  assert.deepEqual(await stream.next(), { done: true, value: undefined });
});

test("read converts each value, and a refused open rejects with the host's code", async () => {
  const host = new FakeHost();
  host.push({ n: 2 });
  const doubled = openStream(host, "test.ticks", {}, {}, (v) => (v as { n: number }).n * 2);
  assert.deepEqual(await doubled.next(), { done: false, value: 4 });
  await doubled.return();
  const refused = openStream(host, "test.nothing", {});
  await assert.rejects(refused.next(), (err: DeviceError) => err.code === "unavailable");
});

test("return() while the stream opens closes it once it has an id", async () => {
  let open!: (v: unknown) => void;
  const sent: Sent[] = [];
  const transport: DeviceTransport = {
    call(method, params) {
      sent.push({ method, params });
      if (method === "test.ticks") return new Promise((resolve) => (open = resolve));
      return Promise.resolve(null);
    },
  };
  const stream = openStream(transport, "test.ticks", {});
  const first = stream.next();
  await new Promise((r) => setTimeout(r, 0));
  await stream.return();
  open({ stream: 9 });
  assert.deepEqual(await first, { done: true, value: undefined });
  assert.deepEqual(sent.at(-1), { method: "stream.close", params: { stream: 9 } });
});

test("through webkitHost, a cancelled stream.next posts the cancel Swift ends the stream on", async () => {
  const received: { id?: number; method?: string; params?: Record<string, unknown>; cancel?: true }[] = [];
  globalThis.webkit = {
    messageHandlers: {
      device: {
        postMessage(message: unknown) {
          const msg = message as (typeof received)[number];
          received.push(msg);
          if (msg.cancel) return Promise.resolve(null);
          if (msg.method === "test.ticks") return Promise.resolve({ result: { stream: msg.id } });
          // stream.next: nothing comes.
          return new Promise(() => {});
        },
      },
    },
  };
  try {
    const handler = webkitHost();
    // As cdp-kernel's Worker does: the call rejects on abort, and the page's
    // handler is told through its own signal.
    const transport: DeviceTransport = {
      call(method, params, options = {}) {
        const signal = options.signal ?? new AbortController().signal;
        return Promise.race([
          handler({ method, params }, signal),
          new Promise((_, reject) => signal.addEventListener("abort", () => reject(signal.reason), { once: true })),
        ]);
      },
    };
    const controller = new AbortController();
    const stream = openStream(transport, "test.ticks", {}, { signal: controller.signal });
    const waiting = stream.next();
    await new Promise((r) => setTimeout(r, 5));
    controller.abort();
    await assert.rejects(waiting, (err: DeviceError) => err.code === "cancelled");
    const opened = received[0];
    const next = received[1];
    assert.equal(opened.method, "test.ticks");
    assert.deepEqual(next.params, { stream: opened.id });
    const cancel = received.findIndex((m) => m.cancel);
    assert.deepEqual(received[cancel], { id: next.id, cancel: true });
    // Then the close, in case the cancel came too early or too late for Swift's read.
    assert.deepEqual(received.slice(cancel + 1).map((m) => [m.method, m.params]), [["stream.close", { stream: opened.id }]]);
  } finally {
    delete (globalThis as { webkit?: unknown }).webkit;
  }
});

// #82: the host ends a stream on a cancel only while the read waits there.

test("a stream.next that fails before reaching the host still closes the stream", async () => {
  const sent: Sent[] = [];
  const transport: DeviceTransport = {
    call(method, params) {
      sent.push({ method, params });
      if (method === "test.ticks") return Promise.resolve({ stream: 5 });
      if (method === "stream.close") return Promise.resolve(null);
      // As webkitHost's "cancelled before it was sent": the host never sees the read.
      return Promise.reject(new DeviceError("cancelled", "stream.next was cancelled before it was sent"));
    },
  };
  const stream = openStream(transport, "test.ticks", {});
  await assert.rejects(stream.next(), (err: DeviceError) => err.code === "cancelled");
  assert.deepEqual(sent.map((s) => s.method), ["test.ticks", "stream.next", "stream.close"]);
  assert.deepEqual(sent.at(-1)?.params, { stream: 5 });
  assert.deepEqual(await stream.next(), { done: true, value: undefined });
});

test("a malformed stream.next reply closes the stream", async () => {
  const sent: string[] = [];
  const transport: DeviceTransport = {
    call(method) {
      sent.push(method);
      if (method === "test.ticks") return Promise.resolve({ stream: 5 });
      if (method === "stream.close") return Promise.resolve(null);
      return Promise.resolve({ values: "nope" });
    },
  };
  await assert.rejects(openStream(transport, "test.ticks", {}).next(), (err: DeviceError) => err.code === "failed");
  assert.deepEqual(sent, ["test.ticks", "stream.next", "stream.close"]);
});

test("a read that throws stops the stream", async () => {
  const host = new FakeHost();
  host.push(1, "bad", 3);
  const read = (value: unknown) => {
    if (typeof value !== "number") throw new DeviceError("failed", "not a number");
    return value;
  };
  const seen: number[] = [];
  await assert.rejects(async () => {
    for await (const value of openStream(host, "test.ticks", {}, {}, read)) seen.push(value);
  }, (err: DeviceError) => err.code === "failed");
  assert.deepEqual(seen, [1]);
  assert.ok(host.stopped);
  assert.deepEqual(host.sent.at(-1), { method: "stream.close", params: { stream: 7 } });
});

test("a read that throws something else still rejects with a DeviceError", async () => {
  const host = new FakeHost();
  host.push(1);
  const stream = openStream(host, "test.ticks", {}, {}, () => {
    throw new TypeError("boom");
  });
  await assert.rejects(stream.next(), (err) => err instanceof DeviceError);
  assert.ok(host.stopped);
});
