// The `device` object cells use. It knows nothing about where it runs: every
// call goes through a DeviceTransport, which each kernel placement supplies
// (a Worker's host channel today; a host function in an embedded engine, or
// a Jupyter comm for remote kernels, later). See docs/protocol.md.

import { type Bytes, toBytes } from "./binary.ts";
import { DeviceError } from "./errors.ts";

export interface CallOptions {
  signal?: AbortSignal;
}

/** Carries one request to the native host and back. */
export interface DeviceTransport {
  call(method: string, params: Record<string, unknown>, options?: CallOptions): Promise<unknown>;
}

/** What the host answers to `hello`, once, before the first cell, and the current state when it answers `info`. */
export interface DeviceInfo {
  /** "macos", "ipados", or "browser". */
  platform: string;
  appVersion: string;
  /** The hardware model identifier, such as "Mac14,2" or "iPad13,4". */
  model?: string;
  osVersion?: string;
  /** The methods this host answers, such as "clipboard.readText". */
  capabilities: string[];
  /** The rest is from `info`, read when `info()` is called, on hosts that answer it. */
  isPad?: boolean;
  /** The main screen in points, and its points-to-pixels scale. */
  screen?: { width: number; height: number; scale: number };
  /** Absent on a device without a battery. `level` is 0 to 1, or null when unknown. */
  battery?: { level: number | null; charging: boolean };
  darkMode?: boolean;
  /** The person's locale as a BCP 47 tag, such as "en-US". */
  locale?: string;
}

export type ImpactStyle = "light" | "medium" | "heavy" | "soft" | "rigid";
export type NotificationFeedback = "success" | "warning" | "error";

/** Taptic feedback. iPhone only: iPads and Macs have no Taptic Engine, so there `has()` is false and calls fail `unavailable`. */
export interface Haptics {
  impact(style?: ImpactStyle, options?: CallOptions): Promise<void>;
  notification(type: NotificationFeedback, options?: CallOptions): Promise<void>;
  selection(options?: CallOptions): Promise<void>;
}

export interface OpenURLOptions extends CallOptions {
  /** On iPhone and iPad, show a web page in the app (Safari view) instead of switching to Safari. Ignored on the Mac. */
  inApp?: boolean;
}

export interface Clipboard {
  /** The clipboard's text, or null when it holds none. */
  readText(options?: CallOptions): Promise<string | null>;
  writeText(text: string, options?: CallOptions): Promise<void>;
  /** The clipboard's image as PNG bytes, or null when it holds none. */
  readImage(options?: CallOptions): Promise<Uint8Array | null>;
  /** Puts an image on the clipboard. PNG, JPEG, GIF, HEIC or TIFF bytes; anything else fails `failed`. */
  writeImage(image: Bytes, options?: CallOptions): Promise<void>;
}

export interface Device {
  /**
   * The host's answer to `hello`, as it was when the kernel started, with
   * the current screen, battery, appearance and locale when the host
   * answers `info`.
   */
  info(options?: CallOptions): Promise<DeviceInfo>;
  /** Whether the host answers `method`. Synchronous: it reads the cached `hello`. */
  has(method: string): boolean;
  readonly clipboard: Clipboard;
  readonly haptics: Haptics;
  /** Opens an `http`, `https` or `mailto` URL; other schemes fail `failed`. */
  openURL(url: string | URL, options?: OpenURLOptions): Promise<void>;
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
  function requireMethod(method: string): void {
    if (!capabilities.has(method)) throw new DeviceError("unavailable", `${method} isn't available on ${info.platform}`);
  }
  async function call(method: string, params: Record<string, unknown>, options?: CallOptions): Promise<unknown> {
    requireMethod(method);
    try {
      return await transport.call(method, params, options);
    } catch (err) {
      throw DeviceError.from(err);
    }
  }
  return {
    async info(options) {
      const snapshot = structuredClone(info);
      if (!capabilities.has("info")) return snapshot;
      const current = await call("info", {}, options);
      // What `hello` said stays as it said it: the capabilities are what
      // this device was built with.
      return {
        ...snapshot,
        ...(isRecord(current) ? current : {}),
        platform: snapshot.platform,
        appVersion: snapshot.appVersion,
        capabilities: snapshot.capabilities,
      };
    },
    has: (method) => capabilities.has(method),
    clipboard: {
      async readText(options) {
        const text = await call("clipboard.readText", {}, options);
        return typeof text === "string" ? text : null;
      },
      async writeText(text, options) {
        await call("clipboard.writeText", { text: String(text) }, options);
      },
      async readImage(options) {
        const image = await call("clipboard.readImage", {}, options);
        if (image instanceof Uint8Array) return image;
        if (image instanceof ArrayBuffer) return new Uint8Array(image);
        return null;
      },
      async writeImage(image, options) {
        // Checked first, so a host without it fails `unavailable` before a Blob is read.
        requireMethod("clipboard.writeImage");
        await call("clipboard.writeImage", { image: await toBytes(image) }, options);
      },
    },
    haptics: {
      async impact(style = "medium", options) {
        await call("haptics.impact", { style }, options);
      },
      async notification(type, options) {
        await call("haptics.notification", { type }, options);
      },
      async selection(options) {
        await call("haptics.selection", {}, options);
      },
    },
    async openURL(url, options = {}) {
      const { inApp = false, ...callOptions } = options;
      await call("openURL", { url: String(url), inApp }, callOptions);
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
