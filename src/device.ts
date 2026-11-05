// The `device` object cells use. It knows nothing about where it runs: every
// call goes through a DeviceTransport, which each kernel placement supplies
// (a Worker's host channel today; a host function in an embedded engine, or
// a Jupyter comm for remote kernels, later). See docs/protocol.md.

import { type Bytes, MAX_BINARY_BYTES, toBytes } from "./binary.ts";
import { DeviceError } from "./errors.ts";

/**
 * Every method takes these. Aborting `signal`, or interrupting the kernel,
 * cancels the call: it rejects with a `DeviceError` whose code is
 * `cancelled` (`timeout` for `AbortSignal.timeout()`), and the host drops
 * any dialog or prompt it showed for it.
 *
 * Where each method works is in `SUPPORT` (src/support.ts); the docs'
 * table is generated from it.
 */
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

/**
 * Taptic feedback. iPhone only: iPads and Macs have no Taptic Engine, so
 * there `has()` is false and calls fail `unavailable`. No permission.
 * Remote kernels: planned. Browser: no.
 */
export interface Haptics {
  /** A tap, `"medium"` by default. Cancel rejects `cancelled`; the tap may already have played. */
  impact(style?: ImpactStyle, options?: CallOptions): Promise<void>;
  /** The success, warning or error pattern. Cancel rejects `cancelled`. */
  notification(type: NotificationFeedback, options?: CallOptions): Promise<void>;
  /** The tick of a picker moving. Cancel rejects `cancelled`. */
  selection(options?: CallOptions): Promise<void>;
}

export interface OpenURLOptions extends CallOptions {
  /** On iPhone and iPad, show a web page in the app (Safari view) instead of switching to Safari. Ignored on the Mac. */
  inApp?: boolean;
}

/**
 * The system clipboard. On-device: Mac, iPad and iPhone, no permission
 * (iPadOS may show its paste prompt on a read). Remote kernels and the
 * browser: planned; a browser will need a click first.
 */
export interface Clipboard {
  /** The clipboard's text, or null when it holds none. Cancel rejects `cancelled`. */
  readText(options?: CallOptions): Promise<string | null>;
  /** Replaces the clipboard with `text`. Cancel rejects `cancelled`; the write may already have happened. */
  writeText(text: string, options?: CallOptions): Promise<void>;
  /** The clipboard's image as PNG bytes, or null when it holds none. Cancel rejects `cancelled`. */
  readImage(options?: CallOptions): Promise<Uint8Array | null>;
  /**
   * Puts an image on the clipboard. PNG, JPEG, GIF, HEIC or TIFF bytes;
   * anything else fails `failed`. Cancel rejects `cancelled`; the write may
   * already have happened.
   */
  writeImage(image: Bytes, options?: CallOptions): Promise<void>;
}

export interface AlertOptions extends CallOptions {
  /** A heading above the message. */
  title?: string;
}

export interface ConfirmOptions extends AlertOptions {
  /** Shows the confirming button as destructive (red). */
  destructive?: boolean;
  /** The confirming button's label; "OK" by default. */
  okLabel?: string;
}

export interface PromptOptions extends AlertOptions {
  /** Grey text shown while the field is empty. */
  placeholder?: string;
  /** Text the field starts with. */
  defaultValue?: string;
  /** Hides what is typed, as for a password. */
  secure?: boolean;
}

export interface ActionSheetOptions extends CallOptions {
  /** A line under the title. */
  message?: string;
  /** The cancel button's label; "Cancel" by default. */
  cancel?: string;
  /** The index of an option to show as destructive (red). */
  destructive?: number;
}

export type DateMode = "date" | "time" | "datetime";

export interface PickDateOptions extends CallOptions {
  /** What to pick; "datetime" by default. */
  mode?: DateMode;
  /** A heading above the picker. */
  title?: string;
  /** The date the picker starts at; now by default. */
  value?: Date;
  min?: Date;
  max?: Date;
}

/** A file a cell hands over: a `File`, or bytes with the name to show and save them under. */
export type NamedBytes = File | { name: string; data: Bytes };

export interface ShareOptions extends CallOptions {
  /** Text to share, such as a message or a caption. */
  text?: string;
  /** A link to share. */
  url?: string | URL;
  /** Files to share; their names are what the receiving app sees. */
  files?: NamedBytes[];
}

/**
 * Dialogs the app shows over the notebook: sheets on the Mac, alerts on
 * iPhone and iPad. One shows at a time; a second call waits for the first
 * to close. Dismissing one is not an error: it returns `null` or `false`.
 * An interrupt or an aborted `signal` closes it and rejects `cancelled`
 * (`timeout` for `AbortSignal.timeout()`). On-device: Mac, iPad and iPhone,
 * no permission. Remote kernels and the browser: planned.
 */
export interface UI {
  /** Shows `message` with an OK button, and resolves when it is closed. Cancel closes it and rejects `cancelled`. */
  alert(message: string, options?: AlertOptions): Promise<void>;
  /** True when the person confirms, false when they cancel or dismiss it. Cancel closes it and rejects `cancelled`. */
  confirm(message: string, options?: ConfirmOptions): Promise<boolean>;
  /** The text entered, or null when the person cancels. Cancel closes it and rejects `cancelled`. */
  prompt(message: string, options?: PromptOptions): Promise<string | null>;
  /** The index of the option chosen, or null when the person cancels. Cancel closes it and rejects `cancelled`. */
  actionSheet(title: string, options: string[], sheetOptions?: ActionSheetOptions): Promise<number | null>;
  /** The date chosen, or null when the person cancels. Cancel closes it and rejects `cancelled`. */
  pickDate(options?: PickDateOptions): Promise<Date | null>;
}

export interface Device {
  /**
   * The host's answer to `hello`, as it was when the kernel started, with
   * the current screen, battery, appearance and locale when the host
   * answers `info`. On-device: Mac, iPad and iPhone, no permission. Remote
   * kernels and the browser: planned (a browser has no model or battery).
   * Cancel rejects `cancelled`.
   */
  info(options?: CallOptions): Promise<DeviceInfo>;
  /**
   * Whether the host answers `method`, such as `"clipboard.readText"`.
   * Synchronous: it reads the cached `hello`, so it can't be cancelled.
   */
  has(method: string): boolean;
  readonly clipboard: Clipboard;
  readonly haptics: Haptics;
  /**
   * Opens an `http`, `https` or `mailto` URL; other schemes fail `failed`.
   * On-device: Mac, iPad and iPhone, no permission; `inApp` only on iPad
   * and iPhone. Remote kernels and the browser: planned (a browser opens a
   * tab after a click). Cancel rejects `cancelled`; the URL may already
   * have opened.
   */
  openURL(url: string | URL, options?: OpenURLOptions): Promise<void>;
  /** Dialogs over the notebook; see `UI`. */
  readonly ui: UI;
  /**
   * Shows the system share sheet (`NSSharingServicePicker` on the Mac)
   * with `text`, `url` and `files`; at least one is needed. True when the
   * person picked where to send them, false when they dismissed it. The
   * sheet is its own consent, so no permission. Files together are at
   * most 16 MiB. On-device: Mac, iPad and iPhone. Remote kernels and the
   * browser: planned (a browser after a click). Cancel closes it and
   * rejects `cancelled`.
   */
  share(options: ShareOptions): Promise<boolean>;
  /**
   * Shows `files` in Quick Look and resolves when the person closes it.
   * Quick Look picks the viewer from each name's extension, so name a PNG
   * `*.png`. Files together are at most 16 MiB. On-device: Mac, iPad and
   * iPhone, no permission. Remote kernels: planned. Browser: no. Cancel
   * closes it and rejects `cancelled`.
   */
  preview(files: NamedBytes[], options?: CallOptions): Promise<void>;
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
    ui: {
      async alert(message, options = {}) {
        const { signal, title } = options;
        await call("ui.alert", { message: String(message), ...defined({ title }) }, { signal });
      },
      async confirm(message, options = {}) {
        const { signal, title, destructive = false, okLabel } = options;
        const result = await call("ui.confirm", { message: String(message), destructive, ...defined({ title, okLabel }) }, { signal });
        return result === true;
      },
      async prompt(message, options = {}) {
        const { signal, title, placeholder, defaultValue, secure = false } = options;
        const result = await call("ui.prompt", { message: String(message), secure, ...defined({ title, placeholder, defaultValue }) }, { signal });
        return typeof result === "string" ? result : null;
      },
      async actionSheet(title, choices, options = {}) {
        const { signal, message, cancel, destructive } = options;
        if (!Array.isArray(choices) || choices.length === 0) throw new DeviceError("failed", "actionSheet needs at least one option");
        const params = { title: String(title), options: choices.map(String), ...defined({ message, cancel, destructive }) };
        const result = await call("ui.actionSheet", params, { signal });
        return typeof result === "number" && Number.isInteger(result) && result >= 0 && result < choices.length ? result : null;
      },
      async pickDate(options = {}) {
        const { signal, mode = "datetime", title, value, min, max } = options;
        const params = { mode, ...defined({ title, value: iso(value), min: iso(min), max: iso(max) }) };
        const result = await call("ui.pickDate", params, { signal });
        if (typeof result !== "string") return null;
        const date = new Date(result);
        if (Number.isNaN(date.getTime())) throw new DeviceError("failed", `ui.pickDate answered a date it can't read: ${result}`);
        return date;
      },
    },
    async share(options) {
      const { signal, text, url, files } = options ?? {};
      if (text === undefined && url === undefined && (files === undefined || files.length === 0)) {
        throw new DeviceError("failed", "share needs text, a url or files");
      }
      // Checked first, so a host without it fails `unavailable` before files are read.
      requireMethod("share");
      const params = {
        ...defined({ text: text === undefined ? undefined : String(text), url: url === undefined ? undefined : String(url) }),
        files: files === undefined ? [] : await namedFiles("share", files),
      };
      return (await call("share", params, { signal })) === true;
    },
    async preview(files, options = {}) {
      if (!Array.isArray(files) || files.length === 0) throw new DeviceError("failed", "preview needs at least one file");
      requireMethod("preview");
      await call("preview", { files: await namedFiles("preview", files) }, options);
    },
  };
}

/** Each file as `{ name, data }` bytes, checked for a name and a total within the binary limit. */
async function namedFiles(method: string, files: NamedBytes[]): Promise<{ name: string; data: Uint8Array }[]> {
  if (!Array.isArray(files)) throw new DeviceError("failed", `${method} takes an array of files`);
  const out: { name: string; data: Uint8Array }[] = [];
  let total = 0;
  for (const file of files) {
    const isFile = typeof File !== "undefined" && file instanceof File;
    const name = isFile ? file.name : (file as { name?: unknown })?.name;
    if (typeof name !== "string" || !name.trim() || name === "." || name === ".." || /[/\\\0]/.test(name)) {
      throw new DeviceError("failed", `${method}: each file needs a plain file name (no slashes)`);
    }
    // A File's size is known before reading it.
    if (isFile && total + file.size > MAX_BINARY_BYTES) {
      throw new DeviceError("failed", `${method}: files together are limited to ${MAX_BINARY_BYTES} bytes`);
    }
    const data = await toBytes(isFile ? file : (file as { data: Bytes }).data);
    total += data.byteLength;
    if (total > MAX_BINARY_BYTES) {
      throw new DeviceError("failed", `${method}: files together are limited to ${MAX_BINARY_BYTES} bytes`);
    }
    out.push({ name, data });
  }
  return out;
}

/** `fields` without its undefined values, so they aren't sent. */
function defined(fields: Record<string, unknown>): Record<string, unknown> {
  return Object.fromEntries(Object.entries(fields).filter(([, v]) => v !== undefined));
}

/** A date as the ISO 8601 string the host reads, or undefined. */
function iso(date: Date | undefined): string | undefined {
  if (date === undefined) return undefined;
  if (!(date instanceof Date) || Number.isNaN(date.getTime())) throw new DeviceError("failed", "pickDate takes Date values");
  return date.toISOString();
}

/** A Device whose every call rejects `unavailable`: what `import` gives on a kernel with no host. */
export function unavailableDevice(): Device {
  const transport: DeviceTransport = { call: () => Promise.reject(new DeviceError("unavailable", "this kernel has no device host")) };
  return createDevice(transport, { platform: "none", appVersion: "", capabilities: [] });
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
