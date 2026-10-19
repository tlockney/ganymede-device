# A `device` API for TypeScript notebooks in the Mac and iPad apps

Goal: give notebook code in the Mac and iPad apps something in the spirit of
Juno's `juno` Python module: calls from a cell into the native app for
files, clipboard, sharing, notifications, location, photos and similar. Not
a copy of Juno's API; the same direction.

Scope (Thomas, 2026-10-18): the **on-device kernel** is the target and
gets the full API. A remote kernel (Ganymede on the Mac mini) driven
from the app gets the **features that need no permission** through the
same API (Thomas, 2026-10-18); see "Remote kernels". A browser frontend
gets a few of those through web APIs where they fit; see "Browser
fallback". Every feature's support in each case is documented in one
matrix; see "Documentation".

Sources: Juno's module docs (juno.sh/docs/python/juno/ and its 17
module pages, read 2026-10-18) and the existing design in
`research/ts-on-ipados/source/design-note.md` §08. The table under
"What Juno has" maps each Juno module to ours.

## The bridge: kernel straight to Swift

Like Juno, the kernel runs inside the app, so `device` calls go straight
from the kernel's runtime to the native host. No Jupyter comms, no
frontend plugin, and Ganymede is not involved.

The kernel-side `device` object talks to one small interface, and each
on-device placement supplies it:

```ts
interface DeviceTransport {
  call(method: string, params: JsonObject, buffers?: Uint8Array[], signal?: AbortSignal): Promise<Reply>;
  stream(method: string, params: JsonObject, signal?: AbortSignal): AsyncIterable<Reply>;
  on(event: string, handler: (value: unknown) => void): () => void;
}
```

| Kernel placement | Where it applies | Transport |
| --- | --- | --- |
| Worker kernel in a WKWebView (cdp-kernel#314) | Mac and iPad, first | Worker `postMessage` → page → `webkit.messageHandlers.device` (`WKScriptMessageHandlerWithReply`) → Swift |
| Embedded engine (JSC prototype, then rusty_v8 jitless; ts-on-ipados tier 2) | iPad, later | A host function installed in the isolate (JSExport or a Rust op) → Swift |
| Child process of the bundled Ganymede (cdp-kernel on Node/Deno) | Mac, only if the Mac app runs its local kernel that way | Unix socket the app passes in an env var; JSON lines plus length-prefixed binary |

```
cell code ── device.clipboard.readText() ──▶ device object (in the cell's realm)
   │  DeviceTransport.call("clipboard.readText", {})
   ▼
placement-specific hop (Worker postMessage / host function / Unix socket)
   ▼
Swift DeviceBridge ──▶ UIPasteboard / CoreLocation / PhotosUI / UNUserNotificationCenter …
```

Why this route:

- It matches Juno: the code asking and the person holding the device are
  on the same machine, so there is no "which frontend answers" problem.
- It works with no notebook UI attached, so share-sheet actions,
  Shortcuts and widgets (ts-on-ipados tier 3) get the API for free.
- Ganymede and the Jupyter protocol stay untouched.

Availability: the host installs `device` only when it has a transport. On
any other kernel `globalThis.device` is undefined, and importing the
module gives an object whose calls reject with `unavailable`. A
`capabilities.device` entry in `kernel_info_reply` lets the UI show it.

### Design rule: notebook outputs must not reach the bridge

In the Worker placement, the kernel and the notebook's rendered outputs
could share one WKWebView. An HTML output with a script could then call
`webkit.messageHandlers.device` directly and skip the permission checks.
Options, in order of preference:

1. Run the Worker kernel in a **hidden kernel WKWebView** that renders no
   outputs; Swift relays Jupyter messages between it and the UI WebView.
   Only the kernel WebView registers the `device` handler. This also
   keeps a busy UI from stalling the kernel.
2. Register the handler in a separate `WKContentWorld` and render outputs
   in sandboxed iframes.

Phase 0 checks that option 1 is cheap enough.

## Remote kernels: a subset over Jupyter comms

Rule: **remote support never shapes the on-device design.** The API is
designed for the on-device kernel first: `device` is a global with no
import, installed before the first cell with no handshake wait;
`device.info()` and `has()` answer from a cache filled at install; streams,
long-lived handles, host events and headless runs are all available. The
remote transport is a filtered view of that API. If a feature can't work
well remotely, it is left out of the subset, not weakened for everyone.

When the app is the frontend for a kernel on another machine (the iPad on
Ganymede at the Mac mini), the same `device` API can work through a
second transport. The kernel has no line to the device's Swift host, but
the app's UI does, and Jupyter comms already connect the two.

```
cell on the Mac mini ── device.clipboard.readText()
   │  CommTransport: jupyter.comm, target "ganymede.device.v1"
   ▼
Ganymede (passes comms through untouched)
   │  websocket over the tailnet
   ▼
ganymede-ui in the app ── device-bridge plugin ── Swift DeviceBridge
```

How the kernel side finds it: if the host installed a transport, use it.
Otherwise open the comm and send `hello`; if the app answers within ~2 s,
use `CommTransport`, else every call rejects `unavailable`. Same message
format as the on-device transports, carried in comm data and buffers.

### What changes when the kernel is remote

- **Which frontend answers.** A comm open goes to every connected client.
  `hello` carries the Jupyter session of the cell's `execute_request`, and
  only the app window with that session answers. A JupyterLab tab on the
  same kernel stays silent.
- **Data leaves the device.** A clipboard read or picked file lands on
  the Mac mini. That is why remote stops at features that need no
  permission: each one is either an action the person sees and confirms
  (pickers, share, dialogs, the system paste prompt) or sends nothing
  back (haptics, sound, clipboard write). No ledger entries for remote
  hosts, and a remote host can never trigger a permission prompt.
- **Dialogs from a remote host.** Code on the server can still open
  dialogs and pickers on the iPad. The app shows which host asked, allows
  one at a time, and the person can mute a host for the session.
- **The link drops.** The iPad suspends the app and the websocket goes
  away while the kernel keeps running. Pending calls reject
  `disconnected`; streams end; native handles (sound players, BLE
  connections) close. After reattach, the comm is reopened on the next
  call. Long or stateful features are a poor fit for this.
- **Latency.** Each call is a tailnet round trip plus the UI hop. Fine for
  one-shot calls, poor for high-rate streams.
- **No headless runs.** There is no remote equivalent of a share-sheet or
  Shortcuts run; those stay on-device.
- **Interrupt.** `interrupt_request` aborts the cell's signals in the
  kernel, which sends `{ id, cancel }` over the comm; the app dismisses
  any picker it showed.
- **Getting the module.** A remote kernel is a plain Node or Deno
  cdp-kernel. The package is published to npm/jsr and imported
  (`import { device } from "npm:@ganymede/device"`), or Ganymede passes a
  preload when it launches kernels for the app.

### The remote subset

Decision (Thomas, 2026-10-18): remote kernels get only features that
need no permission.

| Feature | Remote | Why |
| --- | --- | --- |
| `info`, `has` | yes | small, read-only; reports the device, not the server |
| clipboard write | yes | sends nothing back |
| clipboard read (text, image) | yes | the system paste prompt is the consent |
| `ui.*` dialogs and pickers | yes | user-initiated; the reason a remote notebook wants this most |
| share, preview, openURL | yes | the person sees and confirms the action |
| files pick/export, photos pick | yes | pickers are consent; bytes go to the server, which is the point |
| haptics, `sound.play` | yes | fire-and-forget |
| notifications | no | needs notification permission |
| location, motion, camera, photos save | no | need permission |
| contacts, reminders, Bluetooth | no | need permission |
| secrets | no | Keychain items stay on the device |
| `sound.player`, Shortcuts run, host events | no in v1 | handles and events don't survive disconnects; Shortcuts suit on-device scripts |

Widening this later means revisiting the ledger (keyed by host) and
prompt rate limits; neither is built for v1.

## Browser fallback

Decision (Thomas, 2026-10-18): expose a few features through web APIs
where it makes sense. This covers a remote kernel driven from a browser
instead of the app: ganymede-ui as a PWA, and later JupyterLab through a
small labextension. The same `ganymede.device.v1` comm target, answered
by a web implementation instead of Swift, and limited to the remote
subset's no-permission rule.

The catch is **user activation**. Clipboard, Web Share, file pickers,
`window.open` and audio need a recent click, and a message from the
kernel is not one. The web implementation therefore renders a small
inline prompt in the cell's output ("Copy to clipboard", "Choose file",
"Share") and runs the call on that click. Calls that don't need
activation run directly.

| Feature | Browser | Web API |
| --- | --- | --- |
| `info`, `has` | yes, partial | `navigator`, `screen`, `matchMedia("(prefers-color-scheme: dark)")`; no model or battery |
| clipboard write / read | yes, via click | Clipboard API (`writeText`, `write`, `read`) |
| share | yes, via click, where supported | Web Share API (`navigator.share`, `canShare` for files) |
| files pick | yes, via click | `<input type=file>`; File System Access where present |
| files export | yes | Blob download link |
| openURL | yes, via click | `window.open`; `inApp` ignored |
| `ui.alert`, `confirm`, `prompt`, `actionSheet`, `pickDate` | yes | rendered inline in the output, not `window.alert` |
| `sound.play` | yes, via click on first use | `HTMLAudioElement` |
| preview | yes | an inline `jupyter.display` of the file instead of QuickLook |
| photos pick | yes, via click | `<input type=file accept="image/*">` |
| haptics | no | `navigator.vibrate` isn't in Safari, and it's mostly a no-op elsewhere |
| everything needing permission | no | same rule as remote |

`has()` reports the browser's real support, so `share` with files is
false in a browser without `canShare({ files })`.


## What Juno has, and what we take from it

Juno ships 15 `juno.*` modules, each a thin Pythonic wrapper over one iOS
framework, plus two "use the standard library" answers (browser via
`webbrowser`, camera via OpenCV). Mapping to our namespaces:

| Juno | What it does | Ours | Phase |
| --- | --- | --- | --- |
| `device` | model, OS, `is_pad`, screen size/scale, battery, dark mode, locale; impact/notification/selection haptics | `device.info()`, `device.haptics.*` | 1 |
| `clipboard` | text get/set; image get/set (PNG/JPEG bytes) | `device.clipboard.{readText,writeText,readImage,writeImage}` | 1 |
| `dialogs` | alert, confirm (destructive), text input (secure option), action sheet, date / time / datetime pickers | `device.ui.*` | 1 |
| `sharing` | share sheet with text / url / file (path or bytes); returns completed or dismissed | `device.share()` | 1 |
| `preview` | QuickLook modal for files, bytes, images, figures; repeated calls append pages | `device.preview()` | 1 |
| `sound` | fire-and-forget `play(path)`; `Player` with play/pause/stop/seek/volume | `device.sound.{play,player}` | 1 |
| `photos` | `pick()` via PHPicker (no permission); `save()` to camera roll (add-only permission) | `device.photos.{pick,save}` | 1 / 2 |
| browser (`webbrowser`) | in-app web view or Safari | `device.openURL(url, { inApp })` | 1 |
| `notifications` | schedule after a delay, list pending, cancel one / all | `device.notifications.*` | 2 |
| `location` | one-shot fix, continuous updates, forward and reverse geocoding | `device.location.*` | 2 |
| `motion` | accelerometer, gravity, attitude, rotation rate; settable interval | `device.motion.watch()` | 2 |
| camera (OpenCV) | live frames as arrays | `device.camera.capture()`; frame streams later | 2 |
| `contacts` | search, get, get all, add, delete | `device.contacts.*` | 2 |
| `reminders` | calendars, list (by completion), add, complete/uncomplete, delete | `device.reminders.*` | 2 |
| `keychain` | get/set/delete by (service, account) | `device.secrets.*` | 3 |
| `bluetooth` | BLE central: scan, connect, services, characteristic read / write / notify, RSSI, reconnect by id | `device.bluetooth.*` | 3 |
| `objc` | raw Objective-C runtime access (rubicon) | none; see below | — |

Ours only (Juno doesn't need them because the kernel's filesystem is the
app's): `device.files.pick/export`, Shortcuts, host events, folder
bookmarks.

Not taking `objc` in v1. Raw runtime access is arbitrary native calls the
permission ledger can't reason about, and Juno's own docs warn that
callbacks from it hang or crash. Revisit later behind an explicit
per-notebook opt-in.

Design patterns worth copying from Juno:

- **Same permission trio on every permissioned module**:
  `authorizationStatus()`, `isAuthorized()`, `requestAuthorization()`,
  with status strings (including iOS partial grants such as limited
  contacts or write-only reminders). Calls that need permission request it
  lazily and fail with `denied`.
- **Stop interrupts every wait**: Juno turns its Stop button into
  `KeyboardInterrupt` during prompts, pickers and streams. Ours: kernel
  interrupt aborts the pending call's `AbortSignal` and the Swift side
  dismisses the prompt or picker.
- **Bounded streams with drop-oldest**: BLE advertisements (128) and
  notifications (1024) never stall the radio; iterators expose a `dropped`
  count. Same rule for our location, motion and BLE streams.
- **Explicit lifetimes for native resources**: BLE connections and audio
  players are context managers. Ours: handles implement
  `Symbol.asyncDispose` so `await using conn = await p.connect()` works,
  and the Swift side closes everything when the kernel restarts or exits.
- **Plain records**: dataclasses with every field optional on input
  (`Contact`, `Reminder`), so `add({ title: "Buy milk" })` works.
- **Narrow, honest scope**: each module documents what it doesn't wrap
  (no calendar triggers for notifications, no recurrence for reminders).
  Start equally narrow.

## API surface (TypeScript)

A `device` global, installed like `jupyter` by the on-device host, plus an
importable module for types. Everything is async; errors are typed.

```ts
/// <reference types="@ganymede/device" />

const info = await device.info();
// { platform: "ipados"|"macos", model, osVersion, isPad, screen: { width, height, scale },
//   battery, darkMode, locale, appVersion, capabilities: [...] }
if (!device.has("location")) { … }

// Phase 1: no system permission needed
await device.clipboard.writeText("hi");
const text = await device.clipboard.readText();
const png = await device.clipboard.readImage();            // Uint8Array | null
await device.haptics.impact("light");                      // no-op + has()=false on Mac
await device.openURL("https://deno.com", { inApp: true });
await device.share({ text, url, files: [blob] });          // share sheet / NSSharingServicePicker
await device.preview([figurePng, "report.pdf"]);           // QuickLook
const files = await device.files.pick({ types: ["public.json"], multiple: true });
await device.files.export(bytes, { name: "out.csv" });     // document picker / save panel
const photos = await device.photos.pick({ limit: 3 });     // PHPicker: no library permission
await device.sound.play("ding.m4a");
await using p = await device.sound.player(bytes); await p.play();

await device.ui.alert("Done");
if (await device.ui.confirm("Delete?", { destructive: true })) { … }
const name = await device.ui.prompt("Name?", { placeholder: "Alex", secure: false });
const i = await device.ui.actionSheet("Quality", ["Low", "High"], { cancel: "Cancel" });
const when = await device.ui.pickDate({ mode: "datetime", min, max });
// pickers and prompts return null on cancel instead of throwing

// Phase 2: system permission (TCC) behind it
await device.location.requestAuthorization();
const loc = await device.location.current({ accuracy: "city", signal });
for await (const p of device.location.watch({ signal })) { … }   // bounded stream
const [place] = await device.location.reverseGeocode(loc);
const id = await device.notifications.schedule("Drink water", { title, delay: 60 });
await device.notifications.cancel(id);
for await (const m of device.motion.watch({ interval: 0.1, signal })) { m.attitude.roll }
await device.photos.save(png);
const shot = await device.camera.capture();
const people = await device.contacts.search("alex");
await device.reminders.add({ title: "Buy milk", due: new Date(…) });

// Phase 3: app-level
const token = await device.secrets.get("github");   // Keychain, scoped per notebook
for await (const adv of device.bluetooth.scan({ services: [NUS], timeout: 10 })) { … }
await using conn = await adv.peripheral.connect();
await device.shortcuts.run("Log", { input: text }); // x-callback round trip
device.on("appearance", (mode) => …);               // events from the host
```

Conventions:

- Errors are `DeviceError` with `code`: `unavailable` (no transport, or
  not on this platform), `denied`, `cancelled` (interrupt or abort),
  `timeout`, `failed`, `disconnected` (BLE peer dropped mid-stream). A
  person dismissing a picker or dialog returns `null`/`false`, as in Juno,
  not an error.
- Binary data travels as transferable `ArrayBuffer`s (Worker), raw bytes
  (host function) or framed binary (socket), never base64 in JSON.
- Long-lived calls take an `AbortSignal`. Interrupt in the Worker
  placement terminates the Worker; the host tags every call with the
  kernel's generation id and cancels that generation's calls in Swift.
- `device.has(cap)` and `device.info().capabilities` come from a
  handshake at install time, so code can branch instead of catching.
- Display helpers can reuse `jupyter.display`: e.g. a picked photo is a
  `Blob` the cell can display directly.

Platform differences are data, not separate APIs: Macs have no haptics
(beyond trackpads), motion sensors or camera capture in v1, iPad has no
menu bar items; all report it through `has()`.

## Message format

Same JSON on every transport, so the Swift side has one dispatcher:

- Request: `{ id, gen, method, params }` plus buffers.
- Reply: `{ id, result }` or `{ id, error: { code, message } }`.
- Stream: `{ id, event, value }` until `{ id, end: true }`; cancel with
  `{ id, cancel: true }`.
- Host events: `{ event, value }` with no `id`.
- A `hello` at install returns platform, app version and capabilities.
- Methods are named `namespace.method` (`location.current`); additive
  changes only.

## Where the code lives

| Piece | Repo | Contents |
| --- | --- | --- |
| `@ganymede/device` (name TBD) | new package, or inside the app repo | The `device` object over a `DeviceTransport`, types, `DeviceError`, the Worker (and, if needed, socket) transports. Pure TS, no Node imports. |
| cdp-kernel | tlockney/cdp-kernel | Generic only: a **preload** hook (code a host installs in the cell realm before the first cell; none exists today), `capabilities` in `kernel_info_reply` (review.md item 4), and a way for the Worker driver (`runtime/browser-worker.mjs`) to pass non-kernel messages to its owner page. |
| Kernel host page | the app repo | The hidden kernel WebView's page: starts the Worker kernel, relays Jupyter messages to Swift, forwards `device` messages to the handler. |
| Swift `DeviceBridge` | the app repo (new; Thomas creates it) | The dispatcher, one handler type per capability, the permission ledger, macOS/iPadOS conditionals. Shared Swift package used by both apps. |
| `device-bridge` plugin (remote only) | tlockney/ganymede-ui | Registers the `ganymede.device.v1` comm target, matches the session, enforces the remote subset. Forwards to Swift inside the app; uses the web implementation in a browser. |
| Web implementation | `@ganymede/device` (shared with the plugin) | The browser-fallback handlers and the inline click-through prompts. Reused by a later JupyterLab labextension. |
| Support matrix | `@ganymede/device` | One table of every method × (on-device, remote in app, browser), the source for both `has()` defaults and the docs. |

For on-device kernels ganymede-ui needs nothing; it can show a badge from
`capabilities.device`. Ganymede's only part in the remote case is passing
comms and kernel metadata through verbatim, which docs/ipados.md already
requires.

Host shell: Swift + WKWebView on both platforms (SwiftUI multiplatform),
running ganymede-ui. No Tauri, no Rust UI.

## Permissions

On-device, the code asking runs on the device: one person, one machine.
Everything below applies to on-device kernels; remote kernels and browsers
never reach a permissioned feature.

1. **System (TCC)**: location, notifications, camera, contacts, reminders,
   Bluetooth are prompted by iOS and macOS the normal way. Info.plist
   usage strings name the feature, e.g. "A notebook asked for your
   location."
2. **App ledger** (from design-note §08), keyed by (notebook path,
   capability):
   - First use from a notebook shows an in-app prompt naming the
     notebook. Choices: once, always for this notebook, deny.
   - Notebooks may declare what they use in metadata
     (`metadata.ganymede.device: ["location"]`) so the prompt can come at
     open time instead of mid-cell.
   - Pickers (files, photos, share) are their own consent: the person
     chooses what to hand over, so no ledger prompt.
   - A Settings screen lists and revokes grants.
   - Headless runs (share sheet, Shortcuts) use grants already given;
     they can't show a prompt, so an ungranted call fails `denied`.

Files: picked files are copied in by value for v1. Persistent access
(security-scoped bookmarks to a folder) is Phase 3 and maps to Deno-style
`--allow-read` scopes.

App Review: calling native APIs from user-authored code is what Juno,
Pythonista and Scriptable do. Keep the API to user-initiated, documented
features, and keep Info.plist strings honest.

## Phases

**Phase 0: prove the path (days).**
A minimal Swift app (Mac first) with a hidden kernel WKWebView running the
Worker kernel, and one method (`clipboard.readText`) end to end from a
cell. Confirms the Worker → page → `WKScriptMessageHandlerWithReply` round
trip, that interrupt cancels pending calls, and that an HTML output in the
UI WebView cannot reach the handler.

**Phase 1: no-permission APIs.**
`info/has`, haptics, clipboard (text and image), openURL, share, preview,
files pick/export, photos pick, sound, ui (alert, confirm, prompt, action
sheet, date/time pickers).
Ship the TS package, the cdp-kernel preload hook, the Swift package.
Tests: TS unit tests against a fake transport; a Playwright test of the
Worker transport with a stubbed `webkit.messageHandlers`; XCTest for
Swift handlers.

**Phase 2: permissioned APIs and the ledger.**
The authorization trio; notifications (schedule, pending, cancel);
location (current, watch, geocode); motion; photos save; camera;
contacts; reminders. Ledger UI and metadata declarations. Bounded streams
and AbortSignal.

**Phase 3: system integration.**
Keychain secrets, Bluetooth LE (central role), Shortcuts run
(x-callback), host events (appearance, app foreground/background), folder
bookmarks. Bluetooth sits here because its handles outlive a call and
need the disposal rules settled first.

**Phase R: remote subset (any time after Phase 1).**
`CommTransport`, the ganymede-ui `device-bridge` plugin, session
matching, one-dialog-at-a-time and per-host mute, `disconnected` handling
across iPad suspend, the features marked "yes" in the remote table. Then
the browser fallback: the web implementation with click-through prompts in
ganymede-ui as a PWA; a JupyterLab labextension after that. Tests: a
cdp-kernel on Node behind Ganymede with a fake app frontend; a second,
non-app client on the same kernel must not answer; Playwright for the web
implementation in Chromium and WebKit.

## Documentation

Three readers, three places; all generated from or checked against the
support matrix so docs and behaviour can't drift.

- **Support matrix page.** Every method with a column each for on-device,
  remote in the app, and browser, plus a footnote per gap (why, and
  whether it's planned). Generated from the matrix in the package; CI
  fails if a method has no row.
- **API reference.** TSDoc on every method, published from the types
  package and shown by the editor. Each entry states where it works,
  what permission it needs on-device, and what cancel returns.
- **Guides.** "Your first device call", "Permissions and the ledger",
  "Using `device` from a remote kernel" (what's there, what isn't, why),
  "In a browser" (the click-through prompts), and "Headless runs".
- A test per row: the conformance suite calls each method under each
  transport and checks the result matches the matrix (`unavailable` where
  the matrix says no).

**Phase 4: embedded engine and headless runs (with ts-on-ipados tiers
2-3).**
Host-function transport for the JSC/V8 kernel. Share-sheet extension,
App Intents and widgets run scripts through the same transport, using
grants from the ledger.

## Open questions

1. Package name and home: its own repo, or inside the app repo?
2. Global `device` vs import-only. Global needs the cdp-kernel preload
   hook; import-only needs only a way for the module to find the
   transport.
3. On the Mac, does the local kernel run as a Worker in a WebView (same
   as iPad) or as a Node/Deno child of the bundled Ganymede? Worker keeps
   one code path; a child process gives full npm and the debugger. The
   socket transport exists only if the answer includes the second.
4. Motion: stream at a fixed rate (as above) or Juno's snapshot getters
   (`motion.latest()`) backed by a cache on the native side? Snapshot is
   simpler for polling loops.
5. Where the docs live: in the package's repo, or on Ganymede's docs
   site next to the client docs?

Settled 2026-10-18: remote kernels stop at features that need no
permission; browsers get a web-API subset where it fits.

## Next steps (2026-10-19)

Where it lives: not Ganymede (the Rust core never sees a device call) and
not cdp-kernel (a general kernel; it only gets generic hooks). The device
API's two ends, the TS package and the Swift package, share the message
format, the support matrix and the conformance tests, so they belong in
one repo of their own, `tlockney/ganymede-device` (name TBD; Thomas
creates it). Until Phase 0 proves the path, it starts as
`research/ts-device-api/`, the same way ganymede and ganymede-ui started.
The app repo comes later and depends on it.

1. **cdp-kernel, generic PRs (useful without this project):**
   a preload hook for code installed in the cell realm before the first
   cell; a `host` message kind in `runtime/browser-worker.mjs` so the
   Worker can send non-kernel messages to its owner page and get replies;
   `capabilities` in `kernel_info_reply`.
2. **Phase 0 in `research/ts-device-api/`:** the TS `device` object with
   `info` and `clipboard.readText`, a `WorkerTransport`, and a Playwright
   test with a stubbed `webkit.messageHandlers.device`, driven through
   ganymede-ui's in-page cdp-kernel (`src/lib/cdp-kernel.ts`, already on
   `@tlockney/cdp-kernel` 0.7.0).
3. **Phase 0 on the Mac:** a minimal SwiftUI app loading the ganymede-ui
   build in a WKWebView, with the Swift handler for those two methods.
   Needs Xcode, so it runs on Thomas's Mac (a Remote Control session), not
   in a cloud container. Check the hidden-kernel-WebView rule here.
4. **Then** create the repo, move the code over, and start Phase 1.
