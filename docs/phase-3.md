# Phase 3: system integration (spec)

Tracking issue: #68. Design context: [plan.md](plan.md) ("Phases",
"Permissions", "Remote kernels"). Builds on Phase 2 (#57): bounded
streams (protocol.md "Streams"), the permission core ("Permissions")
and the ledger ("The ledger").

Everything here is on-device only: none of it joins the remote subset or
the browser fallback (plan.md, "The remote subset"). Each part below is
one pull request unless it says otherwise, and each one adds TS types
with TSDoc, `support.ts` rows (`remote: "no"`, `browser: "no"`,
`permission` where it has one), protocol.md entries, the Swift handler,
XCTest with a fake source, and a ganymede-ui bump with any Info.plist
usage string.

Order: handles (1) first, since Bluetooth and folders return handles;
then secrets (2), host events (3), Bluetooth (4) and folders (5) in any
order. Shortcuts (6) is already filed as #40.

## 1. Native handles

Today `sound.player` is the one call that returns something that outlives
it, and its lifetime rules live in `Sounds`. Bluetooth connections and
folders need the same rules, so they become one mechanism first.

**TS**

```ts
interface NativeHandle extends AsyncDisposable {
  readonly closed: boolean;
  close(): Promise<void>;        // idempotent; later calls fail `failed`
}
```

A `handle()` helper in createDevice wraps a host id: `close()` sends
`handle.close { handle }`, `[Symbol.asyncDispose]` is `close`, and a
call on a closed handle rejects `failed` without a round trip.
`SoundPlayer` becomes a `NativeHandle`; its wire stays as it is
(`sound.close` is kept as an alias of `handle.close`).

**Swift**

A `Handles` registry in DeviceBridge: `open(owner:, kind:, limit:,
close:) -> id`, `get(id, owner:, kind:)`, `close(id, owner:)`. The same
lifetime as streams: an owner's handles close on `release`, a new
`hello`, `dropPage()`/`dropRemote()`/`dropAll()`; a cancel of the
opening call closes what it opened (the page dropped the answer). A
call naming another kernel's handle answers as no such handle (the
check #78 added for streams). Per-kernel limits per kind (sound players
stay at 32).

**Acceptance**: `sound.player` runs on `Handles` with its tests
unchanged; a test-only handle kind shows release, hello, drop, cancel of
the opening call, the owner check and the limit.

## 2. Secrets (`device.secrets`)

```ts
device.secrets.get(name): Promise<string | null>
device.secrets.set(name, value: string): Promise<void>
device.secrets.delete(name): Promise<boolean>   // true when it existed
device.secrets.list(): Promise<string[]>        // names only
```

- Keychain generic passwords, service `ganymede.device.secrets`,
  account `<notebook path>\0<name>`,
  `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, not synchronized.
  That class lets Phase 4's headless runs (a background widget refresh,
  a Shortcuts automation) read a secret while the device is locked,
  after it has been unlocked once since boot; the trade-off is that the
  item is readable while locked. Before the first unlock, `get` fails
  `unavailable`. Scoped per notebook: a notebook never sees another's
  names. `notebookMoved` re-keys them.
- Values are strings up to 64 KiB; names are 1 to 128 characters
  without NUL.
- No system permission, so the ledger alone gates it: capability
  `secrets`, a `Permission` whose status is always `authorized`, so the
  ledger prompt ("<notebook> wants to use saved secrets") is the only
  consent. Headless runs use a kept "always".
- Settings (ganymede-ui) lists each notebook's secret names with a
  delete button, beside its ledger grants.

**Acceptance**: a notebook sets, reads, lists and deletes a secret; a
second notebook can't see it; a rename keeps it; a ledger "deny"
rejects `denied`. XCTest against a fake keychain.

## 3. Host events (`device.on`)

```ts
device.on(event: "appearance" | "foreground" | "background" | "battery" | "locale",
          handler: (value) => void, options?: { signal?: AbortSignal }): () => void
```

- Built on streams, not a new message type: the first `on()` opens a
  `events.watch { events }` stream (capacity 64) and later `on()` calls
  share it. The returned function, the `signal`, or the last handler
  going away closes it. Keeping every message a call means the Worker's
  host channel still needs no push path (protocol.md, "Streams"), and
  the Phase 4 host-function transport gets events for free.
- Values: `appearance` `"light" | "dark"`; `foreground`/`background`
  `null`; `battery` `{ level, charging }`; `locale` the BCP 47 tag.
- Swift: one `StreamSource` per stream over NotificationCenter and KVO
  (`NSApp.effectiveAppearance`, `UIApplication` scene notifications,
  battery notifications), sending only on change.
- Unlike other streams, an interrupt does not close a handler's stream:
  `on()` outlives the cell that registered it, until the kernel restarts
  or the handler is removed. (The cell signal is not passed.)
- The `DeviceTransport.on` planned in plan.md is dropped in favour of
  this; plan.md says so already.

**Acceptance**: a cell's handler sees appearance and foreground changes
on a Mac and iPad; removing the last handler stops the source; a kernel
restart stops it.

## 4. Bluetooth LE central (`device.bluetooth`)

```ts
device.bluetooth.authorizationStatus() / isAuthorized() / requestAuthorization()
device.bluetooth.scan({ services?, allowDuplicates?, signal }): DeviceStream<Advertisement>
device.bluetooth.connect(id, { timeout?, signal }): Promise<Peripheral>   // NativeHandle
device.bluetooth.known(ids): Promise<Advertisement[]>                     // reconnect by id

interface Advertisement { id: string; name: string | null; rssi: number;
  services: string[]; manufacturerData: Uint8Array | null; serviceData: Record<string, Uint8Array> }

interface Peripheral extends NativeHandle {
  readonly id: string; readonly name: string | null;
  services(): Promise<Service[]>;            // discovered once, cached
  read(service, characteristic): Promise<Uint8Array>;
  write(service, characteristic, data, { withResponse? }): Promise<void>;
  notify(service, characteristic, { signal }): DeviceStream<Uint8Array>;
  rssi(): Promise<number>;
}
```

- Permission `bluetooth` (`CBManager.authorization`); Info.plist
  `NSBluetoothAlwaysUsageDescription`. Mac and iPad; `has()` is false
  while the radio is unsupported, and calls fail `unavailable` while it
  is powered off.
- `scan` is a bounded stream, capacity 128, drop-oldest (Juno's figure);
  `notify` capacity 256. Both stop on break, abort, interrupt.
- `connect` returns a handle (part 1), at most 8 per kernel. When the
  peer drops, pending calls reject `disconnected`, `notify` streams end
  with `disconnected`, and the handle is closed.
- One `CBCentralManager` per bridge; ids are the `CBPeripheral`
  identifier UUIDs, which `known(ids)` resolves with
  `retrievePeripherals`.
- Bytes cross as base64 (protocol.md "Binary values"); a characteristic
  value is at most 512 bytes, so the cost is small.

**Acceptance**: on a Mac and iPad, a cell scans, connects to a BLE
peripheral (a heart-rate strap or nRF test board), reads, writes,
subscribes, and sees `disconnected` when it powers off; interrupt during
scan and during connect stops both. XCTest with a fake central.

## 5. Folder bookmarks (`device.folders`)

The Worker kernel has no file system, and picked files come in by value
(plan.md, "Permissions"). Folders give a notebook lasting, scoped access
to a directory the person chose.

```ts
device.folders.pick({ write?, signal }): Promise<Folder | null>   // null when cancelled
device.folders.list(): Promise<Folder[]>       // this notebook's granted folders

interface Folder {
  readonly id: string; readonly name: string; readonly writable: boolean;
  entries(path?): Promise<{ name: string; kind: "file" | "directory"; size?: number; modified?: Date }[]>;
  read(path): Promise<Uint8Array>;               // at most 16 MiB
  write(path, data): Promise<void>;              // writable folders only
  remove(path): Promise<void>;                   // writable folders only
}
```

- The picker is the consent, so `pick` needs no ledger prompt (as
  `files.pick`). The grant is a security-scoped bookmark kept in the
  ledger store, keyed by notebook path; Settings lists and revokes them
  beside the ledger grants, and `notebookMoved` carries them.
- `path` is relative to the folder; `..`, absolute paths and symlinks
  that resolve outside it fail `denied`. Access is started and stopped
  around each call (`startAccessingSecurityScopedResource`).
- A stale bookmark is refreshed when it resolves; one that no longer
  resolves is dropped and the call fails `unavailable`.
- Process kernels (a Node or Deno cdp-kernel on the Mac) could get the
  same folders as Deno `--allow-read`/`--allow-write` scopes later; not
  in this phase.

**Acceptance**: a notebook picks a folder on a Mac and an iPad (Files,
iCloud Drive), lists, reads and writes in it after an app restart, can't
leave it with `..` or a symlink, and loses access when revoked.

## 6. Shortcuts

`device.shortcuts.run(name, { input })`: filed as #40 (waits on
ganymede-ui#303), tracked under ganymede-ui#301.

## Exit

Each part tried on a real Mac and iPad where `has()` is true, including
a denied permission or ledger answer and an interrupt during a wait;
plan.md "Where things stand" updated.

## Open questions

1. Secrets: per notebook only, or also an app-wide scope the person can
   share across notebooks (Settings would mark which)?
2. Folders: should a process kernel on the Mac get them as Deno
   permission scopes in this phase, or wait?
3. Bluetooth on a remote kernel stays "no"; confirm no need for it from
   the Mac mini.
