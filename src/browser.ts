// The browser fallback (docs/plan.md, "Browser fallback"): a Forward for
// `answerDevice` (src/frontend.ts) that answers a remote kernel's calls with
// web APIs, for a notebook page in a browser instead of the app.
//
//   import { answerDevice } from "@tlockney/ganymede-device/frontend";
//   import { browserForward } from "@tlockney/ganymede-device/browser";
//   answerDevice(kernel, { forward: browserForward({ click }) });
//
// Most of these APIs need a recent click (user activation), and a message
// from the kernel is not one. So the page gives a `click` function that
// shows a prompt ("Copy to clipboard", "Choose file") and runs the call from
// inside that click's handler. Without one, those methods aren't offered.

import { decodeBase64, encodeBase64, MAX_BINARY_BYTES } from "./binary.ts";
import type { Forward } from "./frontend.ts";
import { REMOTE_METHODS } from "./comm.ts";
import { SUPPORT, type SupportRow } from "./support.ts";

/** What the page is asked to show: a prompt with one button. */
export interface ClickRequest {
  /** The device method that needs the click, such as "clipboard.writeText". */
  method: string;
  /** The button's label, such as "Copy to clipboard". */
  label: string;
  /**
   * What the call carries, for the prompt to preview: the text
   * `clipboard.writeText` copies, or the text or URL `share` shares.
   * Whole; the page truncates it for display.
   */
  detail?: string;
  /** Aborted when the kernel cancels the call: take the prompt down. */
  signal: AbortSignal;
}

/**
 * Shows a prompt for `request`. When the person clicks it, call `run()`
 * from inside the click's event handler, before any `await`, and resolve
 * with what it resolves to. Reject when the person dismisses the prompt or
 * `request.signal` aborts; the call then fails `cancelled`.
 */
export type Click = (request: ClickRequest, run: () => Promise<unknown>) => Promise<unknown>;

export interface BrowserForwardOptions {
  /** Shows click-through prompts; methods that need a click are left out without it. */
  click?: Click;
  /** The browser globals used; `globalThis` by default. Tests pass fakes. */
  env?: BrowserEnv;
}

/** The globals this uses, so tests can stand in for a browser. */
export interface BrowserEnv {
  navigator?: {
    language?: string;
    clipboard?: {
      readText?(): Promise<string>;
      writeText?(text: string): Promise<void>;
      read?(): Promise<{ types: readonly string[]; getType(type: string): Promise<Blob> }[]>;
      write?(items: unknown[]): Promise<void>;
    };
    share?(data: { text?: string; url?: string; files?: File[] }): Promise<void>;
    canShare?(data: { files?: File[] }): boolean;
  };
  document?: Pick<Document, "createElement" | "body">;
  screen?: { width: number; height: number };
  devicePixelRatio?: number;
  matchMedia?(query: string): { matches: boolean };
  open?(url: string, target?: string, features?: string): unknown;
  Audio?: new (src?: string) => { volume: number; play(): Promise<void>; pause(): void; addEventListener(type: string, fn: () => void): void };
  ClipboardItem?: new (items: Record<string, Blob>) => unknown;
  URL?: { createObjectURL(blob: Blob): string; revokeObjectURL(url: string): void };
}

type Params = Record<string, unknown>;
type Reply = { result: unknown } | { error: { code: string; message: string } };

class Failure extends Error {
  readonly code: string;
  constructor(code: string, message: string) {
    super(message);
    this.code = code;
  }
}

/** The person dismissed the prompt: `cancelled`, or the method's own answer for a cancel. */
class Dismissed extends Failure {
  constructor(message: string) {
    super("cancelled", message);
  }
}

/**
 * A Forward that answers with web APIs. `hello` lists what this browser
 * has; calls the browser lets a page make only after a click go through
 * `options.click`. A `{ id, cancel: true }` aborts that call's prompt.
 */
export function browserForward(options: BrowserForwardOptions = {}): Forward {
  const env: BrowserEnv = options.env ?? (globalThis as unknown as BrowserEnv);
  const click = options.click;
  const inFlight = new Map<number, AbortController>();
  const capabilities = browserCapabilities(env, click !== undefined);
  // Sounds each owner started, until they end: a release (or the owner's
  // next hello, a restarted kernel) stops them, as on the device.
  const sounds = new Map<number, Set<() => void>>();
  const stopSounds = (owner: number) => {
    for (const stop of sounds.get(owner) ?? []) stop();
    sounds.delete(owner);
  };

  // One prompt at a time, in the order the calls came, as the app's
  // dialog queue shows one dialog at a time.
  let prompts: Promise<unknown> = Promise.resolve();

  const needClick = async (
    method: string,
    label: string,
    signal: AbortSignal,
    run: () => Promise<unknown>,
    detail?: string,
  ): Promise<unknown> => {
    if (!click) throw new Failure("unavailable", `${method} needs a click, and this page can't ask for one`);
    const cancelled = () => new Failure("cancelled", `${method} was cancelled`);
    // Cancelled while an earlier step was pending: no prompt at all.
    if (signal.aborted) throw cancelled();
    const before = prompts;
    let finished!: () => void;
    prompts = new Promise<void>((resolve) => (finished = resolve));
    try {
      // Waits for the prompt before it, or a cancel, whichever comes first.
      await new Promise<void>((resolve, reject) => {
        const onAbort = () => reject(cancelled());
        signal.addEventListener("abort", onAbort, { once: true });
        void before.then(() => {
          signal.removeEventListener("abort", onAbort);
          resolve();
        });
      });
      if (signal.aborted) throw cancelled();
      let ran = false;
      const request: ClickRequest = { method, label, signal, ...(detail !== undefined && { detail }) };
      return await click(request, () => {
        ran = true;
        return run();
      }).catch((err: unknown) => {
        // Rejected before the click: the kernel cancelled the call, or
        // the person dismissed the prompt.
        if (ran) throw err;
        throw signal.aborted ? cancelled() : new Dismissed(`${method}: the prompt was dismissed`);
      });
    } finally {
      // In order: a call cancelled while it waits lets the next one show
      // only after the prompt ahead of it closes.
      void before.then(finished);
    }
  };

  const call = async (method: string, params: Params, signal: AbortSignal, owner: number): Promise<unknown> => {
    if (!capabilities.includes(method)) throw new Failure("unavailable", `${method} isn't available in this browser`);
    const nav = env.navigator;
    switch (method) {
      case "info":
        return {
          ...(env.screen ? { screen: { width: env.screen.width, height: env.screen.height, scale: env.devicePixelRatio ?? 1 } } : {}),
          darkMode: env.matchMedia?.("(prefers-color-scheme: dark)").matches ?? false,
          ...(nav?.language ? { locale: nav.language } : {}),
        };
      case "clipboard.readText": {
        const text = await needClick(method, "Paste from clipboard", signal, () => nav!.clipboard!.readText!());
        return typeof text === "string" && text !== "" ? text : null;
      }
      case "clipboard.writeText": {
        const text = need(params, "text");
        await needClick(method, "Copy to clipboard", signal, () => nav!.clipboard!.writeText!(text), text);
        return null;
      }
      case "clipboard.readImage": {
        const blob = await needClick(method, "Paste image from clipboard", signal, async () => {
          for (const item of await nav!.clipboard!.read!()) {
            if (item.types.includes("image/png")) return item.getType("image/png");
          }
          return null;
        });
        return blob instanceof Blob ? binary(new Uint8Array(await blob.arrayBuffer())) : null;
      }
      case "clipboard.writeImage": {
        const bytes = bytesOf(params.image, "image");
        if (!isPng(bytes)) throw new Failure("failed", "a browser's clipboard takes PNG images only");
        const item = new env.ClipboardItem!({ "image/png": new Blob([bytes as BlobPart], { type: "image/png" }) });
        await needClick(method, "Copy image to clipboard", signal, () => nav!.clipboard!.write!([item]));
        return null;
      }
      case "openURL": {
        const url = need(params, "url");
        if (!/^(https?|mailto):/i.test(url)) throw new Failure("failed", "only http, https and mailto URLs open");
        await needClick(method, `Open ${url}`, signal, async () => void env.open!(url, "_blank", "noopener"));
        return null;
      }
      case "share": {
        const data: { text?: string; url?: string; files?: File[] } = {};
        if (typeof params.text === "string") data.text = params.text;
        if (typeof params.url === "string") {
          if (!/^(https?|mailto):/i.test(params.url)) throw new Failure("failed", "a shared URL must be http, https or mailto");
          data.url = params.url;
        }
        const files = Array.isArray(params.files) ? params.files.map((f, i) => toFile(f, i)) : [];
        checkTotal(files.map((f) => f.size));
        if (files.length) {
          if (!nav?.canShare?.({ files })) throw new Failure("unavailable", "this browser can't share files");
          data.files = files;
        }
        if (!data.text && !data.url && !data.files) throw new Failure("failed", "share needs text, a url or files");
        try {
          await needClick(method, "Share", signal, () => nav!.share!(data), data.text || data.url);
          return true;
        } catch (err) {
          // The person dismissed the prompt or closed the share sheet.
          if (err instanceof Dismissed) return false;
          if ((err as { name?: unknown })?.name === "AbortError" && !signal.aborted) return false;
          throw err;
        }
      }
      case "files.pick":
      case "photos.pick": {
        const photos = method === "photos.pick";
        const limit = photos ? (typeof params.limit === "number" ? params.limit : 1) : undefined;
        const accept = photos ? "image/*" : acceptOf(params.types);
        const multiple = photos ? limit !== 1 : params.multiple === true;
        const label = photos ? (multiple ? "Choose images" : "Choose an image") : multiple ? "Choose files" : "Choose a file";
        let picked: File[];
        try {
          picked = (await needClick(method, label, signal, () => pickFiles(env, accept, multiple, signal))) as File[];
        } catch (err) {
          if (err instanceof Dismissed) return [];
          throw err;
        }
        const files = limit ? picked.slice(0, limit) : picked;
        checkTotal(files.map((f) => f.size));
        return Promise.all(files.map(async (f) => ({ name: f.name, type: f.type, data: binary(new Uint8Array(await f.arrayBuffer())) })));
      }
      case "files.export": {
        const name = need(params, "name");
        if (!plainName(name)) throw new Failure("failed", "a file name must be plain: no slash, backslash or NUL, and not . or ..");
        const bytes = bytesOf(params.data, "data");
        // Behind a click, as the app shows a save panel: a kernel saves
        // nothing on this machine unasked.
        try {
          await needClick(method, `Save ${name}`, signal, async () => download(env, name, bytes));
        } catch (err) {
          if (err instanceof Dismissed) return false;
          throw err;
        }
        // The browser saves it or asks where; the page can't tell which.
        return true;
      }
      case "sound.play": {
        const bytes = bytesOf(params.data, "data");
        const volume = typeof params.volume === "number" ? Math.min(1, Math.max(0, params.volume)) : 1;
        const owned = sounds.get(owner) ?? new Set<() => void>();
        if (owned.size >= MAX_PLAYING) throw new Failure("failed", `at most ${MAX_PLAYING} sounds play at once per kernel`);
        sounds.set(owner, owned);
        const url = env.URL!.createObjectURL(new Blob([bytes as BlobPart]));
        const audio = new env.Audio!(url);
        audio.volume = volume;
        let done = false;
        let released = false;
        const stop = () => {
          if (done) return;
          done = true;
          audio.pause();
          env.URL!.revokeObjectURL(url);
          owned.delete(release);
        };
        const release = () => {
          released = true;
          stop();
        };
        owned.add(release);
        audio.addEventListener("ended", stop);
        audio.addEventListener("error", stop);
        try {
          try {
            await audio.play();
          } catch (err) {
            // Autoplay needs a click on the page first.
            if ((err as { name?: unknown })?.name !== "NotAllowedError") throw err;
            await needClick(method, "Play sound", signal, () => audio.play());
          }
          // Cancelled or released while it started: it doesn't play on.
          if (signal.aborted || released) {
            stop();
            throw new Failure("cancelled", `${method} was cancelled`);
          }
        } catch (err) {
          stop();
          throw err;
        }
        return null;
      }
    }
    throw new Failure("unavailable", `${method} isn't available in this browser`);
  };

  return async (message) => {
    if (message.cancel === true) {
      if (typeof message.id === "number") inFlight.get(message.id)?.abort();
      return { result: null };
    }
    const owner = typeof message.owner === "number" ? message.owner : 0;
    if (message.release === true) {
      stopSounds(owner);
      return { result: null };
    }
    const method = message.method;
    if (method === "hello") {
      stopSounds(owner);
      return { result: { platform: "browser", appVersion: "", capabilities } };
    }
    if (typeof method !== "string") return error("failed", "a device call needs a method");
    const params = isRecord(message.params) ? message.params : {};
    const id = typeof message.id === "number" ? message.id : undefined;
    const controller = new AbortController();
    if (id !== undefined) inFlight.set(id, controller);
    try {
      return { result: await call(method, params, controller.signal, owner) } satisfies Reply;
    } catch (err) {
      if (controller.signal.aborted) return error("cancelled", `${method} was cancelled`);
      if (err instanceof Failure) return error(err.code, err.message);
      const e = err as { name?: unknown; message?: unknown; code?: unknown };
      const text = typeof e?.message === "string" ? e.message : String(err);
      if (e?.name === "AbortError") return error("cancelled", text);
      if (e?.name === "NotAllowedError") return error("denied", text);
      if (typeof e?.code === "string") return error(e.code, text);
      return error("failed", text);
    } finally {
      if (id !== undefined && inFlight.get(id) === controller) inFlight.delete(id);
    }
  };
}

/** The remote subset this browser can answer: what its APIs have, and with `canClick`, those that need a click. */
export function browserCapabilities(env: BrowserEnv = globalThis as unknown as BrowserEnv, canClick = true): string[] {
  const clip = env.navigator?.clipboard;
  const doc = env.document !== undefined;
  // Whether the browser has each method; which need a click is
  // `browserClick` in the support table.
  const has: Record<string, boolean> = {
    info: true,
    "clipboard.readText": typeof clip?.readText === "function",
    "clipboard.writeText": typeof clip?.writeText === "function",
    "clipboard.readImage": typeof clip?.read === "function",
    "clipboard.writeImage": typeof clip?.write === "function" && typeof env.ClipboardItem === "function",
    openURL: typeof env.open === "function",
    share: typeof env.navigator?.share === "function",
    "files.pick": doc,
    "photos.pick": doc,
    "files.export": doc && env.URL !== undefined,
    "sound.play": typeof env.Audio === "function" && env.URL !== undefined,
  };
  const rows: Record<string, SupportRow> = SUPPORT;
  return Object.entries(has)
    .filter(([method, present]) => REMOTE_METHODS.has(method) && present && (canClick || rows[method]?.browserClick !== true))
    .map(([method]) => method);
}

/** Shows a file input and resolves with what the person picks, `[]` when they cancel. */
function pickFiles(env: BrowserEnv, accept: string, multiple: boolean, signal: AbortSignal): Promise<File[]> {
  return new Promise((resolve, reject) => {
    const input = env.document!.createElement("input");
    input.type = "file";
    if (accept) input.accept = accept;
    input.multiple = multiple;
    input.addEventListener("change", () => resolve(Array.from(input.files ?? [])), { once: true });
    input.addEventListener("cancel", () => resolve([]), { once: true });
    signal.addEventListener("abort", () => reject(new Failure("cancelled", "the pick was cancelled")), { once: true });
    input.click();
  });
}

function download(env: BrowserEnv, name: string, bytes: Uint8Array): void {
  const url = env.URL!.createObjectURL(new Blob([bytes as BlobPart]));
  const link = env.document!.createElement("a");
  link.href = url;
  link.download = name;
  link.style.display = "none";
  env.document!.body.append(link);
  link.click();
  link.remove();
  // After the browser has taken the download.
  setTimeout(() => env.URL!.revokeObjectURL(url), 60_000);
}

/** `files.pick` types as an `accept` attribute: MIME types, wildcards and extensions; type identifiers can't be said there. */
function acceptOf(types: unknown): string {
  if (!Array.isArray(types)) return "";
  const kept = types.filter((t): t is string => typeof t === "string" && (t.startsWith(".") || t.includes("/")));
  // `application/*` allows any file, as on the device.
  if (kept.includes("application/*") || kept.length < types.length) return "";
  return kept.join(",");
}

function toFile(value: unknown, index: number): File {
  if (!isRecord(value)) throw new Failure("failed", "each shared file is { name, data }");
  const name = typeof value.name === "string" && plainName(value.name) ? value.name : `file${index + 1}`;
  return new File([bytesOf(value.data, "data") as BlobPart], name);
}

function bytesOf(value: unknown, key: string): Uint8Array {
  if (value instanceof Uint8Array) return value;
  if (isRecord(value) && typeof value.base64 === "string") return decodeBase64(value.base64);
  throw new Failure("failed", `${key} must be bytes`);
}

function binary(bytes: Uint8Array): { base64: string } {
  checkTotal([bytes.byteLength]);
  return { base64: encodeBase64(bytes) };
}

function checkTotal(sizes: number[]): void {
  if (sizes.reduce((a, b) => a + b, 0) > MAX_BINARY_BYTES) throw new Failure("failed", "over the 16 MiB limit for one call");
}

function isPng(bytes: Uint8Array): boolean {
  const magic = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];
  return bytes.length >= 8 && magic.every((b, i) => bytes[i] === b);
}

/** Sounds one kernel may have playing at once, as on the device. */
const MAX_PLAYING = 32;

function plainName(name: string): boolean {
  return name.trim() !== "" && name !== "." && name !== ".." && !/[/\\\0]/.test(name);
}

function need(params: Params, key: string): string {
  const value = params[key];
  if (typeof value !== "string") throw new Failure("failed", `${key} must be a string`);
  return value;
}

function error(code: string, message: string): { error: { code: string; message: string } } {
  return { error: { code, message } };
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
