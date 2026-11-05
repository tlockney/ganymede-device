# ganymede-device

The `device` API: native features for TypeScript notebooks in the Ganymede
Mac and iPad apps, in the spirit of [Juno's `juno`
module](https://juno.sh/docs/python/juno/). A cell calls
`await device.clipboard.readText()` and the app answers from Swift.

```ts
/// <reference types="@tlockney/ganymede-device/globals" />
if (device?.has("clipboard.readText")) {
  const text = await device.clipboard.readText();
}
```

The design, scope and phases are in [docs/plan.md](docs/plan.md); the
wire format and the Swift side's contract in
[docs/protocol.md](docs/protocol.md).

## Status

Phase 0 is done and Phase 1 is under way. The TypeScript side answers
`hello`, the text and image clipboard, `info`, haptics, `openURL` and
the `ui` dialogs (alert, confirm, prompt, action sheet, date picker),
with bytes crossing the bridge as base64 (docs/protocol.md). It runs in
cdp-kernel's browser Worker through its `preload` and `host` options
([tlockney/cdp-kernel#384](https://github.com/tlockney/cdp-kernel/issues/384)),
and is tested end to end in headless Chromium against a fake Swift
bridge. The Swift `DeviceBridge` answers the same methods; the Mac and
iPad apps in [tlockney/ganymede-ui](https://github.com/tlockney/ganymede-ui)
register it on their hidden kernel web view.

## Layout

- `src/device.ts`: the `device` object over a `DeviceTransport`.
- `src/preload.ts`: the Worker preload module that installs
  `globalThis.device` when the host answers `hello`.
- `src/webkit.ts`: the page's `host` handler, forwarding to
  `webkit.messageHandlers.device`.
- `src/support.ts`: which methods work on-device, remotely and in a
  browser, today and planned; the source for docs and tests.
  `npm run support-table` prints it as the Markdown that ganymede-ui's
  `docs/device.md` embeds.
- `src/globals.ts`: ambient types for cells.
- `Package.swift`, `swift/Sources/DeviceBridge/`: the Swift side, a
  `WKScriptMessageHandlerWithReply` named `device`.

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
# The browser test, as CI runs it, against cdp-kernel v0.7.2:
git clone --branch v0.7.2 https://github.com/tlockney/cdp-kernel ../cdp-kernel
(cd ../cdp-kernel && npm ci)
npm i --no-save playwright@1.64.1 && npx playwright install --with-deps chromium
CDPK_DIR=../cdp-kernel node --test test/browser.test.ts
swift test      # the Swift bridge; macOS only
```

## Next

1. Try a cell's `device.clipboard` calls in the Mac and iPad apps
   (docs/plan.md, Phase 0's exit).
2. Phase 1's no-permission methods.
