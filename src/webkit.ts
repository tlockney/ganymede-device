// The page's side inside the Mac and iPad apps: a `host` handler for
// cdp-kernel's startBrowserKernel that sends each request to the Swift
// DeviceBridge through `window.webkit.messageHandlers.device`, a
// WKScriptMessageHandlerWithReply. The wire format is in docs/protocol.md.

/** What startBrowserKernel's `host` option takes (cdp-kernel's HostHandler). */
export type HostHandler = (request: { method: string; params: unknown }, signal: AbortSignal) => Promise<unknown>;

/** The part of WebKit's message handler this uses: postMessage resolves with Swift's reply. */
export interface MessageHandler {
  postMessage(message: unknown): Promise<unknown>;
}

declare global {
  // In a WKWebView with the handler registered (WKUserContentController).
  var webkit: { messageHandlers: Record<string, MessageHandler | undefined> } | undefined;
}

export interface WebKitHostOptions {
  /** The registered handler's name; "device" by default. */
  name?: string;
}

/** The handler, or null outside a WKWebView that registered it. */
export function findMessageHandler(name = "device"): MessageHandler | null {
  return globalThis.webkit?.messageHandlers?.[name] ?? null;
}

/**
 * A host handler backed by the Swift bridge. Swift replies `{ result }` or
 * `{ error: { code, message } }`; an error becomes a thrown DeviceError
 * shape, which cdp-kernel carries to the Worker by name, message and code.
 * Aborting sends `{ id, cancel: true }` so Swift can dismiss what it showed.
 */
export function webkitHost(options: WebKitHostOptions = {}): HostHandler {
  const name = options.name ?? "device";
  let nextId = 0;
  return async ({ method, params }, signal) => {
    const handler = findMessageHandler(name);
    if (!handler) throw deviceError("unavailable", "this page isn't in the app (no WebKit device handler)");
    const id = ++nextId;
    const onAbort = () => void handler.postMessage({ id, cancel: true }).catch(() => {});
    signal.addEventListener("abort", onAbort, { once: true });
    try {
      const reply = await handler.postMessage({ id, method, params: params ?? {} });
      if (isRecord(reply) && isRecord(reply.error)) {
        throw deviceError(String(reply.error.code ?? "failed"), String(reply.error.message ?? `${method} failed`));
      }
      return isRecord(reply) ? reply.result : undefined;
    } finally {
      signal.removeEventListener("abort", onAbort);
    }
  };
}

function deviceError(code: string, message: string): Error {
  return Object.assign(new Error(message), { name: "DeviceError", code });
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
