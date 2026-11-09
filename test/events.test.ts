// `device.on` (Phase 3, host events): handlers over one `events.watch`
// stream, against a fake host that answers `stream.next` as Swift's
// Streams does.
import { test } from "node:test";
import assert from "node:assert/strict";
import { createDevice, DeviceError, type DeviceTransport } from "../src/mod.ts";

/** A host whose `events.watch` streams the test feeds with `push`. */
class EventsHost implements DeviceTransport {
  readonly sent: string[] = [];
  opened = 0;
  closed = 0;
  refuse: DeviceError | null = null;
  #queue: unknown[] = [];
  #waiting: ((batch: unknown) => void) | null = null;

  push(event: string, value: unknown): void {
    this.#queue.push({ event, value });
    this.#flush();
  }

  end(): void {
    this.#waiting?.({ values: [], dropped: 0, end: true });
    this.#waiting = null;
  }

  #flush(): void {
    if (!this.#waiting || this.#queue.length === 0) return;
    const values = this.#queue.splice(0);
    this.#waiting({ values, dropped: 0 });
    this.#waiting = null;
  }

  call(method: string): Promise<unknown> {
    this.sent.push(method);
    switch (method) {
      case "events.watch":
        if (this.refuse) return Promise.reject(this.refuse);
        this.opened++;
        return Promise.resolve({ stream: this.opened });
      case "stream.next":
        return new Promise((resolve) => {
          this.#waiting = resolve;
          this.#flush();
        });
      case "stream.close":
        this.closed++;
        this.end();
        return Promise.resolve(null);
      default:
        return Promise.reject(new DeviceError("unavailable", method));
    }
  }
}

const tick = () => new Promise((done) => setTimeout(done, 0));

function device(host: EventsHost, capabilities = ["events.watch"]) {
  return createDevice(host, { platform: "macos", appVersion: "", capabilities });
}

/** Captures console.error lines while `run` runs. */
async function stderr(run: () => Promise<void>): Promise<string[]> {
  const lines: string[] = [];
  const original = console.error;
  console.error = (...args: unknown[]) => lines.push(args.join(" "));
  try {
    await run();
  } finally {
    console.error = original;
  }
  return lines;
}

test("handlers share one stream and get their own event", async () => {
  const host = new EventsHost();
  const d = device(host);
  const modes: string[] = [];
  const fronts: null[] = [];
  const offMode = d.on("appearance", (mode) => modes.push(mode));
  const offFront = d.on("foreground", (value) => fronts.push(value));
  await tick();
  assert.equal(host.opened, 1, "one stream for both");
  host.push("appearance", "dark");
  host.push("foreground", null);
  host.push("locale", "fr-FR");
  await tick();
  await tick();
  assert.deepEqual(modes, ["dark"]);
  assert.deepEqual(fronts, [null]);
  offMode();
  await tick();
  assert.equal(host.closed, 0, "another handler is left");
  offFront();
  offFront();
  await tick();
  assert.equal(host.closed, 1, "the last removal closes it");
  d.on("locale", () => {});
  await tick();
  assert.equal(host.opened, 2, "a new handler opens a new stream");
});

test("a signal removes the handler; a thrown error doesn't", async () => {
  const host = new EventsHost();
  const d = device(host);
  const controller = new AbortController();
  const seen: unknown[] = [];
  d.on("battery", (value) => seen.push(value), { signal: controller.signal });
  d.on("battery", () => {
    throw new Error("boom");
  });
  await tick();
  const lines = await stderr(async () => {
    host.push("battery", { level: 0.5, charging: true });
    await tick();
    await tick();
  });
  assert.deepEqual(seen, [{ level: 0.5, charging: true }]);
  assert.match(lines.join("\n"), /handler threw: boom/);
  controller.abort();
  host.push("battery", { level: 0.4, charging: true });
  await tick();
  await tick();
  assert.equal(seen.length, 1);
  assert.equal(host.closed, 0, "the throwing handler is still there");
  const aborted = AbortSignal.abort();
  let late = 0;
  d.on("battery", () => late++, { signal: aborted });
  host.push("battery", { level: 0.3, charging: true });
  await tick();
  await tick();
  assert.equal(late, 0, "an aborted signal adds nothing");
});

test("without the stream, the handler goes and stderr says why", async () => {
  const lines = await stderr(async () => {
    const d = device(new EventsHost(), []);
    d.on("appearance", () => {});
    await tick();
  });
  assert.match(lines.join("\n"), /device\.on: no host events \(unavailable\)/);
  const host = new EventsHost();
  host.refuse = new DeviceError("denied", "no");
  const refused = await stderr(async () => {
    device(host).on("locale", () => {});
    await tick();
    await tick();
  });
  assert.match(refused.join("\n"), /\(denied\)/);
  // The next handler tries again.
  host.refuse = null;
  device(host).on("locale", () => {});
  await tick();
  assert.equal(host.opened, 1);
});

test("bad arguments throw at once", () => {
  const d = device(new EventsHost());
  assert.throws(() => d.on("weather" as "locale", () => {}), (err) => err instanceof DeviceError && err.code === "failed");
  assert.throws(() => d.on("locale", "x" as unknown as () => void), (err) => err instanceof DeviceError && err.code === "failed");
});
