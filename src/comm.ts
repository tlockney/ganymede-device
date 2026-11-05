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

export interface ConnectOptions {
  /** How long to wait for the app to answer an announce; 2000 ms by default. */
  timeoutMs?: number;
}

/** The methods a remote kernel may call: SUPPORT rows whose remote column isn't `no`. */
export const REMOTE_METHODS: ReadonlySet<string> = new Set(
  Object.entries(SUPPORT as Record<string, SupportRow>)
    .filter(([, row]) => row.remote !== "no")
    .map(([method]) => method),
);

interface Pending {
  resolve(value: unknown): void;
  reject(error: DeviceError): void;
}

/**
 * The kernel's end of the link. It announces when it has no calls comm,
 * takes the first one the app opens, and announces again after that one
 * closes, on the next call.
 */
class CommLink {
  #api: CommApiLike;
  #timeoutMs: number;
  #comm: CommLike | null = null;
  #hello: DeviceInfo | null = null;
  #waiting: { resolve(comm: CommLike, hello: DeviceInfo): void } | null = null;
  #connecting: Promise<void> | null = null;
  #pending = new Map<number, Pending>();
  #nextId = 0;

  constructor(api: CommApiLike, timeoutMs: number) {
    this.#api = api;
    this.#timeoutMs = timeoutMs;
    api.registerTarget(CALLS_TARGET, (comm, msg) => this.#accept(comm, msg));
  }

  /** The app's `hello`, from the calls comm's open; null before one opened. */
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
    try {
      await this.connect();
    } catch (err) {
      // Linked before, so the app was there and has gone.
      if (this.#hello) throw new DeviceError("disconnected", `the app went away and didn't answer again (${DeviceError.from(err).message})`);
      throw err;
    }
    const encoded = await encodeBinary(params);
    if (signal?.aborted) throw DeviceError.from(signal.reason);
    const comm = this.#comm;
    if (!comm || comm.closed) throw new DeviceError("disconnected", "the app went away");
    const id = ++this.#nextId;
    return new Promise((resolve, reject) => {
      const onAbort = () => {
        this.#pending.delete(id);
        if (!comm.closed) comm.send({ id, cancel: true });
        reject(DeviceError.from(signal?.reason));
      };
      this.#pending.set(id, {
        resolve: (value) => (signal?.removeEventListener("abort", onAbort), resolve(value)),
        reject: (error) => (signal?.removeEventListener("abort", onAbort), reject(error)),
      });
      signal?.addEventListener("abort", onAbort, { once: true });
      comm.send({ id, method, params: encoded });
    });
  }

  #announce(): Promise<void> {
    return new Promise((resolve, reject) => {
      // Anyone may close the announce comm (JupyterLab does); only its
      // open matters.
      const announce = this.#api.open(ANNOUNCE_TARGET, { protocol: 1 });
      const done = () => {
        clearTimeout(timer);
        this.#waiting = null;
        if (!announce.closed) announce.close();
      };
      const timer = setTimeout(() => {
        done();
        reject(new DeviceError("unavailable", "no app answered: this notebook isn't open in the Ganymede app"));
      }, this.#timeoutMs);
      this.#waiting = {
        resolve: (comm, hello) => {
          done();
          this.#use(comm, hello);
          resolve();
        },
      };
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
      comm.close({ error: "taken" });
      return;
    }
    this.#waiting.resolve(comm, hello);
  }

  #use(comm: CommLike, hello: DeviceInfo): void {
    this.#comm = comm;
    this.#hello = hello;
    comm.onMsg(({ data }) => {
      const id = typeof data.id === "number" ? data.id : NaN;
      const pending = this.#pending.get(id);
      if (!pending) return;
      this.#pending.delete(id);
      const error = data.error;
      if (typeof error === "object" && error !== null) {
        const { code, message } = error as { code?: unknown; message?: unknown };
        pending.reject(DeviceError.from({ code: String(code ?? "failed"), message: String(message ?? "the call failed") }));
      } else {
        pending.resolve(decodeBinary(data.result));
      }
    });
    comm.onClose(() => {
      if (this.#comm === comm) this.#comm = null;
      const pending = [...this.#pending.values()];
      this.#pending.clear();
      for (const call of pending) call.reject(new DeviceError("disconnected", "the app went away; the next call reconnects"));
    });
  }
}

/**
 * The `device` API from a kernel that isn't in the app. Announces itself
 * and waits up to `timeoutMs` for the app showing this notebook to answer.
 * With no answer, every call rejects `unavailable`. Only the remote subset
 * is offered (REMOTE_METHODS), whatever the app answers. When the app goes
 * away, calls in flight reject `disconnected` and the next call announces
 * again. Run it from a cell: the app matches the announce to the session
 * of the cell that sent it.
 */
export async function connectDevice(api: CommApiLike, options: ConnectOptions = {}): Promise<Device> {
  const link = new CommLink(api, options.timeoutMs ?? 2000);
  try {
    await link.connect();
  } catch (err) {
    if (DeviceError.from(err).code === "unavailable") return unavailableDevice();
    throw err;
  }
  const hello = link.hello!;
  const info: DeviceInfo = { ...hello, capabilities: hello.capabilities.filter((m) => REMOTE_METHODS.has(m)) };
  const transport: DeviceTransport = { call: (method, params, callOptions) => link.call(method, params, callOptions) };
  return createDevice(transport, info);
}
