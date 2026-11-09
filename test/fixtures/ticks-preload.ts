// A second preload for test/browser.test.ts: `globalThis.ticks(options)`
// opens the fake bridge's test-only `test.ticks` stream through the Worker's
// host channel, as a `device` namespace that streams will.
import { openStream, type StreamOptions } from "../../src/stream.ts";
import type { WorkerHost, WorkerJupyter } from "../../src/preload.ts";

export default function install({ host, jupyter }: { host: WorkerHost; jupyter?: WorkerJupyter }): void {
  const transport = { call: (method: string, params: Record<string, unknown>, options?: { signal?: AbortSignal }) => host.request(method, params, options) };
  Object.assign(globalThis, {
    ticks: (options: StreamOptions = {}) => openStream<number>(transport, "test.ticks", {}, { ...options, cellSignal: jupyter?.signal }),
  });
}
