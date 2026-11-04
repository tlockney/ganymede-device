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
Only dialogs stay open; the app calls `DeviceBridge.dropAll()` from the
web view's navigation delegate, which closes them and answers each
`cancelled`.

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
| `ui.alert` | `{ message, title? }` | `null` once closed |
| `ui.confirm` | `{ message, title?, destructive, okLabel? }` | `true` when confirmed, `false` when cancelled |
| `ui.prompt` | `{ message, title?, placeholder?, defaultValue?, secure }` | the text, or `null` when cancelled |
| `ui.actionSheet` | `{ title, options: string[], message?, cancel?, destructive?: index }` | the chosen option's index, or `null` when cancelled |
| `ui.pickDate` | `{ mode: "date" \| "time" \| "datetime", title?, value?, min?, max? }`, dates as ISO 8601 strings | the date as an ISO 8601 string, or `null` when cancelled |

`hello` is called once per Worker start, before the first cell. A method
missing from `capabilities` is never sent: the TypeScript side rejects it
as `unavailable` itself.

Support for each method across on-device, remote and browser kernels is
in `src/support.ts`.

## Dialogs

`ui.*` calls wait on a person, so Swift answers them when the dialog
closes, not when the message arrives (`DeviceBridge.respond(to:reply:)`).
The Mac shows each as a sheet on the key window; iPhone and iPad show an
alert, an action sheet (a popover with no arrow on an iPad) or a date
picker sheet over the key window's top view controller.

- One dialog at a time per bridge. A second call waits for the first to
  close, in the order the calls came, rather than failing: a cell that
  asks twice in a row gets both.
- A cancel for the dialog showing closes it and answers `cancelled`; a
  cancel for one still waiting takes it off the queue. Either way the
  next waiting dialog shows, once the closed one has left the screen.
- An aborted `signal` sends the cancel. A `signal` from
  `AbortSignal.timeout()` rejects `timeout` instead of `cancelled`.
- With no window to show it on, the call fails `unavailable`.
- A kernel interrupt closes the dialog: cdp-kernel 0.7.2 or later
  aborts the cell's open host requests, which sends the cancel.
