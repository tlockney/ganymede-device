// The remote transport (docs/plan.md, "Remote kernels"; docs/protocol.md,
// "Over a Jupyter comm"): a kernel that isn't in the app, such as cdp-kernel
// on Node behind Ganymede, reaches the app through the notebook page that
// shows it, over Jupyter comms.
//
// The handshake avoids a comm every frontend sees: a kernel-opened comm
// goes to every client on the kernel, and JupyterLab closes one whose
// target it doesn't know, which would close it for the app too. So the
// kernel opens a short-lived announce comm, and the app, if the announce
// came from a cell it ran (its Jupyter session), opens a calls comm back
// to the kernel. Only the app knows that comm; calls and replies go over
// it.
//
//   import { connectDevice } from "@tlockney/ganymede-device/remote";
//   const device = await connectDevice(jupyter.comm);

import { decodeBinary, encodeBinary } from "./binary.ts";
import { type CallOptions, createDevice, type Device, type DeviceInfo, type DeviceTransport, helloInfo, unavailableDevice } from "./device.ts";
import { DeviceError } from "./errors.ts";
import { SUPPORT, type SupportRow } from "./support.ts";

/** The kernel opens this; the app registers it. */
export const ANNOUNCE_TARGET = "ganymede.device.v1";
/** The app opens this; the kernel registers it. */
export const CALLS_TARGET = "ganymede.device.v1.calls";

/** A comm message as cdp-kernel's `jupyter.comm` hands it over. */
export interface CommMessageLike {
  data: Record<string, unknown>;
}

/** The part of a cdp-kernel `Comm` this uses. */
export interface CommLike {
  readonly closed: boolean;
  send(data?: Record<string, unknown>): void;
  close(data?: Record<string, unknown>): void;
  onMsg(handler: (msg: CommMessageLike) => void): void;
  onClose(handler: (msg: CommMessageLike) => void): void;
}

/** The part of cdp-kernel's `jupyter.comm` this uses. */
export interface CommApiLike {
  open(targetName: string, data?: Record<string, unknown>): CommLike;
  registerTarget(targetName: string, handler: (comm: CommLike, msg: CommMessageLike) => void): void;
}

/** The methods a remote kernel may call: SUPPORT rows whose remote column isn't `no`. */
export const REMOTE_METHODS: ReadonlySet<string> = new Set(
  Object.entries(SUPPORT as Record<string, SupportRow>)
    .filter(([, row]) => row.remote !== "no")
    .map(([method]) => method),
);

export interface ConnectOptions {
  /** How long to wait for the app to answer an announce; 5000 ms by default. */
  timeoutMs?: number;
  /**
   * While calls are in flight, how often the kernel pings the app; 5000 ms
   * by default. An app that answers nothing for two of these is taken as
   * gone (killed, suspended, or its network dropped), since a frontend
   * that goes away sends no `comm_close`.
   */
  pingMs?: number;
  /** After the app has gone and an announce went unanswered, how long calls fail at once; 10000 ms by default. */
  retryMs?: number;
}

interface Pending {
  resolve(value: unknown): void;
  reject(error: DeviceError): void;
}

/** The remote subset of a hello. */
function remoteHello(hello: DeviceInfo): DeviceInfo {
  return { ...hello, capabilities: hello.capabilities.filter((m) => REMOTE_METHODS.has(m)) };
}

/**
 * The kernel's end of the link, one per `jupyter.comm`, so the calls
 * target is registered once however often a cell connects. It announces
 * when it has no calls comm, takes the first one the app opens, and
 * announces again after that one closes, on the next call.
 */
class CommLink {
  #api: CommApiLike;
  timeoutMs = 5000;
  pingMs = 5000;
  retryMs = 10000;
  #comm: CommLike | null = null;
  #hello: DeviceInfo | null = null;
  #waiting: { resolve(comm: CommLike, hello: DeviceInfo): void } | null = null;
  #connecting: Promise<void> | null = null;
  #failedAt = -Infinity;
  #pending = new Map<number, Pending>();
  #nextId = 0;
  #heardAt = 0;
  #pinger: ReturnType<typeof setInterval> | undefined;
  #pings = 0;

  constructor(api: CommApiLike) {
    this.#api = api;
    api.registerTarget(CALLS_TARGET, (comm, msg) => this.#accept(comm, msg));
  }

  /** The app's `hello` as of the last connect, cut to the remote subset; null before one. */
  get hello(): DeviceInfo | null {
    return this.#hello;
  }

  /** Resolves once a calls comm is open; rejects `unavailable` when no app answers in time. */
  connect(): Promise<void> {
    if (this.#comm && !this.#comm.closed) return Promise.resolve();
    this.#connecting ??= this.#announce().finally(() => (this.#connecting = null));
    return this.#connecting;
  }

  async call(method: string, params: Record<string, unknown>, options: CallOptions = {}): Promise<unknown> {
    const { signal } = options;
    if (signal?.aborted) throw DeviceError.from(signal.reason);
    await this.#reconnect(signal);
    // What the app answers now, which may differ from the hello the
    // device was made with if a different app answered since.
    if (!this.#hello?.capabilities.includes(method)) {
      throw new DeviceError("unavailable", `${method} isn't available from this app over a remote kernel`);
    }
    const encoded = await encodeBinary(params);
    if (signal?.aborted) throw DeviceError.from(signal.reason);
    const comm = this.#comm;
    if (!comm || comm.closed) throw new DeviceError("disconnected", "the app went away");
    const id = ++this.#nextId;
    return new Promise((resolve, reject) => {
      const done = () => {
        signal?.removeEventListener("abort", onAbort);
        this.#pending.delete(id);
        this.#watch();
      };
      const onAbort = () => {
        done();
        if (!comm.closed) send(comm, { id, cancel: true });
        reject(DeviceError.from(signal?.reason));
      };
      this.#pending.set(id, {
        resolve: (value) => (done(), resolve(value)),
        reject: (error) => (done(), reject(error)),
      });
      signal?.addEventListener("abort", onAbort, { once: true });
      if (!send(comm, { id, method, params: encoded })) {
        this.#drop(comm);
        return;
      }
      this.#watch();
    });
  }

  /** Connects if needed, watching the caller's signal. */
  async #reconnect(signal: AbortSignal | undefined): Promise<void> {
    if (this.#comm && !this.#comm.closed) return;
    const linkedBefore = this.#hello !== null;
    // Gone a moment ago and no answer since: fail now rather than make
    // every call in a loop wait out another announce.
    if (linkedBefore && performance.now() - this.#failedAt < this.retryMs) {
      throw new DeviceError("disconnected", "the app went away and hasn't answered since");
    }
    let onAbort: (() => void) | undefined;
    const aborted = new Promise<never>((_, reject) => {
      onAbort = () => reject(DeviceError.from(signal?.reason));
      signal?.addEventListener("abort", onAbort, { once: true });
    });
    try {
      await Promise.race([this.connect(), aborted]);
    } catch (err) {
      const error = DeviceError.from(err);
      if (error.code !== "unavailable") throw error;
      this.#failedAt = performance.now();
      // Linked before, so the app was there and has gone.
      if (linkedBefore) throw new DeviceError("disconnected", `the app went away and didn't answer again (${error.message})`);
      throw error;
    } finally {
      if (onAbort) signal?.removeEventListener("abort", onAbort);
    }
  }

  #announce(): Promise<void> {
    return new Promise((resolve, reject) => {
      let announce: CommLike | undefined;
      const done = () => {
        clearTimeout(timer);
        this.#waiting = null;
        if (announce && !announce.closed) announce.close();
      };
      const timer = setTimeout(() => {
        done();
        reject(new DeviceError("unavailable", "no app answered: this notebook isn't open in the Ganymede app"));
      }, this.timeoutMs);
      // Set before the announce goes out, so an app that answers at once is taken.
      this.#waiting = {
        resolve: (comm, hello) => {
          done();
          this.#use(comm, hello);
          resolve();
        },
      };
      try {
        // Anyone may close the announce comm (JupyterLab does); only its
        // open matters.
        announce = this.#api.open(ANNOUNCE_TARGET, { protocol: 1 });
        if (!this.#waiting) announce.close();
      } catch (err) {
        done();
        reject(DeviceError.from(err));
      }
    });
  }

  #accept(comm: CommLike, msg: CommMessageLike): void {
    let hello: DeviceInfo;
    try {
      hello = helloInfo(msg.data);
    } catch {
      comm.close({ error: "the calls comm's open needs the app's hello" });
      return;
    }
    // Only an answer to our announce, and only the first: a second app
    // window, or one late after a timeout, is turned away.
    if (!this.#waiting || (this.#comm && !this.#comm.closed)) {
      comm.close({ error: this.#comm && !this.#comm.closed ? "taken" : "not waiting" });
      return;
    }
    this.#waiting.resolve(comm, hello);
  }

  #use(comm: CommLike, hello: DeviceInfo): void {
    this.#comm = comm;
    this.#hello = remoteHello(hello);
    this.#heardAt = performance.now();
    comm.onMsg(({ data }) => {
      if (this.#comm !== comm) return;
      this.#heardAt = performance.now();
      const id = typeof data.id === "number" ? data.id : NaN;
      const pending = this.#pending.get(id);
      if (!pending) return;
      const error = data.error;
      if (error !== undefined && error !== null) {
        const { code, message } = (typeof error === "object" ? error : {}) as { code?: unknown; message?: unknown };
        pending.reject(DeviceError.from({ code: String(code ?? "failed"), message: String(message ?? error) }));
        return;
      }
      let value: unknown;
      try {
        value = decodeBinary(data.result);
      } catch (err) {
        pending.reject(DeviceError.from(err));
        return;
      }
      pending.resolve(value);
    });
    comm.onClose(() => this.#drop(comm));
  }

  /** The app is gone: forget its comm and reject what it never answered. */
  #drop(comm: CommLike): void {
    if (this.#comm !== comm) return;
    this.#comm = null;
    this.#failedAt = -Infinity;
    if (!comm.closed) comm.close();
    const pending = [...this.#pending.values()];
    this.#pending.clear();
    this.#watch();
    for (const call of pending) call.reject(new DeviceError("disconnected", "the app went away; the next call reconnects"));
  }

  /**
   * Pings the app while calls are in flight, and drops a comm that has
   * answered nothing for two pings: a frontend that is killed or
   * suspended never closes its comms.
   */
  #watch(): void {
    if (this.#pending.size === 0 || !this.#comm) {
      clearInterval(this.#pinger);
      this.#pinger = undefined;
      return;
    }
    if (this.#pinger !== undefined) return;
    this.#heardAt = performance.now();
    this.#pinger = setInterval(() => {
      const comm = this.#comm;
      if (!comm) return this.#watch();
      // The pinger starts with #heardAt reset, so two pings unanswered is
      // three intervals.
      if (performance.now() - this.#heardAt > 3 * this.pingMs) return this.#drop(comm);
      if (!send(comm, { ping: ++this.#pings })) this.#drop(comm);
    }, this.pingMs);
  }
}

/** Sends on `comm`; false when it is closed (cdp-kernel's comm then drops the send quietly) or refuses. */
function send(comm: CommLike, data: Record<string, unknown>): boolean {
  if (comm.closed) return false;
  try {
    comm.send(data);
    return true;
  } catch {
    return false;
  }
}

const links = new WeakMap<CommApiLike, CommLink>();

/**
 * The `device` API from a kernel that isn't in the app. Announces itself
 * and waits up to `timeoutMs` for the app showing this notebook to answer.
 * With no answer, every call rejects `unavailable`. Only the remote subset
 * is offered (REMOTE_METHODS), whatever the app answers. When the app goes
 * away, calls in flight reject `disconnected` and the next call announces
 * again. Run it from a cell: the app matches the announce to the session
 * of the cell that sent it. Calling it again reuses the same link.
 *
 * `has()` and `info()` reflect the app that answered first; a call checks
 * the app that answers now. The options apply to the shared link, so a
 * later `connectDevice` with other options changes them for every device
 * on that `jupyter.comm`.
 *
 * An interrupt doesn't cancel a call by itself (the kernel's interrupt
 * reaches host requests, not comms): pass a `signal` to cancel one.
 */
export async function connectDevice(api: CommApiLike, options: ConnectOptions = {}): Promise<Device> {
  let link = links.get(api);
  if (!link) {
    link = new CommLink(api);
    links.set(api, link);
  }
  if (options.timeoutMs !== undefined) link.timeoutMs = options.timeoutMs;
  if (options.pingMs !== undefined) link.pingMs = options.pingMs;
  if (options.retryMs !== undefined) link.retryMs = options.retryMs;
  try {
    await link.connect();
  } catch (err) {
    if (DeviceError.from(err).code === "unavailable") return unavailableDevice();
    throw err;
  }
  const transport: DeviceTransport = { call: (method, params, callOptions) => link.call(method, params, callOptions) };
  return createDevice(transport, link.hello!);
}
