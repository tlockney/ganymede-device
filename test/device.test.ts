// The whole path short of a real Worker and a real WKWebView: the preload
// module, a stand-in for cdp-kernel's Worker host channel, webkitHost, and a
// fake Swift DeviceBridge behind `webkit.messageHandlers.device`.
import { test } from "node:test";
import assert from "node:assert/strict";
import install, { type WorkerHost } from "../src/preload.ts";
import { webkitHost } from "../src/webkit.ts";
import { createDevice, type Device, DeviceError, type DeviceTransport, SUPPORT, unavailableDevice } from "../src/mod.ts";

type Message = { id: number; method?: string; params?: Record<string, unknown>; cancel?: true };

/** A fake Swift bridge: answers by method, records what it was sent. */
function fakeBridge(answers: Record<string, (params: Record<string, unknown>) => unknown>) {
  const received: Message[] = [];
  globalThis.webkit = {
    messageHandlers: {
      device: {
        async postMessage(message: unknown) {
          const msg = message as Message;
          received.push(msg);
          if (msg.cancel) return null;
          const answer = answers[msg.method ?? ""];
          if (!answer) return { error: { code: "unavailable", message: `no ${msg.method}` } };
          return await answer(msg.params ?? {});
        },
      },
    },
  };
  return received;
}

/** What cdp-kernel's Worker and BrowserTarget do between preload and the page's handler (#384). */
function workerHost(): WorkerHost {
  const handler = webkitHost();
  return {
    async request(method, params, options = {}) {
      const controller = new AbortController();
      options.signal?.addEventListener("abort", () => controller.abort());
      if (options.signal?.aborted) throw options.signal.reason;
      return await Promise.race([
        handler({ method, params }, controller.signal).catch((err) => {
          throw Object.assign(new Error(err.message), { name: err.name, code: err.code });
        }),
        new Promise((_, reject) => options.signal?.addEventListener("abort", () => reject(options.signal!.reason))),
      ]);
    },
  };
}

const HELLO = { result: { platform: "macos", appVersion: "0.1", capabilities: ["clipboard.readText", "clipboard.writeText"] } };

async function installed(): Promise<Device> {
  delete (globalThis as { device?: unknown }).device;
  await install({ host: workerHost() });
  return globalThis.device;
}

test("the preload installs device from the host's hello, and calls reach Swift", async () => {
  let clipboard = "from the Mac";
  const received = fakeBridge({
    hello: () => HELLO,
    "clipboard.readText": () => ({ result: clipboard }),
    "clipboard.writeText": (p) => ((clipboard = String(p.text)), { result: null }),
  });
  const device = await installed();
  assert.equal((await device.info()).platform, "macos");
  assert.equal(device.has("clipboard.readText"), true);
  assert.equal(device.has("location.current"), false);

  assert.equal(await device.clipboard.readText(), "from the Mac");
  await device.clipboard.writeText("hello");
  assert.equal(clipboard, "hello");
  assert.deepEqual(received.map((m) => m.method), ["hello", "clipboard.readText", "clipboard.writeText"]);
  assert.deepEqual(received[2].params, { text: "hello" });
});

test("no WebKit handler: no device is installed", async () => {
  globalThis.webkit = undefined;
  assert.equal(await installed(), undefined);
});

test("Swift's error codes arrive as DeviceErrors", async () => {
  fakeBridge({ hello: () => HELLO, "clipboard.readText": () => ({ error: { code: "denied", message: "paste refused" } }) });
  const device = await installed();
  await assert.rejects(device.clipboard.readText(), (err) => err instanceof DeviceError && err.code === "denied" && err.message === "paste refused");
});

test("a method the host didn't announce is unavailable without asking it", async () => {
  const received = fakeBridge({ hello: () => ({ result: { platform: "ipados", appVersion: "0.1", capabilities: [] } }) });
  const device = await installed();
  await assert.rejects(device.clipboard.readText(), (err) => err instanceof DeviceError && err.code === "unavailable");
  assert.equal(received.length, 1);
});

test("aborting a call cancels it in Swift", async () => {
  const received = fakeBridge({ hello: () => HELLO, "clipboard.readText": () => new Promise(() => {}) });
  const device = await installed();
  const controller = new AbortController();
  const pending = device.clipboard.readText({ signal: controller.signal });
  await new Promise((resolve) => setTimeout(resolve, 0));
  controller.abort();
  await assert.rejects(pending, (err) => err instanceof DeviceError && err.code === "cancelled");
  const read = received.find((m) => m.method === "clipboard.readText")!;
  assert.deepEqual(received.at(-1), { id: read.id, cancel: true });
});

test("an imported device on a kernel with no host rejects every call", async () => {
  const device = unavailableDevice();
  assert.equal(device.has("clipboard.readText"), false);
  await assert.rejects(device.clipboard.writeText("x"), (err) => err instanceof DeviceError && err.code === "unavailable");
});

test("the support matrix has a row for every method the device calls, and no others", async () => {
  const called = new Set<string>();
  const transport: DeviceTransport = { call: (method) => (called.add(method), Promise.resolve(null)) };
  const device = createDevice(transport, { platform: "test", appVersion: "", capabilities: Object.keys(SUPPORT) });
  await device.clipboard.readText();
  await device.clipboard.writeText("");
  assert.deepEqual([...called].sort(), Object.keys(SUPPORT).sort());
});
