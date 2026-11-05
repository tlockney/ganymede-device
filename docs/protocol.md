# The device protocol

What the native host answers, and how a request reaches it. The TypeScript
side is in `src/`; the Swift side (`DeviceBridge`, in
`swift/Sources/DeviceBridge/`) implements this page.

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

The `id` in the WebKit message is the page's, unique per page load across
every kernel the page runs (one counter for all `webkitHost()` handlers).
It is what a cancel refers to.

There is no kernel generation (`gen`) in the message. A restart or
shutdown stops the kernel's Worker, and cdp-kernel aborts each call that
Worker had in flight, so Swift gets `{ id, cancel: true }` for each one;
the restarted kernel's calls take new ids.

A page reload or a restarted web content process sends no cancels, and
the new page's ids start over. So when the kernel web view navigates or
its content process terminates, Swift drops every call it still has
open (dismissing what it showed) before taking calls from the new page.
Today's bridge answers each call synchronously, so it holds none.

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
  across this hop, so bytes travel as `{ base64 }` objects (below).
- Register the handler only in the WebView that runs the kernel, never in
  one that renders notebook outputs (docs/plan.md, "Design rule").

## Binary values

Bytes cross the WebKit hop as an object whose only key is `base64`, a
standard base64 string with padding: `{ "base64": "iVBORw0KGgo=" }`.

- `webkitHost()` (src/binary.ts) turns every `Uint8Array`, `ArrayBuffer`,
  other typed array and `Blob` in `params` into one before posting, and
  every `{ base64 }` object in `result` into a `Uint8Array`. An object
  with `base64` and any other key is left alone.
- Swift reads one with `DeviceBridge.bytes(_:)` and writes one with
  `DeviceBridge.binary(_:)`.
- One value is at most 16 MiB (`MAX_BINARY_BYTES`,
  `DeviceBridge.maxBinaryBytes`), either way. Above it the side that
  holds the bytes fails the call `failed`, before sending them.
- Inside the kernel, bytes are `Uint8Array`s; the Worker's postMessage
  copies them. Cells' own buffers are not transferred, so a cell can keep
  using what it passed.

## Methods

| Method | Params | Result |
| --- | --- | --- |
| `hello` | `{}` | `{ platform, appVersion, model?, osVersion?, capabilities: string[] }`, where `capabilities` lists the methods below this host answers. Haptics are listed only on an iPhone: iPads and Macs have no Taptic Engine |
| `clipboard.readText` | `{}` | the text, or `null` when the clipboard holds none |
| `clipboard.writeText` | `{ text }` | `null` |
| `clipboard.readImage` | `{}` | the clipboard's image as PNG bytes, or `null` when it holds none |
| `clipboard.writeImage` | `{ image }`: PNG, JPEG, GIF, HEIC or TIFF bytes | `null`; bytes that aren't an image fail `failed` |
| `info` | `{}` | `{ isPad, screen?: { width, height, scale }, battery?: { level, charging }, darkMode, locale }`, read when called; `battery` is left out without one, and `level` (0 to 1) is `null` when unknown |
| `haptics.impact` | `{ style }`: `light`, `medium`, `heavy`, `soft` or `rigid` | `null` |
| `haptics.notification` | `{ type }`: `success`, `warning` or `error` | `null` |
| `haptics.selection` | `{}` | `null` |
| `openURL` | `{ url, inApp }` | `null`; only `http`, `https` and `mailto` URLs, anything else fails `failed`. `inApp` shows a web page in a Safari view on iOS and iPadOS |

`hello` is called once per Worker start, before the first cell. A method
missing from `capabilities` is never sent: the TypeScript side rejects it
as `unavailable` itself.

Support for each method across on-device, remote and browser kernels is
in `src/support.ts`: shipped (`yes`), `planned`, or `no`. Its
`supportTable()` renders the table in ganymede-ui's `docs/device.md`.
