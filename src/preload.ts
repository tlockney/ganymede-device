// The preload module for cdp-kernel's browser target (its `preload` option,
// tlockney/cdp-kernel#384). The Worker imports it before the first cell and
// after each restart; it asks the page's host who it is and installs
// `globalThis.device`. With no host, or one that doesn't answer `hello`,
// nothing is installed and cells see no `device`.
//
//   startBrowserKernel({ createWorker, preload: [preloadUrl], host: webkitHost() });

import { createDevice, type DeviceTransport, hello } from "./device.ts";

/** The `host` cdp-kernel's Worker passes to a preload module. */
export interface WorkerHost {
  request(method: string, params: unknown, options?: { signal?: AbortSignal }): Promise<unknown>;
}

export default async function install({ host }: { host: WorkerHost }): Promise<void> {
  const transport: DeviceTransport = { call: (method, params, options) => host.request(method, params, options) };
  let info;
  try {
    info = await hello(transport);
  } catch {
    return;
  }
  Object.defineProperty(globalThis, "device", { value: createDevice(transport, info), configurable: true, writable: false });
}
