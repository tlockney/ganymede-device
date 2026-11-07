// The app's end of the remote transport (docs/protocol.md, "Over a Jupyter
// comm"): a notebook page that shows a kernel running elsewhere answers that
// kernel's `connectDevice` (src/comm.ts) and forwards its calls to the native
// host. The page gives a `forward` function that reaches the host; in the
// Ganymede app it posts to the Swift bridge's remote handler
// (`DeviceBridge.registerRemote`), which takes only the remote subset.
//
//   import { answerDevice } from "@tlockney/ganymede-device/frontend";
//   const answerer = answerDevice(kernel, { forward: webkitForward() });
//   // … when the page stops showing that kernel connection:
//   answerer.dispose();
//
// `kernel` is a `@jupyterlab/services` kernel connection, used through the
// few members below, so this package doesn't depend on JupyterLab.

import { ANNOUNCE_TARGET, CALLS_TARGET, REMOTE_METHODS } from "./comm.ts";
import { findMessageHandler } from "./webkit.ts";

/** A comm message as `@jupyterlab/services` hands it over. */
export interface KernelCommMessage {
  parent_header?: { session?: unknown } | Record<string, never>;
  content: { data?: unknown };
}

/** A JSON value, as Lumino's `JSONValue`, which comm data must be. */
export type JsonValue = null | boolean | number | string | JsonValue[] | JsonObject;
export interface JsonObject {
  [key: string]: JsonValue;
}

/**
 * A message callback. Declared as a method, so its parameter is checked
 * both ways and `IComm`'s callbacks, typed with the full message, fit.
 */
export type CommCallback = { bivarianceHack(msg: KernelCommMessage): void | PromiseLike<void> }["bivarianceHack"];

/** The part of a `@jupyterlab/services` `IComm` this uses. */
export interface KernelComm {
  readonly isDisposed: boolean;
  onMsg: CommCallback | undefined;
  onClose: CommCallback | undefined;
  open(data?: JsonObject): unknown;
  send(data: JsonObject): unknown;
  close(data?: JsonObject): unknown;
}

/** The part of a `@jupyterlab/services` `IKernelConnection` this uses. */
export interface KernelConnectionLike {
  /** The session id the connection puts in every message it sends. */
  readonly clientId: string;
  registerCommTarget(target: string, callback: (comm: KernelComm, msg: KernelCommMessage) => void | PromiseLike<void>): void;
  removeCommTarget(target: string, callback: (comm: KernelComm, msg: KernelCommMessage) => void | PromiseLike<void>): void;
  createComm(target: string): KernelComm;
  /** The kernel's status, to drop the link on a restart. */
  readonly statusChanged?: {
    connect(slot: (sender: unknown, status: string) => void): unknown;
    disconnect(slot: (sender: unknown, status: string) => void): unknown;
  };
}

/**
 * Sends one host message, in the shape the Swift bridge takes
 * (docs/protocol.md, "Messages Swift receives"), and resolves with its
 * reply: `{ result }` or `{ error: { code, message } }`.
 */
export type Forward = (message: Record<string, unknown>) => Promise<unknown>;

export interface AnswerOptions {
  /** Reaches the native host; `webkitForward()` by default. */
  forward?: Forward;
  /**
   * Asked on each announce: false turns the kernel away, as when the
   * person muted the server it runs on. Calls on a link already open
   * still go through until it closes.
   */
  accept?: () => boolean;
}

export interface DeviceAnswerer {
  /** Calls forwarded and not yet answered. */
  readonly pending: number;
  /** Stops answering: closes the calls comm, cancels what it forwarded, and releases its sounds. */
  dispose(): void;
}

/** The page's remote handler in the app, `deviceRemote` (`DeviceBridge.remoteHandlerName`). */
export const REMOTE_HANDLER = "deviceRemote";

/** A Forward that posts to the app's remote handler; every message fails `unavailable` outside the app. */
export function webkitForward(name = REMOTE_HANDLER): Forward {
  return async (message) => {
    const handler = findMessageHandler(name);
    if (!handler) return { error: { code: "unavailable", message: "this page isn't in the app (no WebKit device handler)" } };
    return handler.postMessage(message);
  };
}

/** True when the page can answer: it is in the app, which registered the remote handler. */
export function canAnswer(name = REMOTE_HANDLER): boolean {
  return findMessageHandler(name) !== null;
}

// One counter for the page, as in webkit.ts: every answerer posts to the
// same host handler, so a cancel's id must name one call across all of them.
let nextId = 0;
let nextOwner = 0;

/**
 * Answers `connectDevice` from cells of the kernel behind `kernel`: an
 * announce whose session is this connection's own (a cell this page ran)
 * gets a calls comm back, opened with the host's `hello` cut to the remote
 * subset; any other announce is left alone, so a second client on the same
 * kernel never answers for this one. Calls outside the remote subset fail
 * `unavailable` here, before the host sees them.
 */
export function answerDevice(kernel: KernelConnectionLike, options: AnswerOptions = {}): DeviceAnswerer {
  const forward = options.forward ?? webkitForward();
  const owner = ++nextOwner;
  // Kernel call id → page call id, for what the host hasn't answered.
  const inFlight = new Map<number, number>();
  let comm: KernelComm | null = null;
  let disposed = false;
  let opening = false;

  const post = (message: Record<string, unknown>): Promise<unknown> =>
    forward(message).catch((err: unknown) => ({ error: { code: "failed", message: String((err as Error)?.message ?? err) } }));

  const cancelAll = () => {
    for (const id of inFlight.values()) void post({ id, cancel: true });
    inFlight.clear();
  };

  /** Forgets the calls comm, closing it, and cancels what it had in flight. */
  const drop = () => {
    const calls = comm;
    comm = null;
    cancelAll();
    if (calls && !calls.isDisposed) calls.close();
  };

  const onAnnounce = async (_announce: KernelComm, msg: KernelCommMessage): Promise<void> => {
    // The announce stays open: the kernel closes it once answered.
    if (disposed || opening) return;
    if (msg.parent_header?.session !== kernel.clientId) return;
    if (options.accept && !options.accept()) return;
    opening = true;
    try {
      const reply = await post({ owner, method: "hello", params: {} });
      if (disposed || !isRecord(reply) || !isRecord(reply.result)) return;
      const hello = reply.result;
      const capabilities = Array.isArray(hello.capabilities) ? hello.capabilities : [];
      const calls = kernel.createComm(CALLS_TARGET);
      // The kernel announces only when it has no link, so an old one is
      // gone on its side (it restarted, or dropped the link): what it had
      // in flight is moot.
      drop();
      comm = calls;
      calls.onMsg = (m) => receive(calls, m);
      calls.onClose = () => {
        if (comm !== calls) return;
        comm = null;
        cancelAll();
      };
      calls.open({ ...hello, capabilities: capabilities.filter((c) => typeof c === "string" && REMOTE_METHODS.has(c)) } as JsonObject);
    } finally {
      opening = false;
    }
  };

  const receive = async (calls: KernelComm, msg: KernelCommMessage): Promise<void> => {
    const data = msg.content.data;
    if (!isRecord(data)) return;
    // Replies come from the host as JSON (WebKit's reply is a plist value).
    const send = (reply: Record<string, unknown>) => {
      if (comm === calls && !calls.isDisposed) calls.send(reply as JsonObject);
    };
    if (typeof data.ping === "number") {
      send({ pong: data.ping });
      return;
    }
    if (typeof data.id !== "number") return;
    const kernelId = data.id;
    if (data.cancel === true) {
      const id = inFlight.get(kernelId);
      inFlight.delete(kernelId);
      if (id !== undefined) void post({ id, cancel: true });
      return;
    }
    const method = data.method;
    if (typeof method !== "string" || !REMOTE_METHODS.has(method)) {
      send({ id: kernelId, error: { code: "unavailable", message: `${String(method)} isn't available over a remote kernel` } });
      return;
    }
    const id = ++nextId;
    inFlight.set(kernelId, id);
    const reply = await post({ id, owner, method, params: isRecord(data.params) ? data.params : {} });
    // Cancelled, or the link closed, while the host worked: drop the reply.
    if (inFlight.get(kernelId) !== id) return;
    inFlight.delete(kernelId);
    send({ id: kernelId, ...(isRecord(reply) && ("result" in reply || "error" in reply) ? pick(reply) : { result: null }) });
  };

  kernel.registerCommTarget(ANNOUNCE_TARGET, onAnnounce);
  // A restart disposes the connection's comms without an onClose.
  const onStatus = (_: unknown, status: string) => {
    if (status === "restarting" || status === "autorestarting" || status === "dead") drop();
  };
  let statusSlot: (() => void) | undefined;
  if (kernel.statusChanged) {
    kernel.statusChanged.connect(onStatus);
    statusSlot = () => kernel.statusChanged?.disconnect(onStatus);
  }

  return {
    get pending() {
      return inFlight.size;
    },
    dispose() {
      if (disposed) return;
      disposed = true;
      kernel.removeCommTarget(ANNOUNCE_TARGET, onAnnounce);
      statusSlot?.();
      drop();
      void post({ owner, release: true });
    },
  };
}

/** The reply's `result` or `error`, nothing else from the host. */
function pick(reply: Record<string, unknown>): Record<string, unknown> {
  return "error" in reply && reply.error !== undefined && reply.error !== null ? { error: reply.error } : { result: reply.result ?? null };
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
