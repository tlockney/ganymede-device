// The `device` object cells use. It knows nothing about where it runs: every
// call goes through a DeviceTransport, which each kernel placement supplies
// (a Worker's host channel today; a host function in an embedded engine, or
// a Jupyter comm for remote kernels, later). See docs/protocol.md.

import { DeviceError } from "./errors.ts";

export interface CallOptions {
  signal?: AbortSignal;
}

/** Carries one request to the native host and back. */
export interface DeviceTransport {
  call(method: string, params: Record<string, unknown>, options?: CallOptions): Promise<unknown>;
}

/** What the host answers to `hello`, once, before the first cell. */
export interface DeviceInfo {
  /** "macos", "ipados", or "browser". */
  platform: string;
  appVersion: string;
  model?: string;
  osVersion?: string;
  /** The methods this host answers, such as "clipboard.readText". */
  capabilities: string[];
}

export interface Clipboard {
  /** The clipboard's text, or null when it holds none. */
  readText(options?: CallOptions): Promise<string | null>;
  writeText(text: string, options?: CallOptions): Promise<void>;
}

export interface Device {
  /** The host's answer to `hello`, as it was when the kernel started. */
  info(): Promise<DeviceInfo>;
  /** Whether the host answers `method`. Synchronous: it reads the cached `hello`. */
  has(method: string): boolean;
  readonly clipboard: Clipboard;
}

/** Asks the host who it is. Rejects when there is no host to ask. */
export async function hello(transport: DeviceTransport): Promise<DeviceInfo> {
  const info = await transport.call("hello", {});
  if (!isRecord(info) || typeof info.platform !== "string" || !Array.isArray(info.capabilities)) {
    throw new DeviceError("failed", "the host's hello reply is malformed");
  }
  return {
    ...info,
    platform: info.platform,
    appVersion: typeof info.appVersion === "string" ? info.appVersion : "",
    capabilities: info.capabilities.filter((c): c is string => typeof c === "string"),
  };
}

export function createDevice(transport: DeviceTransport, info: DeviceInfo): Device {
  const capabilities = new Set(info.capabilities);
  async function call(method: string, params: Record<string, unknown>, options?: CallOptions): Promise<unknown> {
    if (!capabilities.has(method)) throw new DeviceError("unavailable", `${method} isn't available on ${info.platform}`);
    try {
      return await transport.call(method, params, options);
    } catch (err) {
      throw DeviceError.from(err);
    }
  }
  return {
    info: () => Promise.resolve(structuredClone(info)),
    has: (method) => capabilities.has(method),
    clipboard: {
      async readText(options) {
        const text = await call("clipboard.readText", {}, options);
        return typeof text === "string" ? text : null;
      },
      async writeText(text, options) {
        await call("clipboard.writeText", { text: String(text) }, options);
      },
    },
  };
}

/** A Device whose every call rejects `unavailable`: what `import` gives on a kernel with no host. */
export function unavailableDevice(): Device {
  const transport: DeviceTransport = { call: () => Promise.reject(new DeviceError("unavailable", "this kernel has no device host")) };
  return createDevice(transport, { platform: "none", appVersion: "", capabilities: [] });
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
