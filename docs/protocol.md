# The device protocol

What the native host answers, and how a request reaches it. The TypeScript
side is in `src/`; the Swift side (`DeviceBridge`) implements this page.

## The path today (Worker kernel in a WKWebView)

```
cell ── device.clipboard.readText()
  │  src/device.ts → DeviceTransport.call("clipboard.readText", {})
  ▼
Worker: preload's transport → cdp-kernel host.request (#384)
  │  postMessage { kind: "host", id, method, params }
  ▼
page: cdp-kernel BrowserTarget → host handler = webkitHost() (src/webkit.ts)
  │  window.webkit.messageHandlers.device.postMessage({ id, method, params })
  ▼
Swift: WKScriptMessageHandlerWithReply named "device"
  │  replies { result } or { error: { code, message } }
  ▲  (back the same way)
```

The `id` in the WebKit message is the page's, unique per page load. It is
what a cancel refers to.

## Messages Swift receives

| Message | Meaning | Reply |
| --- | --- | --- |
| `{ id, method, params }` | A call. `params` is a JSON object. | `{ result }` or `{ error: { code, message } }` |
| `{ id, cancel: true }` | The call `id` was aborted: an interrupt, an `AbortSignal`, or the Worker stopped. Dismiss any sheet or picker it showed. | Anything; ignored |

Rules for the Swift handler:

- Always reply with the object, never with WebKit's error string, so the
  `code` survives. Use the error string only for a bug in the bridge.
- `code` is one of `unavailable`, `denied`, `cancelled`, `timeout`,
  `failed`, `disconnected` (`src/errors.ts`). A person dismissing a picker
  or dialog is not an error: reply `{ result: null }`.
- After a cancel, a late result for that `id` is dropped by the page, so
  Swift needn't track whether it already answered.
- Values are what `WKScriptMessage.body` carries: strings, numbers,
  booleans, null, arrays and dictionaries. There is no `ArrayBuffer`
  across this hop, so binary methods (Phase 1) carry base64 in
  `{ base64 }` fields and the TypeScript side converts.
- Register the handler only in the WebView that runs the kernel, never in
  one that renders notebook outputs (PLAN.md, "Design rule").

## Methods

| Method | Params | Result |
| --- | --- | --- |
| `hello` | `{}` | `{ platform, appVersion, model?, osVersion?, capabilities: string[] }`, where `capabilities` lists the methods below this host answers |
| `clipboard.readText` | `{}` | the text, or `null` when the clipboard holds none |
| `clipboard.writeText` | `{ text }` | `null` |

`hello` is called once per Worker start, before the first cell. A method
missing from `capabilities` is never sent: the TypeScript side rejects it
as `unavailable` itself.

Support for each method across on-device, remote and browser kernels is
in `src/support.ts`.
