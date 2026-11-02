// The preload module for cdp-kernel's browser target (its `preload` option,
// tlockney/cdp-kernel#384). The Worker imports it before the first cell and
// after each restart; it asks the page's host who it is and installs
// `globalThis.device`. With no host, or one that doesn't answer `hello`,
// nothing is installed and cells see no `device`. Only a page outside the
// app (no WebKit handler: `unavailable`) stays quiet; any other failure,
// such as a malformed reply or a bridge error, is one line on stderr, so a
// Swift bug doesn't look like "not in the app".
//
//   startBrowserKernel({ createWorker, preload: [preloadUrl], host: webkitHost() });

import { createDevice, type DeviceTransport, hello } from "./device.ts";
import { DeviceError } from "./errors.ts";

/** The `host` cdp-kernel's Worker passes to a preload module. */
export interface WorkerHost {
  request(method: string, params: unknown, options?: { signal?: AbortSignal }): Promise<unknown>;
}

export default async function install({ host }: { host: WorkerHost }): Promise<void> {
  const transport: DeviceTransport = { call: (method, params, options) => host.request(method, params, options) };
  let info;
  try {
    info = await hello(transport);
  } catch (err) {
    const error = DeviceError.from(err);
    if (error.code !== "unavailable") console.error(`device: no device API, hello failed (${error.code}): ${error.message}`);
    return;
  }
  Object.defineProperty(globalThis, "device", { value: createDevice(transport, info), configurable: true, writable: false });
}
