// End to end in a headless browser: cdp-kernel's browser target with this
// package's preload in its Worker and webkitHost on the page, and a stand-in
// for the Swift DeviceBridge at `webkit.messageHandlers.device`. A cell's
// `device.clipboard.readText()` crosses the Worker, the page and the fake
// bridge and comes back.
//
// Needs the playwright package and a cdp-kernel checkout with its `preload`
// and `host` options (v0.7.1 or later; v0.7.2 for interrupts), named by CDPK_DIR. Skipped when
// CDPK_DIR is unset; fails when it is set but the setup isn't usable, so CI
// can't pass with the test skipped.
import { test } from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { existsSync, mkdtempSync, readFileSync, rmSync } from "node:fs";
import { createServer } from "node:http";
import type { AddressInfo } from "node:net";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

type Page = {
  goto(url: string): Promise<unknown>;
  evaluate<T, A>(fn: (arg: A) => T | Promise<T>, arg: A): Promise<T>;
  waitForFunction(expression: string): Promise<unknown>;
};
type Browser = { newPage(): Promise<Page>; close(): Promise<void> };

let chromium: { launch(): Promise<Browser> } | null = null;
let playwrightError = "";
try {
  chromium = (await import("playwright" as string)).chromium;
} catch (err) {
  playwrightError = err instanceof Error ? err.message : String(err);
}
// Resolved once, so a relative path means the same thing to every use below.
const CDPK_DIR = process.env.CDPK_DIR ? resolve(process.env.CDPK_DIR) : undefined;
/** The oldest cdp-kernel whose interrupt aborts host requests (cdp-kernel#388). */
const CDPK_MIN = [0, 7, 2];
const skip = CDPK_DIR ? false : "needs CDPK_DIR, a cdp-kernel checkout";

/** Why the setup CDPK_DIR names can't run the test, or null when it can. */
function setupProblem(): string | null {
  if (chromium === null) return `can't import playwright: ${playwrightError}`;
  if (!existsSync(join(CDPK_DIR!, "scripts/build-browser.mjs"))) return `CDPK_DIR=${CDPK_DIR} isn't a cdp-kernel checkout`;
  if (!existsSync(join(CDPK_DIR!, "node_modules"))) return `run npm ci in ${CDPK_DIR} first`;
  const version = String(JSON.parse(readFileSync(join(CDPK_DIR!, "package.json"), "utf8")).version ?? "");
  const parts = version.split(/[.-]/).slice(0, 3).map(Number);
  const older = CDPK_MIN.findIndex((min, i) => (parts[i] ?? 0) !== min);
  if (older !== -1 && (parts[older] ?? 0) < CDPK_MIN[older]) return `CDPK_DIR has cdp-kernel ${version}; this test needs ${CDPK_MIN.join(".")} or later`;
  return null;
}

const ROOT = fileURLToPath(new URL("..", import.meta.url));

const PAGE = `<!doctype html><script type="module">
import { startBrowserKernel } from "./kernel.js";
import { webkitHost } from "./webkit.js";

// The Swift DeviceBridge, as WKScriptMessageHandlerWithReply answers.
let clipboard = "from the fake bridge";
let image = null;
globalThis.bridgeLog = [];
globalThis.webkit = { messageHandlers: { device: { async postMessage(msg) {
  bridgeLog.push(msg);
  if (msg.method === "hello") return { result: { platform: "macos", appVersion: "test", capabilities: ["clipboard.readText", "clipboard.writeText", "clipboard.readImage", "clipboard.writeImage", "ui.prompt"] } };
  // A dialog the person never answers.
  if (msg.method === "ui.prompt") return new Promise(() => {});
  if (msg.method === "clipboard.readText") return { result: clipboard };
  if (msg.method === "clipboard.writeText") { clipboard = msg.params.text; return { result: null }; }
  if (msg.method === "clipboard.readImage") return { result: image && { base64: image } };
  if (msg.method === "clipboard.writeImage") { image = msg.params.image.base64; return { result: null }; }
  return { error: { code: "unavailable", message: "no " + msg.method } };
} } } };

const kernel = startBrowserKernel({
  createWorker: () => new Worker("./worker.js", { type: "module" }),
  preload: ["./preload.js"],
  host: webkitHost(),
  log: () => {},
});
const seen = [];
kernel.onMessage((channel, msg) => seen.push(msg));
globalThis.execute = (code) => {
  const msg_id = crypto.randomUUID();
  kernel.send("shell", {
    header: { msg_id, msg_type: "execute_request", session: "s", username: "", date: new Date().toISOString(), version: "5.3" },
    parent_header: {}, metadata: {},
    content: { code, silent: false, store_history: true, allow_stdin: false, stop_on_error: true },
  });
  return new Promise((resolve) => {
    const poll = () => {
      const mine = seen.filter((m) => m.parent_header.msg_id === msg_id);
      if (mine.some((m) => m.header.msg_type === "status" && m.content.execution_state === "idle")) {
        const result = mine.find((m) => m.header.msg_type === "execute_result");
        const reply = mine.find((m) => m.header.msg_type === "execute_reply");
        resolve({ status: reply.content.status, evalue: reply.content.evalue, text: result?.content.data["text/plain"] });
      } else setTimeout(poll, 10);
    };
    poll();
  });
};
globalThis.interrupt = () => kernel.send("control", {
  header: { msg_id: crypto.randomUUID(), msg_type: "interrupt_request", session: "s", username: "", date: new Date().toISOString(), version: "5.3" },
  parent_header: {}, metadata: {}, content: {},
});
globalThis.ready = true;
</script>`;

test("a cell reads and writes the clipboard through the fake Swift bridge", { skip }, async (t) => {
  const problem = setupProblem();
  if (problem) assert.fail(problem);
  const dir = mkdtempSync(join(tmpdir(), "ganymede-device-"));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  execFileSync(process.execPath, [join(CDPK_DIR!, "scripts/build-browser.mjs"), dir], { cwd: CDPK_DIR, stdio: "pipe" });
  execFileSync(process.execPath, [join(ROOT, "scripts/build.mjs"), dir], { cwd: ROOT, stdio: "pipe" });

  const server = createServer((req, res) => {
    const path = new URL(req.url ?? "/", "http://x").pathname;
    if (path === "/") return res.writeHead(200, { "content-type": "text/html" }).end(PAGE);
    if (/^\/(?:kernel|worker|preload|webkit)\.js$/.test(path)) {
      return res.writeHead(200, { "content-type": "text/javascript" }).end(readFileSync(join(dir, path)));
    }
    res.writeHead(404).end();
  });
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  t.after(() => server.close());
  const browser = await chromium!.launch();
  t.after(() => browser.close());
  const page = await browser.newPage();
  await page.goto(`http://127.0.0.1:${(server.address() as AddressInfo).port}/`);
  await page.waitForFunction("globalThis.ready === true");

  type Result = { status: string; evalue?: string; text?: string };
  const execute = (code: string) => page.evaluate((c) => (globalThis as unknown as { execute(c: string): Promise<Result> }).execute(c), code);

  assert.equal((await execute("device.has('clipboard.readText')")).text, "true");
  assert.equal((await execute("await device.clipboard.readText()")).text, "'from the fake bridge'");
  await execute("await device.clipboard.writeText('from a cell')");
  assert.equal((await execute("await device.clipboard.readText()")).text, "'from a cell'");
  assert.equal((await execute("(await device.info()).platform")).text, "'macos'");

  // Bytes from the Worker reach Swift as base64 and come back as a Uint8Array.
  await execute("await device.clipboard.writeImage(new Blob([new Uint8Array([137, 80, 78, 71, 0, 255])]))");
  assert.equal(await page.evaluate(() => (globalThis as unknown as { bridgeLog: { params?: { image?: unknown } }[] }).bridgeLog.at(-1)!.params!.image, null).then(JSON.stringify), JSON.stringify({ base64: "iVBORwD/" }));
  const read = await execute("const png = await device.clipboard.readImage(); [png instanceof Uint8Array, [...png].join(',')]");
  assert.equal(read.text, "[ true, '137,80,78,71,0,255' ]");

  // A cell waiting on a dialog that its signal aborts: the call rejects
  // cancelled in the cell, and Swift is told to close that dialog.
  const cancelled = await execute("await device.ui.prompt('Name?', { signal: AbortSignal.timeout(50) }).catch((e) => e.code)");
  assert.equal(cancelled.text, "'timeout'");
  const calls = await page.evaluate(() => (globalThis as unknown as { bridgeLog: { id: number; method?: string; cancel?: true }[] }).bridgeLog, null);
  const prompt = calls.find((m) => m.method === "ui.prompt")!;
  assert.deepEqual(calls.at(-1), { id: prompt.id, cancel: true });

  // An interrupt while a cell waits on a dialog: Swift is told to close it.
  const waiting = execute("await device.ui.prompt('Again?')");
  await page.waitForFunction("bridgeLog.filter((m) => m.method === 'ui.prompt').length === 2");
  await page.evaluate(() => (globalThis as unknown as { interrupt(): void }).interrupt(), null);
  assert.equal((await waiting).status, "error");
  const after = await page.evaluate(() => (globalThis as unknown as { bridgeLog: { id: number; method?: string; cancel?: true }[] }).bridgeLog, null);
  const again = after.filter((m) => m.method === "ui.prompt")[1];
  assert.deepEqual(after.at(-1), { id: again.id, cancel: true });

  const log = await page.evaluate(() => (globalThis as unknown as { bridgeLog: { method?: string }[] }).bridgeLog.map((m) => m.method), null);
  // The cancel has no method.
  assert.deepEqual(log, ["hello", "clipboard.readText", "clipboard.writeText", "clipboard.readText", "clipboard.writeImage", "clipboard.readImage", "ui.prompt", undefined, "ui.prompt", undefined]);
});
