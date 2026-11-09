# Phase 4: embedded engine and headless runs (spec)

Tracking issue: #69. Design context: [plan.md](plan.md) ("Phases",
"Permissions") and the iPadOS TypeScript design note (ts-on-ipados tiers
2 and 3). Waits on the embedded engine kernel (the native in-app kernel,
tlockney/ganymede#266, on hold until it is designed) and builds on
Phase 2's ledger (#57).

Phases 0 to 3 run every call through a Worker in a hidden kernel web
view. Phase 4 adds kernels and scripts that have no web view: a
JavaScript engine embedded in the app (JavaScriptCore first, jitless V8
later), run from a notebook, the share sheet, Shortcuts or a widget.

## 1. Host-function transport

```ts
// src/host.ts
hostFunctionTransport(post: (message: string) => Promise<string>): DeviceTransport
```

- The engine gets one function, `__ganymedeDevice(message)`, installed
  by Swift: JSExport on JavaScriptCore, an op for V8. It takes and
  answers JSON text in exactly the messages `webkitHost()` posts today
  (`{ id, owner, method, params }`, `{ id, cancel }`,
  `{ owner, release }`), and Swift hands them to the same
  `DeviceBridge.respond(to:reply:)`. Streams, the permission core, the
  ledger and handles need nothing new, since every message is a call.
- Ids and owners: one owner per engine context, from a counter in
  DeviceBridge that is kept apart from the web view's (as the remote
  handler's ids are negative today). Swift knows which context called,
  so it stamps that context's owner on every message and ignores any
  `owner` in the JSON: the message format stays the same, but code in
  one context can't name another's owner to reach its streams, handles
  or ledger grants.
- Binary values cross as base64, as on the web view; a later op can pass
  bytes directly (protocol.md, "Binary values" note).
- Cancel: the engine's interrupt aborts the cell's signals, which send
  `{ id, cancel }` as the Worker does.
- A preload for the engine installs `device` with this transport and
  `hello`, as src/preload.ts does for the Worker.

**Acceptance**: the conformance tests that run against the Worker
transport (test/device.test.ts, the browser test) pass against a
host-function transport in Node with a fake bridge, and on an iPad with
JavaScriptCore.

As built: `src/host.ts` (`hostFunctionTransport`, `installHostDevice`,
exported as `@tlockney/ganymede-device/host`) and Swift's
`EngineDevice` (`bridge.engineDevice()`, `install(in: JSContext)`).
test/host-transport.test.ts runs test/device.test.ts again through the
host function. Swift maps each context's ids to bridge-wide ones rather
than asking for negative ids, since an engine can't be trusted to keep
to a range. Not yet: the run on an iPad with JavaScriptCore, which needs
an engine kernel to run cells (ganymede#266).

## 2. Headless runs

A run with no notebook on screen: the share sheet, Shortcuts, a widget
refresh.

- The bridge for a headless run has no `ledgerPrompter` and no dialog
  presenter. Its `hello` lists only methods that work without a person:
  no `ui.*`, pickers, `share`, `preview`; permissioned methods only when
  the ledger has a kept "always" for the script's notebook and
  capability and the system permission is granted. So `has()` answers
  truthfully and a call outside the list fails `unavailable`.
- The script is a notebook (run top to bottom) or a `.ts` file; its path
  keys the ledger as a notebook's does.
- `support.ts` gains a `headless` column, and the docs a "Headless runs"
  guide (plan.md, "Documentation").
- The ledger store moves to an App Group's UserDefaults suite
  (`UserDefaultsLedgerStore(defaults:)`), so extensions read the app's
  grants. Extensions read; only the app writes. Secrets (phase-3.md,
  part 2) are in the shared keychain access group
  `<team>.ganymede.device` for the same reason.
- Entitlements, on the app and on every extension:
  `com.apple.security.application-groups` for the suite (`group.<name>`
  on iOS and iPadOS, `<team>.<name>` on the Mac) and
  `keychain-access-groups` with `<team>.ganymede.device`. Without them
  the extension's reads come back empty rather than failing.

**Acceptance**: a headless run of a notebook with a kept location grant
reads the location; without it the call is `unavailable` in `has()` and
fails `unavailable`; a dialog fails `unavailable`.

## 3. Share-sheet extension

- "Run with Ganymede" in the share sheet on iPad, iPhone and Mac. The
  person picks a script (remembered per content type); the shared items
  arrive as `device.input` (`{ text?, url?, files: File[] }`, files
  copied in, 16 MiB together).
- The script's return value or `device.output(...)` (text, a URL, or
  files) is handed back to the share sheet's host app where it accepts
  one (for example a reply in Messages), or shown in the extension.
- Limits: share extensions have a memory ceiling (about 120 MB on iOS),
  so the engine runs jitless with a heap cap, and a run is cut off after
  30 s with a message.

**Acceptance**: sharing a web page runs a script that fetches it and
returns a summary; sharing a photo runs a script that returns a resized
copy; a script over the time limit is stopped with a message.

## 4. App Intents (Shortcuts and Siri)

- `RunNotebookIntent(notebook, input: String?)` returns text and files;
  `RunScriptIntent(script, input)` the same for a `.ts` file. Both run
  headless in the app process (`openAppWhenRun = false`).
- A Shortcuts action per notebook the person marks "Show in Shortcuts".
- This is the reverse of #40 (`device.shortcuts.run`, a cell running a
  shortcut); both may land, independently.

**Acceptance**: a Shortcut runs a notebook with input text and uses its
output in the next action, on a Mac and an iPad, with the app closed.

## 5. Widgets

Widget extensions get tens of megabytes and a few seconds per refresh,
too little for an engine run. So a widget shows what a script last
published, and refreshes come from the app or an App Intent:

- `device.widget.update(kind, content)` from any run (headless or in a
  notebook) stores `content` in the App Group and reloads that widget
  kind's timeline. `content` is a small declarative layout: title, up to
  six rows of text or a number with a unit, a tint, an optional
  sparkline of up to 64 numbers.
- A widget's configuration picks a script; tapping it opens the
  notebook. A Background Task (BGAppRefreshTask on iOS, a scheduled run
  on the Mac) reruns widget scripts headless when the system allows.

**Acceptance**: a notebook publishes a widget on a Mac and an iPad; the
background refresh updates it with the app closed.

## Exit

Each entry point tried on a real iPad and Mac; plan.md "Where things
stand" updated.

## Open questions

1. Widgets: is "publish from a run" enough, or should widgets run the
   engine themselves despite the limits?
2. Share extension and intents: run in their own processes with their
   own engine, or hand the work to the app (which may not be running)?
3. The order relative to ganymede#266: does the host-function transport
   land with the native kernel's first version, or after it?
