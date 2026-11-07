// The app's end of the remote transport (src/frontend.ts) against the
// kernel's end (src/comm.ts), joined by a fake comm bus in the shape of
// cdp-kernel's `jupyter.comm` on one side and a `@jupyterlab/services`
// kernel connection on the other.
import { test } from "node:test";
import assert from "node:assert/strict";
import { ANNOUNCE_TARGET, CALLS_TARGET, type CommApiLike, type CommLike, type CommMessageLike, connectDevice } from "../src/comm.ts";
import { DeviceError } from "../src/errors.ts";
import { answerDevice, type KernelComm, type KernelCommMessage, type KernelConnectionLike } from "../src/frontend.ts";

const tick = (ms = 0) => new Promise((resolve) => setTimeout(resolve, ms));

/** One comm, seen from both ends. Messages are delivered from a microtask, as over a websocket. */
class BusComm {
  closed = false;
  kernelMsg: ((msg: CommMessageLike) => void)[] = [];
  kernelClose: ((msg: CommMessageLike) => void)[] = [];
  /** Sent by the frontend, as the kernel saw it. */
  fromFrontend: Record<string, unknown>[] = [];
  /** Sent by the kernel, as the frontend saw it. */
  fromKernel: Record<string, unknown>[] = [];
  frontend: KernelComm;
  kernel: CommLike;
  target: string;
  chain: Promise<unknown> = Promise.resolve();

  constructor(target: string) {
    this.target = target;
    const self = this;
    this.kernel = {
      get closed() {
        return self.closed;
      },
      send(data = {}) {
        if (self.closed) throw new Error("send on a closed comm");
        self.fromKernel.push(data);
        // In order, each after the last handler settles, as
        // @jupyterlab/services' message chain does.
        self.chain = self.chain.then(() => self.frontend.onMsg?.({ content: { data } }));
      },
      close() {
        if (self.closed) return;
        self.closed = true;
        queueMicrotask(() => void self.frontend.onClose?.({ content: {} }));
      },
      onMsg: (h) => void self.kernelMsg.push(h),
      onClose: (h) => void self.kernelClose.push(h),
    };
    this.frontend = {
      get isDisposed() {
        return self.closed;
      },
      onMsg: undefined,
      onClose: undefined,
      open() {
        throw new Error("set by the bus");
      },
      send(data) {
        if (self.closed) throw new Error("send on a closed comm");
        self.fromFrontend.push(data);
        queueMicrotask(() => self.kernelMsg.forEach((h) => h({ data })));
      },
      close() {
        if (self.closed) return;
        self.closed = true;
        queueMicrotask(() => self.kernelClose.forEach((h) => h({ data: {} })));
      },
    };
  }
}

type Target = (comm: KernelComm, msg: KernelCommMessage) => void | PromiseLike<void>;

/** A kernel with one or more frontends. `cellSession` is the session of the cell that runs connectDevice. */
function bus() {
  const kernelTargets = new Map<string, (comm: CommLike, msg: CommMessageLike) => void>();
  const comms: BusComm[] = [];
  const frontends: { clientId: string; targets: Map<string, Target> }[] = [];
  const state = { cellSession: "app" };
  /** Targets of the comms frontends opened, in order. */
  const opened: string[] = [];
  const api: CommApiLike = {
    open(target, data = {}) {
      const comm = new BusComm(target);
      comms.push(comm);
      // A kernel's comm_open goes to every client, with the cell's parent header.
      for (const f of frontends) {
        const cb = f.targets.get(target);
        if (cb) queueMicrotask(() => void cb(comm.frontend, { parent_header: { session: state.cellSession }, content: { data } }));
      }
      return comm.kernel;
    },
    registerTarget(target, handler) {
      kernelTargets.set(target, handler);
    },
  };
  /** `subshell`, when given, makes the kernel offer subshells and gives each created comm's `subshellStarted`. */
  function frontend(clientId: string, subshell?: () => Promise<void>): KernelConnectionLike & { status(s: string): void } {
    const targets = new Map<string, Target>();
    frontends.push({ clientId, targets });
    const slots = new Set<(sender: unknown, status: string) => void>();
    return {
      clientId,
      registerCommTarget: (t, cb) => void targets.set(t, cb),
      removeCommTarget: (t, cb) => void (targets.get(t) === cb && targets.delete(t)),
      createComm(target) {
        const comm = new BusComm(target);
        comms.push(comm);
        if (subshell) Object.assign(comm.frontend, { subshellStarted: subshell() });
        comm.frontend.open = (data = {}) => {
          opened.push(target);
          const handler = kernelTargets.get(target);
          queueMicrotask(() => (handler ? handler(comm.kernel, { data }) : (comm.closed = true)));
        };
        return comm.frontend;
      },
      supportsSubshells: subshell !== undefined,
      statusChanged: { connect: (s) => slots.add(s), disconnect: (s) => slots.delete(s) },
      status(s) {
        for (const slot of slots) slot(this, s);
      },
    };
  }
  return { api, comms, frontend, state, opened };
}

const HELLO = {
  platform: "ipados",
  appVersion: "0.6",
  capabilities: ["clipboard.readText", "clipboard.writeText", "ui.alert", "sound.player", "info"],
};

/** A host that answers like the Swift bridge; `hold` keeps a method's reply until released. */
function host(options: { hold?: string } = {}) {
  const sent: Record<string, unknown>[] = [];
  const held = new Map<number, (reply: unknown) => void>();
  const forward = async (message: Record<string, unknown>) => {
    sent.push(message);
    if (message.method === "hello") return { result: HELLO };
    if (message.cancel || message.release) return { result: null };
    if (message.method === options.hold) return new Promise((resolve) => held.set(message.id as number, resolve));
    if (message.method === "clipboard.readText") return { result: "from the iPad" };
    if (message.method === "clipboard.writeText") return { error: { code: "failed", message: "nope" } };
    return { result: null };
  };
  return { forward, sent, held };
}

test("the app answers its own cell's announce, and calls round-trip with the remote subset only", async () => {
  const b = bus();
  const h = host();
  answerDevice(b.frontend("app"), { forward: h.forward });
  const device = await connectDevice(b.api);
  const calls = b.comms.find((c) => c.target === CALLS_TARGET)!;
  assert.deepEqual(calls.fromFrontend, [], "the hello goes in the open, not as a message");
  assert.equal(device.has("clipboard.readText"), true);
  assert.equal(device.has("sound.player"), false, "not in the remote subset, so cut from the hello");
  assert.equal(await device.clipboard.readText(), "from the iPad");
  await assert.rejects(device.clipboard.writeText("x"), (err) => err instanceof DeviceError && err.code === "failed" && err.message === "nope");
  const forwarded = h.sent.filter((m) => typeof m.method === "string" && m.method !== "hello");
  assert.deepEqual(forwarded.map((m) => m.method), ["clipboard.readText", "clipboard.writeText"]);
  assert.ok(forwarded.every((m) => typeof m.id === "number" && typeof m.owner === "number"));
});

test("a second client on the kernel stays silent, and a cell from another session isn't answered", async () => {
  const b = bus();
  const app = host();
  const other = host();
  answerDevice(b.frontend("app"), { forward: app.forward });
  answerDevice(b.frontend("lab"), { forward: other.forward });
  const device = await connectDevice(b.api);
  assert.equal(await device.clipboard.readText(), "from the iPad");
  assert.equal(other.sent.length, 0, "the other client never asked its host");
  assert.equal(b.comms.filter((c) => c.target === CALLS_TARGET).length, 1);

  const b2 = bus();
  b2.state.cellSession = "lab";
  answerDevice(b2.frontend("app"), { forward: host().forward });
  const none = await connectDevice(b2.api, { timeoutMs: 20 });
  await assert.rejects(none.clipboard.readText(), (err) => err instanceof DeviceError && err.code === "unavailable");
});

test("a call outside the remote subset fails unavailable without reaching the host", async () => {
  const b = bus();
  const h = host();
  answerDevice(b.frontend("app"), { forward: h.forward });
  await connectDevice(b.api);
  const calls = b.comms.find((c) => c.target === CALLS_TARGET)!;
  calls.kernel.send({ id: 99, method: "sound.player", params: {} });
  await tick();
  assert.deepEqual(calls.fromFrontend.at(-1), { id: 99, error: { code: "unavailable", message: "sound.player isn't available over a remote kernel" } });
  assert.ok(!h.sent.some((m) => m.method === "sound.player"));
});

test("pings get pongs; a kernel cancel and a closed link cancel on the host; dispose releases", async () => {
  const b = bus();
  const h = host({ hold: "ui.alert" });
  const answerer = answerDevice(b.frontend("app"), { forward: h.forward });
  const device = await connectDevice(b.api, { timeoutMs: 50 });
  const calls = b.comms.find((c) => c.target === CALLS_TARGET)!;
  calls.kernel.send({ ping: 7 });
  await tick();
  assert.deepEqual(calls.fromFrontend.at(-1), { pong: 7 });

  const controller = new AbortController();
  const alert = device.ui.alert("hi", { signal: controller.signal });
  await tick();
  assert.equal(answerer.pending, 1);
  const hostId = h.sent.find((m) => m.method === "ui.alert")!.id;
  controller.abort();
  await assert.rejects(alert, (err) => err instanceof DeviceError && err.code === "cancelled");
  await tick();
  assert.deepEqual(h.sent.at(-1), { id: hostId, cancel: true });
  assert.equal(answerer.pending, 0);
  h.held.get(hostId as number)!({ result: null });
  await tick();
  assert.ok(!calls.fromFrontend.some((m) => m.id !== undefined && m.result !== undefined), "a reply after the cancel is dropped");

  const second = device.ui.alert("again");
  await tick();
  const secondId = h.sent.filter((m) => m.method === "ui.alert").at(-1)!.id;
  calls.kernel.close();
  await assert.rejects(second, (err) => err instanceof DeviceError && err.code === "disconnected");
  await tick();
  assert.deepEqual(h.sent.at(-1), { id: secondId, cancel: true }, "the closed link cancels on the host");

  answerer.dispose();
  const owner = h.sent[0].owner;
  assert.deepEqual(h.sent.at(-1), { owner, release: true });
});

test("a restart drops the link and cancels its calls; muting turns announces away", async () => {
  const b = bus();
  const h = host({ hold: "ui.alert" });
  const conn = b.frontend("app");
  answerDevice(conn, { forward: h.forward });
  const device = await connectDevice(b.api);
  void device.ui.alert("hi").catch(() => {});
  await tick();
  const hostId = h.sent.find((m) => m.method === "ui.alert")!.id;
  conn.status("restarting");
  assert.deepEqual(h.sent.at(-1), { id: hostId, cancel: true });
  assert.equal(b.comms.find((c) => c.target === CALLS_TARGET)!.closed, true);

  const b2 = bus();
  let muted = true;
  answerDevice(b2.frontend("app"), { forward: host().forward, accept: () => !muted });
  const none = await connectDevice(b2.api, { timeoutMs: 20 });
  assert.equal(none.has("clipboard.readText"), false);
  muted = false;
  assert.equal(b2.comms.filter((c) => c.target === ANNOUNCE_TARGET).length, 1);
});

test("the announce handler returns nothing, so @jupyterlab/services doesn't hold later messages for it", () => {
  let target: ((comm: KernelComm, msg: KernelCommMessage) => unknown) | undefined;
  const kernel: KernelConnectionLike = {
    clientId: "app",
    registerCommTarget: (_t, cb) => void (target = cb),
    removeCommTarget: () => {},
    createComm: () => {
      throw new Error("not reached");
    },
  };
  answerDevice(kernel, { forward: () => new Promise(() => {}) });
  const returned = target!({} as KernelComm, { parent_header: { session: "app" }, content: { data: {} } });
  assert.equal(returned, undefined);
});

test("a ping is answered while a call waits on the host, as the kernel's messages aren't held", async () => {
  const b = bus();
  const h = host({ hold: "ui.alert" });
  answerDevice(b.frontend("app"), { forward: h.forward });
  const device = await connectDevice(b.api);
  const calls = b.comms.find((c) => c.target === CALLS_TARGET)!;
  const alert = device.ui.alert("open");
  await tick();
  calls.kernel.send({ ping: 1 });
  await tick();
  assert.deepEqual(calls.fromFrontend.at(-1), { pong: 1 });
  h.held.get(h.sent.find((m) => m.method === "ui.alert")!.id as number)!({ result: null });
  assert.equal(await alert, undefined);
});

test("the calls comm opens only once its subshell is up", async () => {
  const b = bus();
  let start!: () => void;
  answerDevice(b.frontend("app", () => new Promise<void>((resolve) => (start = resolve))), { forward: host().forward });
  const connecting = connectDevice(b.api);
  await tick(20);
  assert.deepEqual(b.opened, [], "not on the main shell before the subshell");
  start();
  const device = await connecting;
  assert.deepEqual(b.opened, [CALLS_TARGET]);
  assert.equal(await device.clipboard.readText(), "from the iPad");
});

test("with no subshell in time the page gives up, and answers the next announce", async () => {
  const b = bus();
  let subshell: () => Promise<void> = () => new Promise<void>(() => {});
  answerDevice(b.frontend("app", () => subshell()), { forward: host().forward });
  const none = await connectDevice(b.api, { timeoutMs: 3500 });
  assert.equal(none.has("clipboard.readText"), false);
  assert.deepEqual(b.opened, [], "the comm is dropped, never opened on the main shell");
  assert.equal(b.comms.find((c) => c.target === CALLS_TARGET)?.closed, true);
  subshell = () => Promise.resolve();
  const device = await connectDevice(b.api);
  assert.equal(await device.clipboard.readText(), "from the iPad");
});

