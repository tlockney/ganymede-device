// The whole path short of a real Worker and a real WKWebView: the preload
// module, a stand-in for cdp-kernel's Worker host channel, webkitHost, and a
// fake Swift DeviceBridge behind `webkit.messageHandlers.device`.
// test/host-transport.test.ts runs these again with installHostDevice and a
// host-function transport (an embedded engine's) over the same fake bridge.
import { test } from "node:test";
import assert from "node:assert/strict";
import install, { type WorkerHost } from "../src/preload.ts";
import { webkitHost } from "../src/webkit.ts";
import { installHostDevice } from "../src/host.ts";
import { createDevice, type Device, DeviceError, type DeviceTransport, MAX_BINARY_BYTES, SUPPORT, supportTable, unavailableDevice } from "../src/mod.ts";
import { decodeBase64, decodeBinary, encodeBase64, encodeBinary } from "../src/binary.ts";

type Message = { id: number; owner?: number; method?: string; params?: Record<string, unknown>; cancel?: true; release?: true };

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

/** Set by test/host-transport.test.ts: install through an engine's host function instead. */
const viaHostFunction = (globalThis as { deviceTestTransport?: string }).deviceTestTransport === "host";

/** What Swift's `__ganymedeDevice` does: JSON text to the same bridge and back. */
async function hostFunction(message: string): Promise<string> {
  const handler = globalThis.webkit?.messageHandlers.device;
  if (!handler) return JSON.stringify({ error: { code: "unavailable", message: "no bridge" } });
  return JSON.stringify((await handler.postMessage(JSON.parse(message))) ?? null);
}

async function installed(): Promise<Device> {
  delete (globalThis as { device?: unknown }).device;
  if (viaHostFunction) await installHostDevice(hostFunction);
  else await install({ host: workerHost() });
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
  // The host lists `on` as the stream it reads.
  const capabilities = [...Object.keys(SUPPORT).filter((m) => m !== "on"), "events.watch"];
  const device = createDevice(transport, { platform: "test", appVersion: "", capabilities });
  await device.clipboard.readText();
  await device.clipboard.writeText("");
  await device.clipboard.readImage();
  await device.clipboard.writeImage(new Uint8Array());
  await device.info();
  await device.haptics.impact();
  await device.haptics.notification("success");
  await device.haptics.selection();
  await device.openURL("https://example.com");
  await device.ui.alert("");
  await device.ui.confirm("");
  await device.ui.prompt("");
  await device.ui.actionSheet("", ["a"]);
  await device.ui.pickDate();
  await device.share({ text: "t" });
  await device.preview([{ name: "a.txt", data: new Uint8Array([1]) }]);
  await device.files.pick();
  await device.files.export(new Uint8Array([1]), { name: "a.txt" });
  await device.photos.pick();
  await device.photos.save(new Uint8Array([1]));
  await device.sound.play(new Uint8Array([1]));
  await device.sound.player(new Uint8Array([1])).catch(() => {}); // null isn't a player; the call is what counts
  await device.notifications.schedule("b", { delay: 1 }).catch(() => {}); // null isn't an id
  await device.notifications.pending().catch(() => {});
  await device.notifications.cancel("x");
  await device.notifications.cancelAll();
  await device.location.current().catch(() => {}); // null isn't a fix
  await device.location.watch().next().catch(() => {}); // null isn't a stream
  await device.location.geocode("Paris").catch(() => {});
  await device.location.reverseGeocode({ latitude: 0, longitude: 0 }).catch(() => {});
  await device.motion.watch().next().catch(() => {}); // null isn't a stream
  await device.motion.latest().catch(() => {}); // null isn't a sample
  await device.contacts.search("a").catch(() => {}); // null isn't a list
  await device.contacts.get("x");
  await device.contacts.all().catch(() => {});
  await device.contacts.add({ givenName: "a" }).catch(() => {}); // null isn't an id
  await device.contacts.delete("x").catch(() => {}); // null isn't a boolean
  await device.camera.capture();
  await device.reminders.calendars().catch(() => {}); // null isn't a list
  await device.reminders.list().catch(() => {});
  await device.reminders.add({ title: "a" }).catch(() => {});
  await device.reminders.complete("x").catch(() => {});
  await device.reminders.uncomplete("x").catch(() => {});
  await device.reminders.delete("x").catch(() => {});
  await device.bluetooth.scan().next().catch(() => {}); // null isn't a stream
  await device.bluetooth.known([]).catch(() => {}); // null isn't a list
  await device.bluetooth.connect("6E400001-B5A3-F393-E0A9-E50E24DCCA9E").catch(() => {}); // null isn't a peripheral
  await device.folders.pick(); // null: cancelled
  await device.folders.list().catch(() => {}); // null isn't a list
  await device.output({ text: "a" });
  await device.widget.update("a", {});
  const quiet = console.error;
  console.error = () => {}; // null isn't a stream
  device.on("locale", () => {});
  await new Promise((done) => setTimeout(done, 0));
  console.error = quiet;
  // `on` reads the `events.watch` stream.
  assert.deepEqual([...called].map((m) => (m === "events.watch" ? "on" : m)).sort(), Object.keys(SUPPORT).sort());
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
  // Each call encodes its params before posting.
  await new Promise((resolve) => setTimeout(resolve, 0));
  const [one, two] = received;
  assert.notEqual(one.id, two.id);
  a.abort();
  assert.deepEqual(received.at(-1), { id: one.id, cancel: true });
  b.abort();
  assert.deepEqual(received.at(-1), { id: two.id, cancel: true });
});

test("each kernel's handler names its owner on every call, and release names it too", async () => {
  const received = fakeBridge({ "clipboard.readText": () => ({ result: "x" }) });
  const first = webkitHost();
  const second = webkitHost();
  assert.notEqual(first.owner, second.owner);
  const signal = new AbortController().signal;
  await first({ method: "clipboard.readText", params: {} }, signal);
  await second({ method: "clipboard.readText", params: {} }, signal);
  assert.deepEqual(received.map((m) => m.owner), [first.owner, second.owner]);
  first.release();
  assert.deepEqual(received.at(-1), { owner: first.owner, release: true });
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

const PNG = new Uint8Array([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0, 255]);
const IMAGE_HELLO = { result: { platform: "macos", appVersion: "0.1", capabilities: ["clipboard.readImage", "clipboard.writeImage"] } };

test("clipboard images cross the WebKit hop as base64 and arrive as bytes", async () => {
  let clipboard: string | null = null;
  const received = fakeBridge({
    hello: () => IMAGE_HELLO,
    "clipboard.readImage": () => ({ result: clipboard === null ? null : { base64: clipboard } }),
    "clipboard.writeImage": (p) => ((clipboard = (p.image as { base64: string }).base64), { result: null }),
  });
  const device = await installed();
  assert.equal(await device.clipboard.readImage(), null);

  await device.clipboard.writeImage(PNG);
  assert.deepEqual(received.at(-1)!.params, { image: { base64: Buffer.from(PNG).toString("base64") } });
  const read = await device.clipboard.readImage();
  assert.ok(read instanceof Uint8Array);
  assert.deepEqual([...read], [...PNG]);

  // An ArrayBuffer and a Blob go the same way.
  await device.clipboard.writeImage(PNG.slice().buffer);
  assert.deepEqual([...(await device.clipboard.readImage())!], [...PNG]);
  await device.clipboard.writeImage(new Blob([PNG]));
  assert.deepEqual([...(await device.clipboard.readImage())!], [...PNG]);
});

test("a call aborted while its bytes are encoded never reaches Swift", async () => {
  const received = fakeBridge({ "clipboard.writeImage": () => ({ result: null }) });
  const controller = new AbortController();
  const pending = webkitHost()({ method: "clipboard.writeImage", params: { image: new Blob([PNG]) } }, controller.signal);
  controller.abort();
  await assert.rejects(pending, (err: Error & { code?: string }) => err.code === "cancelled");
  assert.deepEqual(received, []);
});

test("a view of part of a buffer is sent as its own bytes", async () => {
  const { toBytes } = await import("../src/binary.ts");
  const big = new Uint8Array(1024).fill(7);
  const part = await toBytes(big.subarray(10, 20));
  assert.equal(part.buffer.byteLength, 10);
  assert.deepEqual([...part], new Array(10).fill(7));
  const whole = await toBytes(big);
  assert.equal(whole, big, "a whole buffer isn't copied");
});

test("writeImage on a host without it is unavailable, whatever it was given", async () => {
  fakeBridge({ hello: () => HELLO });
  const device = await installed();
  await assert.rejects(device.clipboard.writeImage("not bytes" as unknown as Uint8Array), (err) => err instanceof DeviceError && err.code === "unavailable");
});

test("a binary value over the limit fails before it reaches Swift", async () => {
  const received = fakeBridge({ hello: () => IMAGE_HELLO, "clipboard.writeImage": () => ({ result: null }) });
  const device = await installed();
  const big = new Uint8Array(MAX_BINARY_BYTES + 1);
  await assert.rejects(device.clipboard.writeImage(big), (err) => err instanceof DeviceError && err.code === "failed" && /limited/.test(err.message));
  await assert.rejects(device.clipboard.writeImage(new Blob([big])), (err) => err instanceof DeviceError && err.code === "failed");
  // And at the WebKit hop, for a caller that skipped device.ts.
  await assert.rejects(webkitHost()({ method: "clipboard.writeImage", params: { image: big } }, new AbortController().signal), (err: Error & { code?: string }) => err.code === "failed");
  assert.deepEqual(received.map((m) => m.method), ["hello"]);
});

test("a result over the limit, or malformed base64, fails", async () => {
  const tooLong = "A".repeat(Math.ceil((MAX_BINARY_BYTES + 3) / 3) * 4);
  fakeBridge({
    hello: () => IMAGE_HELLO,
    "clipboard.readImage": () => ({ result: { base64: tooLong } }),
  });
  const device = await installed();
  await assert.rejects(device.clipboard.readImage(), (err) => err instanceof DeviceError && err.code === "failed");
  assert.throws(() => decodeBase64("not base64!"), (err) => err instanceof DeviceError && err.code === "failed");
});

test("encodeBinary and decodeBinary reach nested values and leave the rest alone", async () => {
  const encoded = await encodeBinary({ a: [PNG], b: { c: new Uint16Array([1]) }, d: "x", e: null, f: 2 });
  assert.deepEqual(encoded, { a: [{ base64: encodeBase64(PNG) }], b: { c: { base64: "AQA=" } }, d: "x", e: null, f: 2 });
  const decoded = decodeBinary({ a: [{ base64: encodeBase64(PNG) }], keep: { base64: "AQA=", name: "two keys" } }) as {
    a: Uint8Array[];
    keep: unknown;
  };
  assert.deepEqual([...decoded.a[0]], [...PNG]);
  assert.deepEqual(decoded.keep, { base64: "AQA=", name: "two keys" });
  // Larger than one String.fromCharCode chunk, through the fallback too.
  const bytes = new Uint8Array(100_000).map((_, i) => i % 251);
  assert.deepEqual([...decodeBase64(encodeBase64(bytes))], [...bytes]);
});

test("supportTable has one row per method, and a note line per note", () => {
  const table = supportTable();
  const rows = table.split("\n").filter((l) => l.startsWith("| `device."));
  assert.deepEqual(
    rows.map((r) => /`device\.([\w.]+)/.exec(r)![1]),
    Object.values(SUPPORT).map((r) => /^[\w.]+/.exec(r.call)![0]),
  );
  assert.deepEqual(
    Object.values(SUPPORT).map((r) => /^[\w.]+/.exec(r.call)![0]),
    Object.keys(SUPPORT),
    "each row's call names its own method",
  );
  assert.equal(table.split("\n").filter((l) => l.startsWith("- `device.")).length, Object.values(SUPPORT).filter((r) => "note" in r).length);
});

test("supportTable says what ships, what's planned and what can't work", () => {
  const table = supportTable({
    a: { call: "a()", returns: "nothing", onDevice: "yes", devices: "iPhone", remote: "planned", browser: "no" },
    b: { call: "b()", returns: "nothing", onDevice: "planned", remote: "no", browser: "planned", browserClick: true, note: "Why." },
  });
  assert.equal(
    table,
    [
      "| Method | Returns | In the app | Remote kernel | Browser |",
      "| --- | --- | --- | --- | --- |",
      "| `device.a()` | nothing | iPhone | planned | no |",
      "| `device.b()` | nothing | planned | no | planned, after a click |",
      "",
      "- `device.b()`: Why.",
    ].join("\n"),
  );
});

test("dialogs send what the cell asked and return what the person chose", async () => {
  const sent: [string, Record<string, unknown>][] = [];
  const answers: Record<string, unknown> = {
    "ui.alert": null,
    "ui.confirm": true,
    "ui.prompt": "Io",
    "ui.actionSheet": 1,
    "ui.pickDate": "2026-11-04T20:30:00.250Z",
  };
  const transport: DeviceTransport = { call: (method, params) => (sent.push([method, params]), Promise.resolve(answers[method])) };
  const device = createDevice(transport, { platform: "macos", appVersion: "", capabilities: Object.keys(SUPPORT) });
  const min = new Date("2026-01-01T00:00:00Z");

  assert.equal(await device.ui.alert("Done", { title: "Export" }), undefined);
  assert.equal(await device.ui.confirm("Delete?", { destructive: true }), true);
  assert.equal(await device.ui.prompt("Name?", { placeholder: "Alex", secure: true }), "Io");
  assert.equal(await device.ui.actionSheet("Quality", ["Low", "High"], { cancel: "Never mind", destructive: 1 }), 1);
  const picked = await device.ui.pickDate({ mode: "date", min });
  assert.ok(picked instanceof Date);
  assert.equal(picked.toISOString(), "2026-11-04T20:30:00.250Z");
  assert.deepEqual(sent, [
    ["ui.alert", { message: "Done", title: "Export" }],
    ["ui.confirm", { message: "Delete?", destructive: true }],
    ["ui.prompt", { message: "Name?", secure: true, placeholder: "Alex" }],
    ["ui.actionSheet", { title: "Quality", options: ["Low", "High"], cancel: "Never mind", destructive: 1 }],
    ["ui.pickDate", { mode: "date", min: "2026-01-01T00:00:00.000Z" }],
  ]);
});

test("dismissing a dialog is null or false, not an error", async () => {
  const transport: DeviceTransport = { call: () => Promise.resolve(null) };
  const device = createDevice(transport, { platform: "ipados", appVersion: "", capabilities: Object.keys(SUPPORT) });
  assert.equal(await device.ui.confirm("Sure?"), false);
  assert.equal(await device.ui.prompt("Name?"), null);
  assert.equal(await device.ui.actionSheet("Pick", ["a"]), null);
  assert.equal(await device.ui.pickDate(), null);
});

test("dialogs refuse bad input before asking, and odd answers", async () => {
  let asked = 0;
  const transport: DeviceTransport = { call: (method) => (asked++, Promise.resolve(method === "ui.actionSheet" ? 7 : "not a date")) };
  const device = createDevice(transport, { platform: "macos", appVersion: "", capabilities: Object.keys(SUPPORT) });
  await assert.rejects(device.ui.actionSheet("Pick", []), (err) => err instanceof DeviceError && err.code === "failed");
  await assert.rejects(device.ui.pickDate({ min: new Date("nope") }), (err) => err instanceof DeviceError && err.code === "failed");
  assert.equal(asked, 0);
  assert.equal(await device.ui.actionSheet("Pick", ["a", "b"]), null, "an index out of range is no choice");
  await assert.rejects(device.ui.pickDate(), (err) => err instanceof DeviceError && err.code === "failed" && /can't read/.test(err.message));
});

test("an open dialog that is aborted is cancelled in Swift, and the call rejects cancelled", async () => {
  const received = fakeBridge({
    hello: () => ({ result: { platform: "macos", appVersion: "0.1", capabilities: ["ui.prompt"] } }),
    // The person never answers.
    "ui.prompt": () => new Promise(() => {}),
  });
  const device = await installed();
  const controller = new AbortController();
  const pending = device.ui.prompt("Name?", { signal: controller.signal });
  await new Promise((resolve) => setTimeout(resolve, 0));
  controller.abort();
  await assert.rejects(pending, (err) => err instanceof DeviceError && err.code === "cancelled");
  const prompt = received.find((m) => m.method === "ui.prompt")!;
  assert.deepEqual(prompt.params, { message: "Name?", secure: false });
  assert.deepEqual(received.at(-1), { id: prompt.id, cancel: true });
});

test("a timeout signal's abort is a timeout, and also closes the dialog", async () => {
  const received = fakeBridge({
    hello: () => ({ result: { platform: "macos", appVersion: "0.1", capabilities: ["ui.confirm"] } }),
    "ui.confirm": () => new Promise(() => {}),
  });
  const device = await installed();
  // Node doesn't keep the process alive for AbortSignal.timeout's timer.
  const alive = setTimeout(() => {}, 1000);
  await assert.rejects(device.ui.confirm("Sure?", { signal: AbortSignal.timeout(10) }), (err) => err instanceof DeviceError && err.code === "timeout");
  clearTimeout(alive);
  const confirm = received.find((m) => m.method === "ui.confirm")!;
  assert.deepEqual(received.at(-1), { id: confirm.id, cancel: true });
});

test("share sends text, url and named files, and says whether it was sent", async () => {
  const sent: [string, Record<string, unknown>][] = [];
  let answer: unknown = true;
  const transport: DeviceTransport = { call: (method, params) => (sent.push([method, params]), Promise.resolve(answer)) };
  const device = createDevice(transport, { platform: "ios", appVersion: "", capabilities: ["share", "preview"] });
  const file = new File([new Uint8Array([1, 2])], "plot.png", { type: "image/png" });
  assert.equal(await device.share({ text: "hi", url: new URL("https://deno.com/"), files: [file, { name: "a.csv", data: new Uint8Array([3]) }] }), true);
  assert.deepEqual(sent[0], [
    "share",
    {
      text: "hi",
      url: "https://deno.com/",
      files: [
        { name: "plot.png", data: new Uint8Array([1, 2]) },
        { name: "a.csv", data: new Uint8Array([3]) },
      ],
    },
  ]);
  answer = null;
  assert.equal(await device.share({ text: "hi" }), false, "a dismissed sheet is false, not an error");
  assert.deepEqual(sent[1], ["share", { text: "hi", files: [] }]);
  answer = null;
  assert.equal(await device.preview([file]), undefined);
  assert.deepEqual(sent[2], ["preview", { files: [{ name: "plot.png", data: new Uint8Array([1, 2]) }] }]);
});

test("share and preview refuse bad files before asking the host", async () => {
  const sent: string[] = [];
  const transport: DeviceTransport = { call: (method) => (sent.push(method), Promise.resolve(null)) };
  const device = createDevice(transport, { platform: "ios", appVersion: "", capabilities: ["share", "preview"] });
  const failed = (err: unknown) => err instanceof DeviceError && err.code === "failed";
  await assert.rejects(device.share({}), failed);
  await assert.rejects(device.share({ files: [] }), failed);
  await assert.rejects(device.preview([]), failed);
  for (const name of ["", "a/b", "..", "a\\b"]) {
    await assert.rejects(device.preview([{ name, data: new Uint8Array([1]) }]), failed, JSON.stringify(name));
  }
  const half = new Uint8Array(MAX_BINARY_BYTES / 2 + 1);
  await assert.rejects(device.share({ files: [{ name: "a", data: half }, { name: "b", data: half }] }), failed, "files together over the limit");
  assert.deepEqual(sent, []);
  const none = createDevice(transport, { platform: "macos", appVersion: "", capabilities: [] });
  await assert.rejects(none.share({ text: "x" }), (err) => err instanceof DeviceError && err.code === "unavailable");
});

test("files.pick and photos.pick answer Files, and [] when cancelled", async () => {
  const sent: [string, Record<string, unknown>][] = [];
  let answer: unknown = [
    { name: "a.csv", type: "text/csv", data: new Uint8Array([1, 2]) },
    { name: "b.bin", data: new Uint8Array([3]) },
  ];
  const transport: DeviceTransport = { call: (method, params) => (sent.push([method, params]), Promise.resolve(answer)) };
  const device = createDevice(transport, { platform: "ios", appVersion: "", capabilities: ["files.pick", "photos.pick"] });
  const files = await device.files.pick({ types: ["text/csv", ".parquet"], multiple: true });
  assert.deepEqual(sent[0], ["files.pick", { multiple: true, types: ["text/csv", ".parquet"] }]);
  assert.deepEqual(
    files.map((f) => [f.name, f.type, f.size]),
    [
      ["a.csv", "text/csv", 2],
      ["b.bin", "", 1],
    ],
  );
  assert.deepEqual([...new Uint8Array(await files[0].arrayBuffer())], [1, 2]);
  answer = [];
  assert.deepEqual(await device.photos.pick({ limit: 0 }), []);
  assert.deepEqual(sent[1], ["photos.pick", { limit: 0 }]);
  answer = null;
  assert.deepEqual(await device.photos.pick(), [], "a dismissed picker is [], not an error");
  assert.deepEqual(sent[2], ["photos.pick", { limit: 1 }]);
  answer = [{ name: "x" }];
  await assert.rejects(device.files.pick(), (err) => err instanceof DeviceError && err.code === "failed");
});

test("files.export sends named bytes and says whether they were saved", async () => {
  const sent: [string, Record<string, unknown>][] = [];
  let answer: unknown = true;
  const transport: DeviceTransport = { call: (method, params) => (sent.push([method, params]), Promise.resolve(answer)) };
  const device = createDevice(transport, { platform: "macos", appVersion: "", capabilities: ["files.export", "files.pick", "photos.pick"] });
  assert.equal(await device.files.export(new Blob(["hi"]), { name: "out.txt" }), true);
  assert.deepEqual(sent[0], ["files.export", { name: "out.txt", data: new TextEncoder().encode("hi") }]);
  answer = null;
  assert.equal(await device.files.export(new Uint8Array([1]), { name: "out.txt" }), false);
  const failed = (err: unknown) => err instanceof DeviceError && err.code === "failed";
  for (const name of ["", "a/b", ".."]) {
    await assert.rejects(device.files.export(new Uint8Array([1]), { name }), failed, JSON.stringify(name));
  }
  await assert.rejects(device.files.export(new Uint8Array(MAX_BINARY_BYTES + 1), { name: "big" }), failed);
  await assert.rejects(device.files.pick({ types: ["", "x"] }), failed);
  await assert.rejects(device.photos.pick({ limit: -1 }), failed);
  await assert.rejects(device.photos.pick({ limit: 1.5 }), failed);
  assert.equal(sent.length, 2);
  const none = createDevice(transport, { platform: "macos", appVersion: "", capabilities: [] });
  await assert.rejects(none.files.export(new Uint8Array([1]), { name: "a" }), (err) => err instanceof DeviceError && err.code === "unavailable");
});

test("sound.play sends the bytes and volume, and checks them first", async () => {
  const sent: [string, Record<string, unknown>][] = [];
  const transport: DeviceTransport = { call: (method, params) => (sent.push([method, params]), Promise.resolve(null)) };
  const device = createDevice(transport, { platform: "macos", appVersion: "", capabilities: ["sound.play"] });
  await device.sound.play(new Blob([new Uint8Array([1, 2])]), { volume: 0.5 });
  assert.deepEqual(sent, [["sound.play", { data: new Uint8Array([1, 2]), volume: 0.5 }]]);
  const failed = (err: unknown) => err instanceof DeviceError && err.code === "failed";
  await assert.rejects(device.sound.play(new Uint8Array()), failed, "no bytes");
  await assert.rejects(device.sound.play(new Uint8Array([1]), { volume: 2 }), failed);
  await assert.rejects(device.sound.play(new Uint8Array([1]), { volume: NaN }), failed);
  await assert.rejects(device.sound.play(new Uint8Array(MAX_BINARY_BYTES + 1)), failed);
  assert.equal(sent.length, 1);
});

test("a sound player controls the host's player by id and closes once", async () => {
  const sent: [string, Record<string, unknown>][] = [];
  const transport: DeviceTransport = {
    call(method, params) {
      sent.push([method, params]);
      if (method === "sound.player") return Promise.resolve({ player: 7, duration: 2.5 });
      if (method === "sound.control") return Promise.resolve({ playing: params.action === "play", time: 1, duration: 2.5 });
      return Promise.resolve(null);
    },
  };
  const capabilities = ["sound.player", "sound.control", "sound.close"];
  const device = createDevice(transport, { platform: "ios", appVersion: "", capabilities });
  // What `await using player = …` does; Node 22 can't parse that yet.
  {
    const player = await device.sound.player(new Uint8Array([1]));
    assert.equal(player.duration, 2.5);
    assert.deepEqual(await player.play(), { playing: true, time: 1, duration: 2.5 });
    assert.deepEqual(await player.pause(), { playing: false, time: 1, duration: 2.5 });
    await player.seek(1.25);
    await player.setVolume(0.2);
    await player.stop();
    await player.state();
    await assert.rejects(player.seek(-1), (err) => err instanceof DeviceError && err.code === "failed");
    await assert.rejects(player.setVolume(1.5), (err) => err instanceof DeviceError && err.code === "failed");
    await player[Symbol.asyncDispose]();
  }
  assert.deepEqual(
    sent.map(([method, params]) => [method, params.action, params.time ?? params.volume]),
    [
      ["sound.player", undefined, undefined],
      ["sound.control", "play", undefined],
      ["sound.control", "pause", undefined],
      ["sound.control", "seek", 1.25],
      ["sound.control", "state", 0.2],
      ["sound.control", "stop", undefined],
      ["sound.control", "state", undefined],
      ["sound.close", undefined, undefined],
    ],
  );
  assert.ok(sent.slice(1).every(([, params]) => params.player === 7));
  const player = await device.sound.player(new Uint8Array([1]));
  assert.equal(player.closed, false);
  await player.close();
  assert.equal(player.closed, true);
  await player.close();
  assert.equal(sent.filter(([m]) => m === "sound.close").length, 2, "a second close sends nothing");
  await assert.rejects(player.play(), (err) => err instanceof DeviceError && err.code === "failed");
});

test("setVolume needs a volume", async () => {
  const sent: string[] = [];
  const transport: DeviceTransport = {
    call(method) {
      sent.push(method);
      return Promise.resolve(method === "sound.player" ? { player: 1, duration: 1 } : { playing: false, time: 0, duration: 1 });
    },
  };
  const device = createDevice(transport, { platform: "macos", appVersion: "", capabilities: ["sound.player", "sound.control", "sound.close"] });
  const player = await device.sound.player(new Uint8Array([1]));
  await assert.rejects(player.setVolume(undefined as unknown as number), (err) => err instanceof DeviceError && err.code === "failed");
  assert.deepEqual(sent, ["sound.player"]);
});
