// The browser fallback (src/browser.ts) against stand-ins for the web APIs
// it uses, and through answerDevice's subset filter.
import { test } from "node:test";
import assert from "node:assert/strict";
import { encodeBase64 } from "../src/binary.ts";
import { type BrowserEnv, browserCapabilities, browserForward, type Click, type ClickRequest } from "../src/browser.ts";
import { REMOTE_METHODS } from "../src/comm.ts";
import { SUPPORT } from "../src/support.ts";

const PNG = new Uint8Array([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 1, 2, 3]);
const b64 = (bytes: Uint8Array) => ({ base64: encodeBase64(bytes) });

/** A fake input or link element: records what was set, and what clicking it did. */
class FakeElement {
  type = "";
  accept = "";
  multiple = false;
  href = "";
  download = "";
  style: Record<string, string> = {};
  files: File[] | null = null;
  removed = false;
  listeners = new Map<string, () => void>();
  onClick: (el: FakeElement) => void = () => {};
  addEventListener(type: string, fn: () => void) {
    this.listeners.set(type, fn);
  }
  click() {
    this.onClick(this);
  }
  remove() {
    this.removed = true;
  }
  fire(type: string) {
    this.listeners.get(type)?.();
  }
}

/** A browser with every API this uses, recording what each was given. */
function fakeBrowser() {
  let urls = 0;
  const log = {
    clipboardText: "",
    clipboardItems: [] as unknown[],
    opened: [] as unknown[][],
    shared: [] as unknown[],
    elements: [] as FakeElement[],
    played: 0,
    sounds: [] as { src: string; playing: boolean }[],
    revoked: [] as string[],
  };
  const state = { autoplay: true, gate: null as Promise<void> | null, canShareFiles: true, shareAbort: false, pick: (el: FakeElement) => el.fire("cancel") };
  const env: BrowserEnv = {
    navigator: {
      language: "en-GB",
      clipboard: {
        readText: async () => log.clipboardText,
        writeText: async (text) => void (log.clipboardText = text),
        read: async () => [{ types: ["text/plain", "image/png"], getType: async () => new Blob([PNG as BlobPart], { type: "image/png" }) }],
        write: async (items) => void log.clipboardItems.push(...items),
      },
      share: async (data) => {
        if (state.shareAbort) throw Object.assign(new Error("dismissed"), { name: "AbortError" });
        log.shared.push(data);
      },
      canShare: () => state.canShareFiles,
    },
    document: {
      createElement: ((tag: string) => {
        const el = new FakeElement();
        el.onClick = tag === "input" ? state.pick : () => {};
        log.elements.push(el);
        return el;
      }) as unknown as Document["createElement"],
      body: { append: () => {} } as unknown as HTMLElement,
    },
    screen: { width: 1440, height: 900 },
    devicePixelRatio: 2,
    matchMedia: () => ({ matches: true }),
    open: (...args) => void log.opened.push(args),
    Audio: class {
      volume = 1;
      record: { src: string; playing: boolean };
      constructor(src = "") {
        this.record = { src, playing: false };
        log.sounds.push(this.record);
      }
      async play() {
        if (state.gate) await state.gate;
        if (!state.autoplay) throw Object.assign(new Error("no gesture"), { name: "NotAllowedError" });
        log.played++;
        this.record.playing = true;
      }
      pause() {
        this.record.playing = false;
      }
      addEventListener() {}
    },
    ClipboardItem: class {
      items: Record<string, Blob>;
      constructor(items: Record<string, Blob>) {
        this.items = items;
      }
    },
    URL: {
      createObjectURL: () => `blob:${++urls}`,
      revokeObjectURL: (url: string) => void log.revoked.push(url),
    },
  };
  return { env, log, state };
}

/** A page that clicks every prompt at once, recording each. */
function clicker() {
  const asked: ClickRequest[] = [];
  const click: Click = (request, run) => {
    asked.push(request);
    return run();
  };
  return { asked, click };
}

test("hello lists what the browser has, in the remote subset", async () => {
  const { env } = fakeBrowser();
  const forward = browserForward({ env, click: clicker().click });
  const hello = (await forward({ owner: 1, method: "hello", params: {} })) as { result: { platform: string; capabilities: string[] } };
  assert.equal(hello.result.platform, "browser");
  assert.deepEqual(hello.result.capabilities, [
    "info",
    "clipboard.readText",
    "clipboard.writeText",
    "clipboard.readImage",
    "clipboard.writeImage",
    "openURL",
    "share",
    "files.pick",
    "photos.pick",
    "files.export",
    "sound.play",
  ]);
  assert.ok(hello.result.capabilities.every((m) => REMOTE_METHODS.has(m)));
  // Without a way to ask for a click, only what needs none.
  assert.deepEqual(browserCapabilities(env, false), ["info"]);
  // A browser without the async clipboard or Web Share.
  assert.deepEqual(browserCapabilities({ ...env, navigator: { language: "en" } }), ["info", "openURL", "files.pick", "photos.pick", "files.export", "sound.play"]);
});

test("a method the browser lacks fails unavailable", async () => {
  const { env } = fakeBrowser();
  const forward = browserForward({ env });
  const reply = (await forward({ id: 1, owner: 1, method: "clipboard.readText", params: {} })) as { error: { code: string } };
  assert.equal(reply.error.code, "unavailable");
});

test("info reads the screen, appearance and locale", async () => {
  const { env } = fakeBrowser();
  const reply = await browserForward({ env })({ id: 1, owner: 1, method: "info", params: {} });
  assert.deepEqual(reply, { result: { screen: { width: 1440, height: 900, scale: 2 }, darkMode: true, locale: "en-GB" } });
});

test("the clipboard goes through a click", async () => {
  const { env, log } = fakeBrowser();
  const { asked, click } = clicker();
  const forward = browserForward({ env, click });
  assert.deepEqual(await forward({ id: 1, owner: 1, method: "clipboard.writeText", params: { text: "hi" } }), { result: null });
  assert.equal(log.clipboardText, "hi");
  assert.deepEqual(await forward({ id: 2, owner: 1, method: "clipboard.readText", params: {} }), { result: "hi" });
  log.clipboardText = "";
  assert.deepEqual(await forward({ id: 3, owner: 1, method: "clipboard.readText", params: {} }), { result: null }, "an empty clipboard is null");
  assert.deepEqual(await forward({ id: 4, owner: 1, method: "clipboard.readImage", params: {} }), { result: b64(PNG) });
  assert.deepEqual(
    asked.map((r) => [r.method, r.label]),
    [
      ["clipboard.writeText", "Copy to clipboard"],
      ["clipboard.readText", "Paste from clipboard"],
      ["clipboard.readText", "Paste from clipboard"],
      ["clipboard.readImage", "Paste image from clipboard"],
    ],
  );
});

test("writeImage takes PNG only", async () => {
  const { env, log } = fakeBrowser();
  const forward = browserForward({ env, click: clicker().click });
  const jpeg = (await forward({ id: 1, owner: 1, method: "clipboard.writeImage", params: { image: b64(new Uint8Array([0xff, 0xd8, 0xff])) } })) as {
    error: { code: string };
  };
  assert.equal(jpeg.error.code, "failed");
  assert.deepEqual(await forward({ id: 2, owner: 1, method: "clipboard.writeImage", params: { image: b64(PNG) } }), { result: null });
  assert.equal(log.clipboardItems.length, 1);
});

test("a dismissed prompt fails cancelled; a refusal after the click fails denied", async () => {
  const { env } = fakeBrowser();
  const forward = browserForward({ env, click: () => Promise.reject(new Error("closed")) });
  const dismissed = (await forward({ id: 1, owner: 1, method: "clipboard.readText", params: {} })) as { error: { code: string } };
  assert.equal(dismissed.error.code, "cancelled");

  env.navigator!.clipboard!.readText = () => Promise.reject(Object.assign(new Error("no"), { name: "NotAllowedError" }));
  const refused = (await browserForward({ env, click: clicker().click })({ id: 2, owner: 1, method: "clipboard.readText", params: {} })) as {
    error: { code: string };
  };
  assert.equal(refused.error.code, "denied");
});

test("a cancel takes the prompt down and answers cancelled", async () => {
  const { env } = fakeBrowser();
  let seen: ClickRequest | undefined;
  const click: Click = (request) =>
    new Promise((_, reject) => {
      seen = request;
      request.signal.addEventListener("abort", () => reject(new Error("taken down")));
    });
  const forward = browserForward({ env, click });
  const pending = forward({ id: 7, owner: 1, method: "clipboard.writeText", params: { text: "x" } });
  await new Promise((resolve) => setTimeout(resolve, 0));
  assert.equal(seen?.signal.aborted, false);
  assert.deepEqual(await forward({ id: 7, cancel: true }), { result: null });
  assert.equal(seen?.signal.aborted, true);
  assert.equal(((await pending) as { error: { code: string } }).error.code, "cancelled");
});

test("openURL opens http, https and mailto in a new tab, after a click", async () => {
  const { env, log } = fakeBrowser();
  const forward = browserForward({ env, click: clicker().click });
  const bad = (await forward({ id: 1, owner: 1, method: "openURL", params: { url: "javascript:alert(1)" } })) as { error: { code: string } };
  assert.equal(bad.error.code, "failed");
  assert.deepEqual(await forward({ id: 2, owner: 1, method: "openURL", params: { url: "https://example.com", inApp: true } }), { result: null });
  assert.deepEqual(log.opened, [["https://example.com", "_blank", "noopener"]]);
});

test("share answers true when sent and false when dismissed", async () => {
  const { env, log, state } = fakeBrowser();
  const forward = browserForward({ env, click: clicker().click });
  assert.deepEqual(await forward({ id: 1, owner: 1, method: "share", params: { text: "t", files: [{ name: "a.txt", data: b64(new Uint8Array([65])) }] } }), {
    result: true,
  });
  const shared = log.shared[0] as { text: string; files: File[] };
  assert.equal(shared.text, "t");
  assert.equal(shared.files[0].name, "a.txt");
  state.shareAbort = true;
  assert.deepEqual(await forward({ id: 2, owner: 1, method: "share", params: { text: "t" } }), { result: false });
  state.canShareFiles = false;
  const files = (await forward({ id: 3, owner: 1, method: "share", params: { files: [{ name: "a", data: b64(PNG) }] } })) as { error: { code: string } };
  assert.equal(files.error.code, "unavailable");
});

test("files.pick and photos.pick use a file input", async () => {
  const { env, log, state } = fakeBrowser();
  const forward = browserForward({ env, click: clicker().click });
  state.pick = (el) => {
    el.files = [new File(["one"], "one.csv", { type: "text/csv" }), new File(["two"], "two.csv", { type: "text/csv" })];
    el.fire("change");
  };
  const picked = await forward({ id: 1, owner: 1, method: "files.pick", params: { types: [".csv", "text/csv"], multiple: true } });
  assert.deepEqual(picked, {
    result: [
      { name: "one.csv", type: "text/csv", data: b64(new TextEncoder().encode("one")) },
      { name: "two.csv", type: "text/csv", data: b64(new TextEncoder().encode("two")) },
    ],
  });
  assert.equal(log.elements[0].accept, ".csv,text/csv");
  assert.equal(log.elements[0].multiple, true);

  // A type identifier can't be said in `accept`, so any file is allowed.
  await forward({ id: 2, owner: 1, method: "files.pick", params: { types: ["public.json"] } });
  assert.equal(log.elements[1].accept, "");

  const photo = (await forward({ id: 3, owner: 1, method: "photos.pick", params: {} })) as { result: unknown[] };
  assert.equal(photo.result.length, 1, "one image by default");
  assert.equal(log.elements[2].accept, "image/*");
  assert.equal(log.elements[2].multiple, false);

  state.pick = (el) => el.fire("cancel");
  assert.deepEqual(await forward({ id: 4, owner: 1, method: "files.pick", params: {} }), { result: [] });
});

test("files.export downloads the file after a click, and answers false when dismissed", async () => {
  const { env, log } = fakeBrowser();
  const { asked, click } = clicker();
  const forward = browserForward({ env, click });
  assert.deepEqual(await forward({ id: 1, owner: 1, method: "files.export", params: { name: "out.csv", data: b64(PNG) } }), { result: true });
  const link = log.elements[0];
  assert.equal(link.download, "out.csv");
  assert.equal(link.removed, true);
  assert.deepEqual(asked.map((r) => r.label), ["Save out.csv"]);
  const bad = (await forward({ id: 2, owner: 1, method: "files.export", params: { name: "../x", data: b64(PNG) } })) as { error: { code: string } };
  assert.equal(bad.error.code, "failed");
  const dismissed = browserForward({ env, click: () => Promise.reject(new Error("closed")) });
  assert.deepEqual(await dismissed({ id: 3, owner: 1, method: "files.export", params: { name: "out.csv", data: b64(PNG) } }), { result: false });
  assert.equal(log.elements.length, 1, "nothing downloaded");
});

test("sound.play asks for a click only when autoplay is blocked", async () => {
  const { env, log, state } = fakeBrowser();
  const { asked, click } = clicker();
  const forward = browserForward({ env, click });
  assert.deepEqual(await forward({ id: 1, owner: 1, method: "sound.play", params: { data: b64(PNG) } }), { result: null });
  assert.equal(asked.length, 0);
  state.autoplay = false;
  const blocked = forward({ id: 2, owner: 1, method: "sound.play", params: { data: b64(PNG) } });
  // The click's play() fails too in this fake, which never unblocks: the reply carries that.
  assert.equal(((await blocked) as { error: { code: string } }).error.code, "denied");
  assert.deepEqual(
    asked.map((r) => r.label),
    ["Play sound"],
  );
  assert.equal(log.played, 1);
});

test("the support table's browser column matches what the fallback answers", () => {
  const { env } = fakeBrowser();
  const yes = Object.entries(SUPPORT)
    .filter(([, row]) => row.browser === "yes")
    .map(([method]) => method)
    .sort();
  assert.deepEqual(browserCapabilities(env).sort(), yes);
  for (const [method, row] of Object.entries(SUPPORT)) {
    if (row.browser !== "no") assert.ok(REMOTE_METHODS.has(method), `${method}: a browser reaches only the remote subset`);
  }
});

test("a cancel while autoplay is checked asks for no click", async () => {
  const { env, log, state } = fakeBrowser();
  const { asked, click } = clicker();
  const forward = browserForward({ env, click });
  let open!: () => void;
  state.gate = new Promise((resolve) => (open = resolve));
  state.autoplay = false;
  const pending = forward({ id: 1, owner: 1, method: "sound.play", params: { data: b64(PNG) } });
  await forward({ id: 1, cancel: true });
  open();
  assert.equal(((await pending) as { error: { code: string } }).error.code, "cancelled");
  assert.equal(asked.length, 0, "no prompt for a cancelled call");
  assert.deepEqual(log.revoked, [log.sounds[0].src], "its URL is revoked");
});

test("a release, or the owner's next hello, stops that owner's sounds", async () => {
  const { env, log } = fakeBrowser();
  const forward = browserForward({ env, click: clicker().click });
  await forward({ id: 1, owner: 1, method: "sound.play", params: { data: b64(PNG) } });
  await forward({ id: 2, owner: 2, method: "sound.play", params: { data: b64(PNG) } });
  await forward({ id: 3, owner: 2, method: "sound.play", params: { data: b64(PNG) } });
  assert.deepEqual(log.sounds.map((s) => s.playing), [true, true, true]);
  assert.deepEqual(await forward({ owner: 1, release: true }), { result: null });
  assert.deepEqual(log.sounds.map((s) => s.playing), [false, true, true], "only owner 1's");
  assert.deepEqual(log.revoked, [log.sounds[0].src]);
  await forward({ owner: 2, method: "hello", params: {} });
  assert.deepEqual(log.sounds.map((s) => s.playing), [false, false, false]);
  assert.equal(log.revoked.length, 3);
});

test("a dismissed sound prompt revokes its URL", async () => {
  const { env, log, state } = fakeBrowser();
  state.autoplay = false;
  const forward = browserForward({ env, click: () => Promise.reject(new Error("closed")) });
  const reply = (await forward({ id: 1, owner: 1, method: "sound.play", params: { data: b64(PNG) } })) as { error: { code: string } };
  assert.equal(reply.error.code, "cancelled");
  assert.deepEqual(log.revoked, [log.sounds[0].src]);
});

test("which methods need a click comes from the support table", () => {
  const { env } = fakeBrowser();
  const noClick = Object.entries(SUPPORT)
    .filter(([, row]) => row.browser === "yes" && !("browserClick" in row && row.browserClick))
    .map(([method]) => method)
    .sort();
  assert.deepEqual(browserCapabilities(env, false).sort(), noClick);
});

test("a dismissed picker or share prompt answers as a cancel does on the device", async () => {
  const { env } = fakeBrowser();
  const forward = browserForward({ env, click: () => Promise.reject(new Error("closed")) });
  assert.deepEqual(await forward({ id: 1, owner: 1, method: "files.pick", params: {} }), { result: [] });
  assert.deepEqual(await forward({ id: 2, owner: 1, method: "photos.pick", params: {} }), { result: [] });
  assert.deepEqual(await forward({ id: 3, owner: 1, method: "share", params: { text: "t" } }), { result: false });
});

test("a kernel cancel while a picker, share or export prompt shows answers cancelled", async () => {
  const { env } = fakeBrowser();
  const click: Click = (request) =>
    new Promise((_, reject) => request.signal.addEventListener("abort", () => reject(new Error("taken down"))));
  const forward = browserForward({ env, click });
  const calls: [string, Record<string, unknown>][] = [
    ["files.pick", {}],
    ["photos.pick", {}],
    ["share", { text: "t" }],
    ["files.export", { name: "out.csv", data: b64(PNG) }],
  ];
  for (const [n, [method, params]] of calls.entries()) {
    const reply = forward({ id: n + 1, owner: 1, method, params });
    await new Promise((resolve) => setTimeout(resolve, 0));
    await forward({ id: n + 1, cancel: true });
    assert.equal(((await reply) as { error: { code: string } }).error.code, "cancelled", method);
  }
});

test("one prompt at a time, and a cancelled call waiting its turn shows none", async () => {
  const { env } = fakeBrowser();
  const shown: { label: string; click: () => void }[] = [];
  const click: Click = (request, run) =>
    new Promise((resolve, reject) => {
      shown.push({ label: request.method, click: () => run().then(resolve, reject) });
      request.signal.addEventListener("abort", () => reject(new Error("taken down")));
    });
  const forward = browserForward({ env, click });
  const tick = () => new Promise((resolve) => setTimeout(resolve, 0));
  const first = forward({ id: 1, owner: 1, method: "clipboard.writeText", params: { text: "a" } });
  const second = forward({ id: 2, owner: 1, method: "clipboard.readText", params: {} });
  const third = forward({ id: 3, owner: 1, method: "clipboard.readText", params: {} });
  await tick();
  assert.deepEqual(shown.map((p) => p.label), ["clipboard.writeText"], "only the first prompt shows");
  await forward({ id: 2, cancel: true });
  assert.equal(((await second) as { error: { code: string } }).error.code, "cancelled");
  await tick();
  assert.deepEqual(shown.map((p) => p.label), ["clipboard.writeText"], "the third waits for the first to close");
  shown[0].click();
  assert.deepEqual(await first, { result: null });
  await tick();
  assert.deepEqual(shown.map((p) => p.label), ["clipboard.writeText", "clipboard.readText"], "then the third; the cancelled one never showed");
  shown[1].click();
  assert.deepEqual(await third, { result: "a" });
});

test("at most 32 sounds play at once per owner", async () => {
  const { env } = fakeBrowser();
  const forward = browserForward({ env, click: clicker().click });
  for (let n = 0; n < 32; n++) await forward({ id: n + 1, owner: 1, method: "sound.play", params: { data: b64(PNG) } });
  const over = (await forward({ id: 99, owner: 1, method: "sound.play", params: { data: b64(PNG) } })) as { error: { code: string } };
  assert.equal(over.error.code, "failed");
  assert.deepEqual(await forward({ id: 100, owner: 2, method: "sound.play", params: { data: b64(PNG) } }), { result: null }, "another owner's count is its own");
});

test("an export name of only spaces is refused, as on the device", async () => {
  const { env } = fakeBrowser();
  const reply = (await browserForward({ env, click: clicker().click })({ id: 1, owner: 1, method: "files.export", params: { name: "  ", data: b64(PNG) } })) as {
    error: { code: string };
  };
  assert.equal(reply.error.code, "failed");
});
