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
  return globalThis.device as Device;
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
  await device.info();
  await device.haptics.impact();
  await device.haptics.notification("success");
  await device.haptics.selection();
  await device.openURL("https://example.com");
  assert.deepEqual([...called].sort(), Object.keys(SUPPORT).sort());
});

test("info adds the host's current state to hello, which it can't change", async () => {
  const hello = { platform: "ipados", appVersion: "0.1", model: "iPad13,4", capabilities: ["info"] };
  const current = {
    platform: "macos",
    capabilities: ["everything"],
    isPad: true,
    screen: { width: 1180, height: 820, scale: 2 },
    battery: { level: 0.5, charging: false },
    darkMode: true,
    locale: "en-US",
  };
  const device = createDevice({ call: () => Promise.resolve(current) }, hello);
  assert.deepEqual(await device.info(), { ...current, platform: "ipados", appVersion: "0.1", model: "iPad13,4", capabilities: ["info"] });
});

test("info on a host that doesn't answer it is the hello snapshot, without asking", async () => {
  const transport: DeviceTransport = { call: () => Promise.reject(new Error("asked")) };
  const hello = { platform: "macos", appVersion: "0.1", capabilities: [] };
  assert.deepEqual(await createDevice(transport, hello).info(), hello);
});

test("haptics and openURL send their parameters; a Mac without haptics refuses them itself", async () => {
  const sent: [string, Record<string, unknown>][] = [];
  const transport: DeviceTransport = { call: (method, params) => (sent.push([method, params]), Promise.resolve(null)) };
  const ipad = createDevice(transport, { platform: "ipados", appVersion: "", capabilities: Object.keys(SUPPORT) });
  await ipad.haptics.impact("heavy");
  await ipad.haptics.impact();
  await ipad.haptics.notification("error");
  await ipad.openURL(new URL("https://deno.com/"), { inApp: true });
  await ipad.openURL("mailto:a@example.com");
  assert.deepEqual(sent, [
    ["haptics.impact", { style: "heavy" }],
    ["haptics.impact", { style: "medium" }],
    ["haptics.notification", { type: "error" }],
    ["openURL", { url: "https://deno.com/", inApp: true }],
    ["openURL", { url: "mailto:a@example.com", inApp: false }],
  ]);

  const mac = createDevice(transport, { platform: "macos", appVersion: "", capabilities: ["openURL"] });
  assert.equal(mac.has("haptics.impact"), false);
  await assert.rejects(mac.haptics.selection(), (err) => err instanceof DeviceError && err.code === "unavailable");
  assert.equal(sent.length, 5);
});

test("two kernels' handlers never send Swift the same id, so a cancel names one call", async () => {
  const received = fakeBridge({ "clipboard.readText": () => new Promise(() => {}) });
  const first = webkitHost();
  const second = webkitHost();
  const a = new AbortController();
  const b = new AbortController();
  void first({ method: "clipboard.readText", params: {} }, a.signal).catch(() => {});
  void second({ method: "clipboard.readText", params: {} }, b.signal).catch(() => {});
  const [one, two] = received;
  assert.notEqual(one.id, two.id);
  a.abort();
  assert.deepEqual(received.at(-1), { id: one.id, cancel: true });
  b.abort();
  assert.deepEqual(received.at(-1), { id: two.id, cancel: true });
});

test("a call aborted before it starts never reaches Swift", async () => {
  const received = fakeBridge({ "clipboard.readText": () => ({ result: "x" }) });
  const controller = new AbortController();
  controller.abort();
  await assert.rejects(
    webkitHost()({ method: "clipboard.readText", params: {} }, controller.signal),
    (err: { name?: string; code?: string }) => err.name === "DeviceError" && err.code === "cancelled",
  );
  assert.deepEqual(received, []);
});

/** Runs `fn` with console.error captured. */
async function stderrOf(fn: () => Promise<unknown>): Promise<string[]> {
  const lines: string[] = [];
  const original = console.error;
  console.error = (...args: unknown[]) => void lines.push(args.join(" "));
  try {
    await fn();
  } finally {
    console.error = original;
  }
  return lines;
}

test("a malformed hello installs no device and says why on stderr", async () => {
  fakeBridge({ hello: () => ({ result: { platform: 42 } }) });
  const lines = await stderrOf(installed);
  assert.equal(globalThis.device, undefined);
  assert.equal(lines.length, 1);
  assert.match(lines[0], /hello failed \(failed\): .*malformed/);
});

test("a bridge error on hello is reported on stderr", async () => {
  fakeBridge({ hello: () => ({ error: { code: "denied", message: "nope" } }) });
  const lines = await stderrOf(installed);
  assert.equal(globalThis.device, undefined);
  assert.deepEqual(lines, ["device: no device API, hello failed (denied): nope"]);
});

test("outside the app, the preload is quiet", async () => {
  globalThis.webkit = undefined;
  assert.deepEqual(await stderrOf(installed), []);
});
