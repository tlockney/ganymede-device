// The transport for a JavaScript engine embedded in the app, with no web
// view (docs/phase-4.md, part 1): Swift installs one function,
// `__ganymedeDevice(message)`, which takes a message as JSON text and
// answers JSON text. The messages are the ones webkitHost() posts
// (docs/protocol.md), handed to the same DeviceBridge dispatcher, so
// streams, handles and the ledger need nothing new.
//
//   const device = await installHostDevice(globalThis.__ganymedeDevice, { cellSignal: () => jupyter.signal });

import { decodeBinary, encodeBinary } from "./binary.ts";
import { type CallOptions, createDevice, type Device, type DeviceTransport, hello, type RunInput, runInput } from "./device.ts";
import { DeviceError } from "./errors.ts";

/** Swift's `__ganymedeDevice`: one message as JSON text in, the reply as JSON text out. */
export type HostPost = (message: string) => Promise<string>;

/** A transport over `__ganymedeDevice`. `release()` tells Swift this context is done with what it opened. */
export interface HostFunctionTransport extends DeviceTransport {
  release(): void;
}

/**
 * A transport that sends each call through `post`. Ids count from 1 per
 * transport: Swift keeps each engine context's ids and owner apart from
 * every other's, and stamps the context's owner on each message itself,
 * so the `owner` sent here is a placeholder. Aborting a call sends
 * `{ id, cancel: true }`; bytes cross as `{ base64 }` both ways.
 */
export function hostFunctionTransport(post: HostPost): HostFunctionTransport {
  let nextId = 0;
  const send = async (message: unknown): Promise<unknown> => {
    const text = await post(JSON.stringify(message));
    try {
      return JSON.parse(text);
    } catch {
      throw new DeviceError("failed", "the host's reply isn't JSON");
    }
  };
  return {
    async call(method: string, params: Record<string, unknown>, options: CallOptions = {}): Promise<unknown> {
      const signal = options.signal;
      const cancelled = () => DeviceError.from(signal?.reason ?? new DeviceError("cancelled", `${method} was cancelled before it was sent`));
      if (signal?.aborted) throw cancelled();
      // Encoded before the call has an id, so a value over the limit never
      // reaches Swift.
      const encoded = await encodeBinary(params ?? {});
      if (signal?.aborted) throw cancelled();
      const id = ++nextId;
      // Both listeners come off once the call settles: the signal is often
      // the cell's, shared by every call the cell makes.
      let rejectAbort: (() => void) | undefined;
      const aborted = new Promise<never>((_, reject) => (rejectAbort = () => reject(cancelled())));
      const onAbort = () => {
        void send({ id, cancel: true }).catch(() => {});
        rejectAbort?.();
      };
      signal?.addEventListener("abort", onAbort, { once: true });
      try {
        const reply = await Promise.race([send({ id, owner: 1, method, params: encoded }), aborted]);
        if (isRecord(reply) && isRecord(reply.error)) {
          throw DeviceError.from({
            name: "DeviceError",
            code: String(reply.error.code ?? "failed"),
            message: String(reply.error.message ?? `${method} failed`),
          });
        }
        return isRecord(reply) ? decodeBinary(reply.result) : undefined;
      } finally {
        signal?.removeEventListener("abort", onAbort);
      }
    },
    release() {
      void send({ owner: 1, release: true }).catch(() => {});
    },
  };
}

export interface InstallHostDeviceOptions {
  /** The running cell's signal, which an interrupt aborts. */
  cellSignal?: () => AbortSignal | undefined;
}

/**
 * The engine's preload: asks the host `hello` and installs
 * `globalThis.device`, as src/preload.ts does for the Worker. Returns the
 * device, or undefined when there is none: an `unavailable` hello stays
 * quiet, any other failure is one line on stderr.
 */
export async function installHostDevice(post: HostPost | undefined, options: InstallHostDeviceOptions = {}): Promise<Device | undefined> {
  if (typeof post !== "function") return undefined;
  const host = hostFunctionTransport(post);
  // The Worker's host aborts a cell's calls on interrupt; here the
  // transport does, with the cell's signal joined to the call's own.
  const cellSignal = () => {
    try {
      return options.cellSignal?.();
    } catch {
      return undefined;
    }
  };
  const transport: DeviceTransport = {
    call(method, params, callOptions = {}) {
      // A cell already interrupted doesn't bind the call: what the
      // interrupt itself sends (`stream.close`, a handle's close in a
      // `finally`) must still reach Swift, as it does from the Worker.
      const current = cellSignal();
      const cell = current?.aborted ? undefined : current;
      const signal = cell && callOptions.signal ? AbortSignal.any([cell, callOptions.signal]) : (cell ?? callOptions.signal);
      return host.call(method, params, { ...callOptions, signal });
    },
  };
  let info;
  try {
    info = await hello(transport);
  } catch (err) {
    const error = DeviceError.from(err);
    if (error.code !== "unavailable") console.error(`device: no device API, hello failed (${error.code}): ${error.message}`);
    return undefined;
  }
  // A run from the share sheet, Shortcuts or a widget has input; a
  // notebook's context doesn't answer input.
  let input: RunInput | null = null;
  if (info.capabilities.includes("input")) {
    try {
      input = runInput(await transport.call("input", {}));
    } catch (err) {
      const error = DeviceError.from(err);
      console.error(`device: the run's input couldn't be read (${error.code}): ${error.message}`);
    }
  }
  const device = createDevice(transport, info, { cellSignal, input });
  Object.defineProperty(globalThis, "device", { value: device, configurable: true, writable: false });
  return device;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
