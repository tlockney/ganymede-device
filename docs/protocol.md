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
It is what a cancel refers to. The `owner` names the kernel: each
`webkitHost()` handler, one per kernel, takes its own, also unique per page
load. Swift keeps sound players and playing sounds under their owner.

There is no kernel generation (`gen`) in the message. A restart or
shutdown stops the kernel's Worker, and cdp-kernel aborts each call that
Worker had in flight, so Swift gets `{ id, cancel: true }` for each one;
the restarted kernel's calls take new ids.

A page reload or a restarted web content process sends no cancels, and
the new page's ids start over. So when the kernel web view navigates or
its content process terminates, Swift drops every call it still has
open (dismissing what it showed) before taking calls from the new page.
Only dialogs and sounds stay open; the app calls `DeviceBridge.dropPage()`
from the kernel web view's navigation delegate, which closes that page's
dialogs and answers each `cancelled`, and stops its sounds and closes its
players. The remote handler's calls (below) are the UI page's, so they
stay; the app calls `dropRemote()` when the UI page navigates or its
process ends, and `dropAll()` drops both.
A kernel restart or shutdown closes that kernel's players and stops its
sounds, and no other kernel's. A restart starts a new Worker, whose
preload calls `hello`; a `hello` from an owner closes what that owner
opened before. A shutdown sends no `hello`, so the page calls the
handler's `release()`, which sends `{ owner, release: true }`. A message
with no `owner` (a page from before owners) counts as owner 0, whose
`hello` closes nothing.

## Messages Swift receives

| Message | Meaning | Reply |
| --- | --- | --- |
| `{ id, owner, method, params }` | A call from kernel `owner`. `params` is a JSON object. | `{ result }` or `{ error: { code, message } }` |
| `{ id, cancel: true }` | The call `id` was aborted: an interrupt, an `AbortSignal`, or the Worker stopped. Dismiss any sheet or picker it showed, and close the player a `sound.player` call opened (the page drops its answer, so it has no id to close). | Anything; ignored |
| `{ owner, release: true }` | Kernel `owner` shut down. Stop its sounds and close its players. | Anything; ignored |

Rules for the Swift handler:

- Always reply with the object, never with WebKit's error string, so the
  `code` survives. Use the error string only for a bug in the bridge.
- `code` is one of `unavailable`, `denied`, `cancelled`, `timeout`,
  `failed`, `disconnected` (`src/errors.ts`). A person dismissing a picker
  or dialog is not an error: reply with the method's dismissed result,
  `null` unless its row below says otherwise (`[]` for a picker, `false`
  for a confirm or an export).
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
| `share` | `{ text?, url?, files: [{ name, data }] }`, at least one of the three; `url` is http, https or mailto; files together at most 16 MiB | `true` when the person picked where to send them (iOS: once the share completes; Mac: once a service is picked, since the Mac can't tell more), `false` when dismissed. Shown through the dialog queue |
| `preview` | `{ files: [{ name, data }] }`, at least one; together at most 16 MiB | `null` once Quick Look closes. Shown through the dialog queue |
| `files.pick` | `{ types?: string[], multiple?: boolean }`; types are MIME types, wildcards (`image/*`, `audio/*`, `video/*`, `text/*`, `font/*`, `model/*`, `message/*`, `application/*`, which allows any file), type identifiers such as `public.json`, or extensions such as `.csv` | `[{ name, type, data }]`, `[]` when cancelled; together at most 16 MiB, or it fails `failed`. Shown through the dialog queue |
| `files.export` | `{ name, data }`, a plain file name | `true` when saved, `false` when cancelled. Shown through the dialog queue |
| `photos.pick` | `{ limit?: number }`, 1 by default, 0 for no limit | `[{ name, type, data }]` images in their stored format, `[]` when cancelled; together at most 16 MiB. Shown through the dialog queue |
| `sound.play` | `{ data, volume? }`, volume 0 to 1 | `null` once it starts; it plays to its end; at most 32 playing per kernel (one an audio interruption paused no longer counts) |
| `sound.player` | `{ data }` | `{ player, duration }`: an id, paused at the start; at most 32 open per kernel; `sound.control` and `sound.close` reach only the calling kernel's players |
| `sound.control` | `{ player, action?, time?, volume? }`; action `play`, `pause`, `stop`, `seek` (to `time` seconds) or `state` (the default) | `{ playing, time, duration }` after the change; a bad `action` or `time` fails `failed` and changes nothing, and `play` fails `failed` when the sound can't start |
| `sound.close` | `{ player }` | `null`; closing one already closed is fine |

`hello` is called once per Worker start, before the first cell. A method
missing from `capabilities` is never sent: the TypeScript side rejects it
as `unavailable` itself.

Support for each method across on-device, remote and browser kernels is
in `src/support.ts`: shipped (`yes`), `planned`, or `no`. Its
`supportTable()` renders the table in ganymede-ui's `docs/device.md`.

## Dialogs

`ui.*`, `share`, `preview`, `files.*` and `photos.pick` calls wait on a person, so Swift answers
them when the dialog closes, not when the message arrives (`DeviceBridge.respond(to:reply:)`).
Each shows on the window of the web view that sent the call, the notebook
whose cell asked, or on the key window when that isn't known. The Mac
shows a sheet; iPhone and iPad show an alert, an action sheet (a popover
with no arrow on an iPad) or a date picker sheet over that window's top
view controller.

- One dialog at a time per bridge. A second call waits for the first to
  close, in the order the calls came, rather than failing: a cell that
  asks twice in a row gets both.
- A cancel for the dialog showing closes it and answers `cancelled`; a
  cancel for one still waiting takes it off the queue. Either way the
  next waiting dialog shows, once the closed one has left the screen.
- An aborted `signal` sends the cancel. A `signal` from
  `AbortSignal.timeout()` rejects `timeout` instead of `cancelled`.
- With no window to show it on, the call fails `unavailable`.
- `share` and `preview` write their files to a fresh folder under the
  app's temporary directory, each file in a folder of its own so names
  can repeat. Quick Look's are removed when it closes; a share's ten
  minutes later, since the app it went to may read the URL after the
  sheet has gone. A file name must be plain: no slash, backslash or NUL,
  and not `.` or `..`.
- Pickers are the person's consent, so there is no permission prompt.
  A picked file is read in by value and the app keeps no access to it:
  the Mac's open panel, the iOS document picker (copying in) and the
  photo picker (which doesn't let the app into the library). The Mac
  open and save panels need the app's
  `com.apple.security.files.user-selected.read-write` entitlement; the
  photo picker shows on the window's content view controller.
- The Mac's share menu can't be closed from code: a cancel answers
  `cancelled` at once and the menu stays until the person closes it.
- A kernel interrupt closes the dialog: cdp-kernel 0.7.2 or later
  aborts the cell's open host requests, which sends the cancel.

## Over a Jupyter comm (remote kernels)

Both ends are in this package: the kernel's, `connectDevice` in
`src/comm.ts` (`@tlockney/ganymede-device/remote`), and the app's,
`answerDevice` in `src/frontend.ts` (`@tlockney/ganymede-device/frontend`),
which the notebook page runs for each kernel connection and which posts
to the bridge's remote handler (below).

A kernel that isn't in the app, such as cdp-kernel on Node behind
Ganymede, reaches the app through the notebook page that shows it:

```ts
import { connectDevice } from "@tlockney/ganymede-device/remote";
const device = await connectDevice(jupyter.comm);
```

The kernel doesn't open a comm that carries calls, because a
kernel-opened comm goes to every client on the kernel and JupyterLab
closes one whose target it doesn't know, for everyone. Instead:

1. The kernel registers target `ganymede.device.v1.calls` and opens a
   comm to target `ganymede.device.v1` with `{ protocol: 1 }`: the
   announce. It comes from a cell, so its parent header carries that
   `execute_request`'s session.
2. The app answers only an announce whose session is its own: it opens a
   comm to `ganymede.device.v1.calls` whose open data is its `hello`
   reply. No other client knows that comm.
3. The kernel takes the first such comm, closes the announce, and turns
   away any other with `comm_close` `{ error: "taken" }` (`"not waiting"`
   for one that comes after the announce timed out). With no answer
   in 5 s, every call rejects `unavailable`.

Over the calls comm, the kernel sends `{ id, method, params }` and
`{ id, cancel: true }`, and the app replies `{ id, result }` or
`{ id, error: { code, message } }`: the messages Swift receives, with
binary values as `{ base64 }` as on the WebKit hop, so the app forwards
them to `DeviceBridge` unchanged. An abort rejects at once and sends the
cancel; a late reply is dropped. When the calls comm closes, calls in
flight reject `disconnected` and the next call announces again (it
rejects `disconnected` if no app answers, and calls in the next 10 s
reject at once rather than announce again).

A frontend that is killed or suspended sends no `comm_close`, so while
calls are in flight the kernel sends `{ ping: n }` every 5 s and the app
answers `{ pong: n }`. A comm that has sent nothing for two pings is
dropped as if closed. A kernel connects once per `jupyter.comm`:
`connectDevice` from a later cell reuses the link and its target.

A cell awaits the app's answer, so the kernel must read comm messages
while a cell runs: cdp-kernel 0.8.0 and later do, for comm messages a
frontend sends on a kernel subshell (JEP 91). `@jupyterlab/services`
does that by default once the kernel lists `kernel subshells`
(`commsOverSubshells`, per comm target). On an older kernel, or a
frontend that sends comms on the main shell, `connectDevice` awaited in
a cell resolves after `timeoutMs` to a device whose calls reject
`unavailable`
(tlockney/cdp-kernel#417). An interrupt doesn't cancel a call by itself;
pass `{ signal: jupyter.signal }` (cdp-kernel 0.8.0), which an interrupt
aborts, or a signal of your own.

The kernel offers only the remote subset: methods whose `remote` column
in `src/support.ts` isn't `no`, whatever the app's `hello` lists. The
app enforces the same subset on its side.

### The app's side

`answerDevice(kernel, { forward })` takes a `@jupyterlab/services`
kernel connection (`clientId`, `registerCommTarget`, `createComm`,
`statusChanged`) and a `forward` function that sends one message to the
native host and resolves with its reply. The default, `webkitForward()`,
posts to `webkit.messageHandlers.deviceRemote`.

- It registers `ganymede.device.v1` and answers an announce only when the
  announce's parent header `session` is the connection's `clientId`: a
  cell this page ran. Another client on the same kernel, such as a
  JupyterLab tab, never answers for it.
- It asks the host for `hello` and opens the calls comm with it, cut to
  the remote subset. The cell that announced is waiting, so the open
  waits for the comm's subshell (`subshellStarted`, up to 3 s, under
  the kernel's 5 s timeout) rather than go on the main shell behind that
  cell; with no subshell by then it gives up. The comm target and the
  calls comm's `onMsg` return nothing, since `@jupyterlab/services`
  holds later kernel messages (the subshell's reply, pings, cancels)
  while either's promise is pending.
- It answers `{ ping }` with `{ pong }` itself, and forwards each call
  and cancel. A call outside the remote subset fails `unavailable`
  without reaching the host. Each forwarded call gets a page-wide `id`,
  and each `answerDevice` an `owner`, as `webkitHost()` does.
- When the calls comm closes, the kernel restarts (`statusChanged`
  `restarting`, `autorestarting` or `dead`) or the page calls
  `dispose()`, it cancels what it forwarded; `dispose()` also releases
  its owner.
- `accept()`, when given, is asked on each announce; false turns the
  kernel away, for a per-server mute.

The Swift side is `DeviceBridge.registerRemote(in:allow:)`, a second
handler named `deviceRemote` on the notebook page's web view. That page
renders outputs too, so the handler differs from `device`:

- It takes main-frame messages only, and only those `allow` passes (the
  app checks the page's origin).
- It answers only `DeviceBridge.remoteMethods`, the rows of
  `src/support.ts` whose remote column isn't `no` (a test checks the two
  lists agree), and its `hello` lists only those.
- Its ids and owners are kept apart from the kernel page's, so a cancel
  or release from one page never touches the other's calls. Dialogs from
  both share one queue: one dialog at a time.

