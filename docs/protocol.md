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
| `{ id, cancel: true }` | The call `id` was aborted: an interrupt, an `AbortSignal`, or the Worker stopped. Dismiss any sheet or picker it showed, and close the handle ("Handles" below) the call opened, such as a `sound.player` player (the page drops its answer, so it has no id to close). | Anything; ignored |
| `{ id, cancel: true }` (continued) | For a stream (below): a cancel of its opening call, or of the `stream.next` waiting on it, stops its source. | |
| `{ owner, release: true }` | Kernel `owner` shut down. Stop its sounds, close its handles (such as players) and stop its streams. | Anything; ignored |

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
| `info` | `{}` | `{ isPad?, screen?: { width, height, scale }, battery?: { level, charging }, darkMode, locale }`, read when called; `battery` is left out without one, and `level` (0 to 1) is `null` when unknown |
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
| `photos.save` | `{ image }`: PNG, JPEG, GIF, HEIC or TIFF bytes, at most 16 MiB | `null` once the photo is in the library. Needs the photos (add-only) permission |
| `sound.play` | `{ data, volume? }`, volume 0 to 1 | `null` once it starts; it plays to its end; at most 32 playing per kernel (one an audio interruption paused no longer counts) |
| `sound.player` | `{ data }` | `{ player, duration }`: an id, paused at the start; at most 32 open per kernel; `sound.control` and `sound.close` reach only the calling kernel's players |
| `sound.control` | `{ player, action?, time?, volume? }`; action `play`, `pause`, `stop`, `seek` (to `time` seconds) or `state` (the default) | `{ playing, time, duration }` after the change; a bad `action` or `time` fails `failed` and changes nothing, and `play` fails `failed` when the sound can't start |
| `sound.close` | `{ player }` | `null`; closing one already closed is fine |
| `notifications.schedule` | `{ body, delay, title? }`, delay in seconds, more than 0 | the notification's id, a string. Needs the notifications permission ("Permissions" below) |
| `notifications.pending` | `{}` | `[{ id, body, title?, date? }]`, the calling notebook's not yet delivered; `date` as ISO 8601 |
| `notifications.cancel` | `{ id }` | `null`; an id that's gone or another notebook's changes nothing |
| `notifications.cancelAll` | `{}` | `null`; the calling notebook's only |
| `location.current` | `{ accuracy? }`: `best` (default), `block` (about 100 m) or `city` (a few km) | `{ latitude, longitude, accuracy, timestamp, altitude?, altitudeAccuracy?, speed?, course? }`: degrees, metres, milliseconds since 1970, metres per second, degrees from true north; parts Core Location doesn't know are left out. Needs the location permission |
| `location.watch` | `{ accuracy? }` | a stream ("Streams" below) of fixes as `location.current` answers them; the queue keeps 16. Needs the location permission |
| `location.geocode` | `{ address }` | `[{ name?, street?, city?, region?, postalCode?, country?, countryCode?, latitude?, longitude? }]`, best match first, `[]` when none |
| `location.reverseGeocode` | `{ latitude, longitude }` | places as `location.geocode` answers them |
| `motion.watch` | `{ interval? }`, seconds, 0.01 to 1, 0.1 by default | a stream ("Streams" below) of samples as `motion.latest` answers them. Needs the motion permission |
| `motion.latest` | `{}` | `{ attitude: { roll, pitch, yaw }, rotationRate, gravity, userAcceleration, timestamp }`: radians, radians per second and g (each `{ x, y, z }`), milliseconds since 1970. Needs the motion permission |
| `contacts.search` | `{ query }` | contacts (below) whose name matches; by email or phone number when the query is one. Needs the contacts permission |
| `contacts.get` | `{ id }` | a contact, or `null` when there is none with that id |
| `contacts.all` | `{}` | every contact the app may see, in the person's sort order |
| `contacts.add` | `{ contact }`: a contact without `id`, with a name, organization, email or phone | the new contact's id |
| `contacts.delete` | `{ id }` | `true`, or `false` when there was none |
| `camera.capture` | `{}` | the photo as JPEG bytes (`{ base64 }`, at most 16 MiB), or `null` when the person cancels. A dialog ("Dialogs" below) that needs the camera permission first; iPad and iPhone only |
| `reminders.calendars` | `{}` | `[{ id, title, isDefault }]`, the reminder lists. Needs the reminders permission (full access) |
| `reminders.list` | `{ calendar?, completed? }` | reminders (below) in that list, or every list; only completed or only incomplete ones when `completed` is set |
| `reminders.add` | `{ reminder }`: `{ title, notes?, due?, priority?, calendar? }` | the new reminder's id |
| `reminders.complete`, `reminders.uncomplete` | `{ id }` | `true`, or `false` when there was none |
| `reminders.delete` | `{ id }` | `true`, or `false` when there was none |

`hello` is called once per Worker start, before the first cell. A method
missing from `capabilities` is never sent: the TypeScript side rejects it
as `unavailable` itself.

Support for each method across on-device, remote and browser kernels is
in `src/support.ts`: shipped (`yes`), `planned`, or `no`. Its
`supportTable()` renders the table in ganymede-ui's `docs/device.md`.

Notifications belong to the notebook that scheduled them (the host's
`setNotebook` for the calling kernel; without one, every `notifications.*`
call fails `denied`). Swift keeps the notebook's path in each
notification's `userInfo`, so after a rename the old notebook's pending
notifications still fire but no longer list or cancel from the new path.
The app turns the namespace on with `DeviceBridge.addNotifications()`;
while the app is in front, `SystemNotificationScheduler` shows them as
banners when the app has no notification center delegate of its own.

Location is when in use only: the app asks with
`requestWhenInUseAuthorization`, and `location.authorizationStatus`
reads `reducedAccuracy` when the person turned precise location off,
which still lets calls through with coarser fixes. Each `current` and
`watch` has a Core Location manager of its own; a cancel, `stream.close`
or the kernel's release stops it. Geocoding (CLGeocoder) needs the
network but no permission. The app turns the namespace on with
`DeviceBridge.addLocation()`, and needs
`NSLocationWhenInUseUsageDescription` in its Info.plist and, on a Mac
with the hardened runtime, the `com.apple.security.personal-information.location`
entitlement. With Location Services off, `current` and `watch` reject
`denied`; a fix that can't be had (no signal) rejects `failed`.

Motion is iPad and iPhone only: `DeviceBridge.addMotion()` does
nothing where Core Motion has no device motion, so a Mac never lists it.
The system has no prompt for these sensors, so the permission is the
app's ledger alone: `motion.authorizationStatus` reads `authorized`
unless the ledger refuses. `watch` and `latest` share one Core Motion
source, shared by every bridge in the app, that runs at the shortest
interval anyone wants: each watch gets the sample nearest each
`interval`, so about one per `interval` on average even when it isn't a
multiple of the source's, and `latest` keeps the source at 0.1 s for 10
seconds after its last call. A call while `latest` is warm gets the
newest sample; any other waits for the next. With no watch and `latest`
cold, the source stops. If Core Motion stops with an error, waiting
calls fail `failed` and watches end with it.

Saving a photo needs add-only access (`PHAccessLevel.addOnly`): the app
can add to the library but never read it, so a grant reads `writeOnly`.
`photos.pick` needs no permission, since the system picker shows the
library without letting the app in; the `photos` trio is about saving.
Bytes that aren't PNG, JPEG, GIF, HEIC (or another HEIF still) or TIFF
fail `failed` before any prompt.
The app turns `save` on with `DeviceBridge.addPhotoSaving()`, and needs
`NSPhotoLibraryAddUsageDescription` in its Info.plist and, on a
sandboxed Mac, the `com.apple.security.personal-information.photos-library`
entitlement.

A contact is a plain record: `{ id, givenName?, middleName?,
familyName?, nickname?, organization?, jobTitle?, emails?, phones?,
addresses?, birthday? }`. `emails` and `phones` are `[{ label?, value }]`;
`addresses` are `[{ label?, street?, city?, state?, postalCode?,
country? }]`; `birthday` is `YYYY-MM-DD`, or `--MM-DD` without a year.
Labels are plain words (`home`, `work`, `mobile`, `main`, `iPhone`,
`school`, `other`) or the person's own. Missing fields are left out.
Every `contacts.*` method needs the contacts permission. With limited
access (iPhone and iPad), the status reads `limited` and the framework
shows only the contacts the person shared with the app. Not wrapped:
groups, containers (accounts; `add` uses the default one), photos, and
notes (which need an entitlement Apple grants on request). A bad call
fails `failed` before any prompt. The app turns the namespace on with
`DeviceBridge.addContacts()`, and needs `NSContactsUsageDescription` and,
on a sandboxed Mac, the
`com.apple.security.personal-information.addressbook` entitlement.

A reminder is a plain record: `{ id, title, calendar, completed, notes?,
due?, priority?, completedAt? }`. `calendar` is the list's id. `due` is
`YYYY-MM-DD` for a due day, or ISO 8601 for a day and time (kept in the
device's time zone); `priority` is 1 (high) to 9 (low), left out for
none; `completedAt` is ISO 8601. Dates are Gregorian whatever the
device's calendar. EventKit grants reminders only full access, so there
is no write-only mode here. Not wrapped:
recurrence, alarms, subtasks, and making or renaming lists. A bad call
fails `failed` before any prompt. The app turns the namespace on with
`DeviceBridge.addReminders()`, and needs
`NSRemindersFullAccessUsageDescription` and, on a sandboxed Mac, the
`com.apple.security.personal-information.calendars` entitlement.

## Streams

A streaming method yields many values, such as a location watch. In a
cell it is an async iterator with a `dropped` count (`DeviceStream`,
src/stream.ts):

```ts
for await (const fix of device.location.watch({ signal })) { … }
```

On the wire every message is an ordinary call, so cancel, interrupt and
the Worker's host channel need nothing new: the page pulls values, and
nothing pushes into the Worker.

| Call | Params | Result |
| --- | --- | --- |
| the streaming method, such as `location.watch` | its own | `{ stream }`, an id: the call's own `id`. A refusal (`denied`, `unavailable`) is the call's error |
| `stream.next` | `{ stream }` | `{ values: [...], dropped, end? }`, answered as soon as a value is queued; `end: true` when the source finished, after which the stream is gone. A source's error is the reply's error, once the values before it were read |
| `stream.close` | `{ stream }` | `null`; stops the source. A `stream.next` waiting on it gets `end` |

- Swift keeps each stream's values in a queue that holds the newest
  `capacity` (set per method with `DeviceBridge.addStream`) and drops the
  oldest, counting them in `dropped`, so a slow cell costs a count, not
  memory. One `stream.next` waits at a time.
- The cell's iterator stops the source when the loop ends (`break`,
  `return`, a throw) with `stream.close`; when its signal aborts or the
  kernel interrupts during a `stream.next`, by the cancel of that call;
  and when the kernel interrupts between reads, by `stream.close` from the
  cell's `jupyter.signal`. A new `hello` from the same owner, `release`,
  `dropPage()`, `dropRemote()` and `dropAll()` stop the owner's streams.
- At most 16 streams are open per kernel. `stream.next` and
  `stream.close` reach only the calling kernel's (`owner`) streams:
  `stream.next` on another kernel's id fails `failed` as no such stream,
  and `stream.close` answers `null` and leaves it running, as it does for
  an id that has ended or never was.
- Streaming methods are on-device only: none is in the remote subset, and
  `stream.next` and `stream.close` aren't either, so over a comm they
  fail `unavailable`.

## Handles

A handle is something a call opened that outlives the call, which later
calls name by id: a `sound.player` player today, Bluetooth connections
and folders in Phase 3 (docs/phase-3.md). In a cell it is a
`NativeHandle`: `closed`, `close()`, and `await using`.

| Call | Params | Result |
| --- | --- | --- |
| `handle.close` | `{ handle }` | `null`; frees what the handle holds. Closing one already closed, or another kernel's, is fine and does nothing |

- Swift keeps handles in one registry (`Handles`), each under the kernel
  that opened it (`owner`), with the same lifetime as streams: a new
  `hello` from the same owner, `release`, `dropPage()`, `dropRemote()`
  and `dropAll()` close the owner's handles, and a cancel of the call
  that opened one closes it.
- A call naming another kernel's handle answers as for no such handle.
- Each kind has a per-kernel limit (32 sound players).
- `sound.close { player }` is a player's `handle.close`, kept by name.
- A cell's handle rejects `failed` after `close()`, without a round trip.
- Handles are on-device only: `handle.close` isn't in the remote subset.
- `hello` doesn't list `handle.close`: every host with a handle kind
  answers it.

## Host events

`device.on(event, handler)` calls `handler` as the device changes. It
reads one stream, `events.watch`, which the first handler opens and the
last one's removal closes; the app turns it on with
`DeviceBridge.addHostEvents()`.

| Call | Params | Result |
| --- | --- | --- |
| `events.watch` | `{ events? }`: a list of `appearance`, `foreground`, `background`, `battery`, `locale`; all when left out | a stream ("Streams" above) of `{ event, value }`, capacity 64 |

- Values: `appearance` `"light"` or `"dark"`; `foreground` and
  `background` `null`; `battery` `{ level, charging }`, `level` 0 to 1 or
  `null`; `locale` a BCP 47 tag.
- Each is sent only when it changes, never its starting state. A Mac
  without a battery never sends `battery`.
- Swift (`HostEventSource`) looks for changes on the locale and battery
  notifications and once a second, against `DeviceState`'s values
  (`info`'s), and sends `foreground` and `background` as the app becomes
  active or not (on iPad and iPhone, as it enters the foreground or
  background).
- The cell's stream gets no cell signal: an interrupt leaves handlers
  running, since `on` outlives the cell that called it. Removing the last
  handler, its `signal`, or a kernel restart (a new `hello`) closes it.
- If the stream can't open or fails, the cell removes every handler and
  writes one line to stderr. `has("on")` says beforehand whether the host
  sends events.
- No permission. On-device only: `events.watch` isn't in the remote
  subset.

## Bluetooth

`device.bluetooth` is a Bluetooth LE central over Core Bluetooth. The
app turns it on with `DeviceBridge.addBluetooth()`, which needs
`NSBluetoothAlwaysUsageDescription` in its Info.plist.

| Call | Params | Result |
| --- | --- | --- |
| `bluetooth.scan` | `{ services?, allowDuplicates? }` | a stream ("Streams" above) of `{ id, name, rssi, services, manufacturerData, serviceData }`, capacity 128. `manufacturerData` is bytes or `null`; `serviceData` maps service UUIDs to bytes |
| `bluetooth.known` | `{ ids }`: at most 64 peripheral ids | `[{ id, name }]`, the ones the system knows |
| `bluetooth.connect` | `{ id, timeout? }`: seconds, 1 to 120, 15 by default | `{ peripheral, id, name }`: `peripheral` is a handle ("Handles" above) of kind `bluetooth.peripheral`, at most 8 per kernel |
| `bluetooth.services` | `{ peripheral }` | `[{ uuid, characteristics: [{ uuid, properties }] }]`, discovered once; `properties` from `read`, `write`, `writeWithoutResponse`, `notify`, `indicate` |
| `bluetooth.read` | `{ peripheral, service, characteristic }` | the value's bytes |
| `bluetooth.write` | `{ peripheral, service, characteristic, data, withResponse? }`: `withResponse` true by default | `null`, once confirmed; at once without a response |
| `bluetooth.notify` | `{ peripheral, service, characteristic }` | a stream of the value's bytes, capacity 256 |
| `bluetooth.rssi` | `{ peripheral }` | dBm |

- UUIDs are 16-bit ("180D"), 32-bit or 128-bit; Swift checks them before
  Core Bluetooth sees them, and answers them upper-cased.
- `scan`, `known` and `connect` need the `bluetooth` permission
  (`CBManager.authorization`); the system asks when the bridge first
  makes its `CBCentralManager`. They fail `unavailable` while the radio
  is off or unsupported, and `connect` fails `timeout` when the
  peripheral doesn't answer in time.
- A handle's calls need no permission, only the handle; another kernel's
  answers as for none.
- When the peripheral goes away, its waiting calls fail `disconnected`,
  its `notify` streams end with `disconnected`, and its handle closes.
  `handle.close` disconnects it: waiting calls fail `failed`, `notify`
  streams end.
- One `CBCentralManager` per bridge. Its open scans share one system
  scan, the union of their filters, and each filters its own. Ids are
  the `CBPeripheral` identifiers, which differ from device to device.
- On-device only: none of these is in the remote subset.

## Permissions

A namespace that needs a system (TCC) permission, such as `location`,
has the trio in TypeScript (`authorization()` in src/permission.ts) and
answers two more methods:

| Method | Params | Result |
| --- | --- | --- |
| `<namespace>.authorizationStatus` | `{}` | the status, without prompting |
| `<namespace>.requestAuthorization` | `{}` | the status after the system prompt; without one when the person was already asked |

The status is one of `notDetermined`, `denied`, `restricted`,
`authorized`, `limited`, `writeOnly` or `reducedAccuracy`. The last
three are partial grants (some contacts or photos; add-only reminders or
photos; approximate location) and count as granted.

- The namespace's other methods ask lazily: a call while the status is
  `notDetermined` shows the system prompt first, and any status short of
  a grant rejects the call `denied`. Calling `requestAuthorization()`
  first is optional. Calls that come while a prompt is up wait on that
  prompt; it shows once.
- A method's argument checks run before any prompt: a malformed call
  fails `failed` without asking (`addMethod`/`addStream` `check:`).
- A cancel (interrupt, abort) while the prompt is up rejects the call
  `cancelled` at once. The system prompt can't be closed; its answer
  still sets the status for later calls, but the cancelled call doesn't
  run.
- In Swift, `DeviceBridge.addPermission(namespace, permission)` takes a
  `Permission` wrapping the framework's status and request; methods take
  `permission: namespace` in `addMethod` (calls that answer later, with a
  cancel action) or `addStream`. Handlers throw or reply
  `DeviceCallError(code, message)` for an error with a code.
- Permissioned methods are on-device only: `support.ts` marks them
  `remote: "no"` and `browser: "no"` with a `permission` field, and the
  generated support table gains a Permission column with the first one.
  Their TSDoc names the permission ("Needs the location permission.").
- The app's own ledger (below) is checked before the system prompt.

### The ledger

Before the system prompt, the app asks the person whether this notebook
may use the capability (docs/plan.md, "Permissions" item 2). The ledger
lives in Swift (`DeviceBridge.ledger`, Ledger.swift); nothing new crosses
the wire.

- The host says which notebook each kernel runs:
  `setNotebook(path, for: owner)` when the kernel starts (`owner` is its
  `webkitHost().owner`), and `notebookMoved(from:to:)` on a rename or
  move, which carries kept answers along (replacing answers left at the
  new path). A permissioned call from a kernel with no notebook is
  denied. `release`, `dropPage()`, `dropRemote()` and `dropAll()` forget
  their kernels' notebooks, since owner numbers start over with the page:
  set the notebook again for each kernel the new page starts.
- Answers: once (this call), always, deny. "Always" and "deny" are kept,
  keyed by (notebook path, capability), in UserDefaults by default
  (`LedgerStore`). A kept "deny" rejects `denied` without the system
  prompt; so does a dismissed prompt, which keeps nothing. Ledgers on
  one store read it on each use, so an app with a bridge per window and
  a Settings screen with a ledger of its own share one set of answers;
  owners (`setNotebook`) stay per ledger.
  `requestAuthorization()` answers `denied` when the ledger refuses, and
  `authorizationStatus()` reads `denied` for a kernel with no notebook or
  a kept deny. When the system status is already `denied` or
  `restricted`, a call fails without the app's prompt.
- The app shows the prompt through `ledgerPrompter`
  (`askPermission(capability, notebook:, id:, answer:)`). Calls for the
  same notebook and capability share one prompt. A cancel takes the call
  off it, and once no call waits, `dismissPermission(id)` closes it.
  With no prompter (headless runs: share sheet, Shortcuts), only kept
  "always" answers let a call through.
- `ledger.grants` and `ledger.revoke(notebook:capability:)` are for the
  Settings screen; a revoke applies from the next call.
- Declarations: `undecided(declared, notebook:)` takes a notebook's
  `metadata.ganymede.device` list and returns the capabilities this app
  has with no kept answer, so the app can ask when the notebook opens.
- Pickers, share and dialogs need no permission, so they never reach
  the ledger.

## Dialogs

`ui.*`, `share`, `preview`, `files.*`, `photos.pick` and `camera.capture` calls wait on a person, so Swift answers
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
- `camera.capture` is there once the app calls
  `DeviceBridge.addCameraCapture()`. It asks for the camera permission
  (the app's ledger, then the system) before it queues, and is refused
  `denied` without a grant. It then shows the system camera screen
  (`UIImagePickerController`) over the window's top view controller.
  The photo comes back as JPEG. The app needs `NSCameraUsageDescription`;
  without it the request answers the status as it is, rather than the
  system ending the app.
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

### In a browser

A notebook page in a browser has no Swift bridge, so it passes
`answerDevice` a `forward` that answers with web APIs:
`browserForward({ click })` from `src/browser.ts`
(`@tlockney/ganymede-device/browser`). Its `hello` says
`platform: "browser"` and lists what the browser has, within the remote
subset (the browser column of `src/support.ts`; a test checks the two
agree).

Most of these APIs work only right after a click (user activation), and
a kernel message isn't one. For those, the forward calls the page's
`click({ method, label, signal, detail }, run)`: the page shows a prompt
with a button ("Copy to clipboard", "Choose a file"), calls `run()` from
inside that button's click handler, and resolves with what `run()`
resolves to. `detail`, when set, is what the call carries, for the
prompt to preview: the text `clipboard.writeText` copies, or the text
(else the URL) `share` shares. It comes whole; the page truncates it.

- One prompt shows at a time, in the order the calls came, as the
  app's dialog queue does; a call cancelled while it waits shows none.
- A prompt the person dismisses answers as a cancel does on the device:
  `[]` for the pickers, `false` for `share` and `files.export`, and
  `cancelled` for the rest. A prompt taken down because the kernel sent
  a cancel (`signal` aborts) fails the call `cancelled`. The browser
  refusing after the click (`NotAllowedError`) fails it `denied`.
- Without `click`, the methods that need one (`browserClick` in
  `src/support.ts`) are left out of `hello`.
- `info` has the screen, appearance and locale; no model, battery or
  `isPad` (a browser on an iPad can't tell).
- Clipboard reads and writes, `openURL` (a new tab, `noopener`; `inApp`
  is ignored), `share` (Web Share; files only where `canShare` allows),
  and the file and photo pickers (a file input; type identifiers such
  as `public.json` can't be said in `accept`, so with one any file is
  allowed) go through a click. Clipboard images are PNG only.
- `files.export` downloads the file after a click, as the app shows a
  save panel first, and answers `true` then, since a page can't tell
  whether it was saved; a dismissed prompt answers `false`.
- A dismissed file picker answers `[]` through the input's `cancel`
  event (Chrome 113, Safari 16.4, Firefox 91); in an older browser the
  call waits until the kernel cancels it. A file input can't limit how
  many files are picked, so `photos.pick` keeps the first `limit`.
- A release, or the owner's next `hello`, stops the sounds that owner
  started. At most 32 play at once per owner.
- `sound.play` plays at once when the page may autoplay, and otherwise
  asks for a click.
- The `ui.*` dialogs aren't answered yet: the page would draw them, and
  no page does so far.

