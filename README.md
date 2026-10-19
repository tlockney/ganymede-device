# ganymede-device

The `device` API: native features for TypeScript notebooks in the Ganymede
Mac and iPad apps, in the spirit of [Juno's `juno`
module](https://juno.sh/docs/python/juno/). A cell calls
`await device.clipboard.readText()` and the app answers from Swift.

```ts
/// <reference types="@tlockney/ganymede-device/globals" />
if (device.has("clipboard.readText")) {
  const text = await device.clipboard.readText();
}
```

The design, scope and phases are in [docs/plan.md](docs/plan.md); the
wire format and the Swift side's contract in
[docs/protocol.md](docs/protocol.md).

## Status

Phase 0: proving the path. Done here: the TypeScript side for `hello`,
`clipboard.readText` and `clipboard.writeText`, running in cdp-kernel's
browser Worker through its `preload` and `host` options
([tlockney/cdp-kernel#384](https://github.com/tlockney/cdp-kernel/issues/384)),
and tested end to end in headless Chromium against a fake Swift bridge.
Not done: the Swift `DeviceBridge` and a minimal Mac app that loads it,
which need Xcode.

## Layout

- `src/device.ts`: the `device` object over a `DeviceTransport`.
- `src/preload.ts`: the Worker preload module that installs
  `globalThis.device` when the host answers `hello`.
- `src/webkit.ts`: the page's `host` handler, forwarding to
  `webkit.messageHandlers.device`.
- `src/support.ts`: which methods work on-device, remotely and in a
  browser; the source for docs and tests.
- `src/globals.ts`: ambient types for cells.

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
});
```

`npm run build` writes `dist/preload.js` and `dist/webkit.js`.

## Development

```sh
npm ci
npm run check   # type check
npm test        # unit tests; the browser test skips without the setup below
CDPK_DIR=../cdp-kernel npm i --no-save playwright && node --test test/browser.test.ts
```

## Next

1. A Swift package with `DeviceBridge` answering `hello` and the two
   clipboard methods, and a minimal SwiftUI Mac app that loads
   ganymede-ui with the kernel in a hidden WebView (docs/plan.md,
   Phase 0).
2. Phase 1's no-permission methods.
