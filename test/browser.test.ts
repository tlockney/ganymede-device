// End to end in a headless browser: cdp-kernel's browser target with this
// package's preload in its Worker and webkitHost on the page, and a stand-in
// for the Swift DeviceBridge at `webkit.messageHandlers.device`. A cell's
// `device.clipboard.readText()` crosses the Worker, the page and the fake
// bridge and comes back.
//
// Needs the playwright package and a cdp-kernel checkout with its `preload`
// and `host` options (tlockney/cdp-kernel#384), named by CDPK_DIR; skipped
// otherwise.
import { test } from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { existsSync, mkdtempSync, readFileSync, rmSync } from "node:fs";
import { createServer } from "node:http";
import type { AddressInfo } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

type Page = {
  goto(url: string): Promise<unknown>;
  evaluate<T, A>(fn: (arg: A) => T | Promise<T>, arg: A): Promise<T>;
  waitForFunction(expression: string): Promise<unknown>;
};
type Browser = { newPage(): Promise<Page>; close(): Promise<void> };

let chromium: { launch(): Promise<Browser> } | null = null;
try {
  chromium = (await import("playwright" as string)).chromium;
} catch {
  // Not installed: skip.
}
const CDPK_DIR = process.env.CDPK_DIR;
const skip = chromium === null
  ? "needs the playwright package"
  : !CDPK_DIR || !existsSync(join(CDPK_DIR, "scripts/build-browser.mjs"))
  ? "needs CDPK_DIR, a cdp-kernel checkout"
  : !readFileSync(join(CDPK_DIR, "src/browser/target.ts"), "utf8").includes("preload?:")
  ? "needs a cdp-kernel with the preload option (tlockney/cdp-kernel#384)"
  : false;

const ROOT = fileURLToPath(new URL("..", import.meta.url));

const PAGE = `<!doctype html><script type="module">
import { startBrowserKernel } from "./kernel.js";
import { webkitHost } from "./webkit.js";

// The Swift DeviceBridge, as WKScriptMessageHandlerWithReply answers.
let clipboard = "from the fake bridge";
globalThis.bridgeLog = [];
globalThis.webkit = { messageHandlers: { device: { async postMessage(msg) {
  bridgeLog.push(msg);
  if (msg.method === "hello") return { result: { platform: "macos", appVersion: "test", capabilities: ["clipboard.readText", "clipboard.writeText"] } };
  if (msg.method === "clipboard.readText") return { result: clipboard };
  if (msg.method === "clipboard.writeText") { clipboard = msg.params.text; return { result: null }; }
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
globalThis.ready = true;
</script>`;

test("a cell reads and writes the clipboard through the fake Swift bridge", { skip }, async (t) => {
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

  const log = await page.evaluate(() => (globalThis as unknown as { bridgeLog: { method?: string }[] }).bridgeLog.map((m) => m.method), null);
  assert.deepEqual(log, ["hello", "clipboard.readText", "clipboard.writeText", "clipboard.readText"]);
});
