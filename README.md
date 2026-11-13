# ganymede-device

> [!IMPORTANT]
> **Moved.** This package now lives in
> [tlockney/ganymede-ui, `packages/device`](https://github.com/tlockney/ganymede-ui/tree/main/packages/device),
> with its history (tlockney/ganymede-ui#560). Open issues and pull
> requests there. This repository is no longer updated.

The `device` API: native features for TypeScript notebooks in the Ganymede
Mac and iPad apps, in the spirit of [Juno's `juno`
module](https://juno.sh/docs/python/juno/). A cell calls
`await device.clipboard.readText()` and the app answers from Swift.

> [!IMPORTANT]
> **macOS and iOS only, for now.** The native side is the Swift
> `DeviceBridge` in Ganymede's Mac, iPad and iPhone apps (macOS 26 and
> iOS 26). There is no host for Windows, Linux or Android. A notebook
> page in any browser can answer a few methods that need no permission
> with web APIs (the browser fallback); everything else needs one of
> the apps.

```ts
/// <reference types="@tlockney/ganymede-device/globals" />
if (device?.has("clipboard.readText")) {
  const text = await device.clipboard.readText();
}
```

Every method, with its arguments, return value, errors, where it works
and an example, is in [docs/reference.md](docs/reference.md). The design,
scope and phases are in [docs/plan.md](docs/plan.md); the wire format
and the Swift side's contract in [docs/protocol.md](docs/protocol.md).

## Status

Phase 0 and Phase 1's methods are done on both sides. The TypeScript
side answers `hello`, the text and image clipboard, `info`, haptics,
`openURL`, the `ui` dialogs (alert, confirm, prompt, action sheet, date
picker), the share sheet, Quick Look previews, the file and photo
pickers, and sound, with bytes crossing the bridge as base64
(docs/protocol.md). It runs in cdp-kernel's browser Worker through its
`preload` and `host` options
([tlockney/cdp-kernel#384](https://github.com/tlockney/cdp-kernel/issues/384)),
and is tested end to end in headless Chromium against a fake Swift
bridge. The Swift `DeviceBridge` answers the same methods; the Mac and
iPad apps in [tlockney/ganymede-ui](https://github.com/tlockney/ganymede-ui)
register it on their hidden kernel web view.

cdp-kernel running in the app's kernel web view gets `device` as a
global. A kernel elsewhere, such as cdp-kernel on Node behind Ganymede,
gets the remote subset (the methods that need no permission) with
`connectDevice(jupyter.comm)`, answered by the notebook page in the app
(docs/protocol.md, "Over a Jupyter comm") from the ganymede-ui release
that carries tlockney/ganymede-ui#378. A notebook page in a browser
can answer the same calls with web APIs (`/browser`), as ganymede-ui's
does outside the app (tlockney/ganymede-ui#384); the dialogs (`ui.*`)
there are still planned. The package isn't published yet (#24).

## Layout

- `src/device.ts`: the `device` object over a `DeviceTransport`.
- `src/preload.ts`: the Worker preload module that installs
  `globalThis.device` when the host answers `hello`.
- `src/webkit.ts`: the page's `host` handler, forwarding to
  `webkit.messageHandlers.device`.
- `src/comm.ts` (`/remote`): `connectDevice(jupyter.comm)`, the kernel
  side of the remote transport over Jupyter comms, for kernels that
  aren't in the app (docs/protocol.md, "Over a Jupyter comm").
- `src/frontend.ts` (`/frontend`): `answerDevice(kernel)`, the app's
  side of that transport, which the notebook page runs for each kernel
  connection and which forwards to the bridge's `deviceRemote` handler.
- `src/browser.ts` (`/browser`): `browserForward({ click })`, the
  browser fallback: answers those calls with web APIs, running each that
  needs user activation, or would save a file, from a click on a prompt
  the page shows.
- `src/support.ts`: which methods work on-device, remotely and in a
  browser, today and planned; the source for docs and tests.
  `npm run support-table` prints it as the Markdown that ganymede-ui's
  `docs/device.md` embeds.
- `src/globals.ts`: ambient types for cells.
- `scripts/reference.ts`: generates `docs/reference.md` from the doc
  comments in `src/device.ts` and the rows in `src/support.ts`. After
  changing either, run `node scripts/reference.ts --write`;
  `test/reference.test.ts` fails while the page is out of date, a
  method lacks a summary, `@param` or `@example`, or an example doesn't
  type-check.
- `Package.swift`, `swift/Sources/DeviceBridge/`: the Swift side, a
  `WKScriptMessageHandlerWithReply` named `device`, and a second one,
  `deviceRemote`, limited to the remote subset (`Remote.swift`).

## Using it in a page

```js
import { startBrowserKernel } from "@tlockney/cdp-kernel/browser";
import workerUrl from "@tlockney/cdp-kernel/browser/worker?worker&url";
import { webkitHost } from "@tlockney/ganymede-device/webkit";
import preloadUrl from "@tlockney/ganymede-device/preload.js?url";

startBrowserKernel({
  createWorker: () => new Worker(workerUrl, { type: "module" }),
  preload: [preloadUrl],
  host: webkitHost(),
  // kernel_info_reply's `capabilities`, so a UI knows this kernel can
  // reach the app. Which methods it has comes from `device.has()`.
  capabilities: { device: true },
});
```

Set these options only when `findMessageHandler()` (from
`@tlockney/ganymede-device/webkit`) finds the app's handler, as
ganymede-ui's kernel page does. If the handler is there but `hello`
fails, the kernel starts without `device` and prints one line on stderr
saying why.

## Installing

The package isn't published yet. Install it from git; npm runs its
`prepare` script, which builds `dist/`:

```sh
npm install github:tlockney/ganymede-device
```

Every export resolves to built JavaScript in `dist/` with a `.d.ts`
beside it, so consumers need no TypeScript loader. `npm run build`
builds the same files locally.

## Using it in an app

Add this repository as a Swift package and register the bridge on the
web view that runs kernels, never on one that renders notebook outputs:

```swift
import DeviceBridge

DeviceBridge().register(in: kernelWebView.configuration.userContentController)
```

## Development

```sh
npm ci
npm run check   # type check
npm test        # unit tests; the browser test skips without CDPK_DIR
# The browser test, as CI runs it, against cdp-kernel v0.9.0:
git clone --branch v0.9.0 https://github.com/tlockney/cdp-kernel ../cdp-kernel
(cd ../cdp-kernel && npm ci)
npm i --no-save playwright@1.64.1 && npx playwright install --with-deps chromium
CDPK_DIR=../cdp-kernel node --test test/browser.test.ts
swift test      # the Swift bridge; macOS only
```

On a pull request, and on a push to `main`, CI runs only the jobs its
files can affect
(`scripts/ci-changes.sh`): the `swift` job for `Package.swift` and
`swift/`, `test` and `browser` for the TypeScript side, none for docs
(except the generated `docs/reference.md`, which the `test` job checks).

## Next

The plan's "Where things stand" has the list, and
[#18](https://github.com/tlockney/ganymede-device/issues/18) tracks it.
