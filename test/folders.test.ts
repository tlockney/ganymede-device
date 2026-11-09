// `device.folders` (Phase 3): argument checks, reply parsing, and the
// `Folder` a reply becomes, against a fake host that answers as
// DeviceBridge does once the transport has decoded `{ base64 }` into bytes.
import { test } from "node:test";
import assert from "node:assert/strict";
import { createDevice, DeviceError, type DeviceTransport } from "../src/mod.ts";

const METHODS = ["folders.pick", "folders.list", "folders.entries", "folders.read", "folders.write", "folders.remove"];
const DATA = { id: "F1", name: "Data", writable: true };

class FolderHost implements DeviceTransport {
  readonly calls: { method: string; params: Record<string, unknown> }[] = [];

  call(method: string, params: Record<string, unknown> = {}): Promise<unknown> {
    this.calls.push({ method, params });
    switch (method) {
      case "folders.pick":
        return Promise.resolve(DATA);
      case "folders.list":
        return Promise.resolve([DATA, { id: "F2", name: "Photos", writable: false }]);
      case "folders.entries":
        return Promise.resolve([
          { name: "a.csv", kind: "file", size: 12, modified: "2026-11-09T10:00:00.000Z" },
          { name: "sub", kind: "directory", modified: "not a date" },
          { name: "latest", kind: "link" },
        ]);
      case "folders.read":
        return Promise.resolve(new Uint8Array([104, 105]));
      case "folders.write":
      case "folders.remove":
        return Promise.resolve(null);
      default:
        return Promise.reject(new DeviceError("unavailable", method));
    }
  }

  last(method: string): Record<string, unknown> | undefined {
    return this.calls.filter((c) => c.method === method).at(-1)?.params;
  }
}

function device(host: DeviceTransport, capabilities = METHODS) {
  return createDevice(host, { platform: "macos", appVersion: "", capabilities });
}

const code = (expected: string) => (err: unknown) => err instanceof DeviceError && err.code === expected;

test("pick sends write and gives a folder; a cancel is null", async () => {
  const host = new FolderHost();
  const folder = await device(host).folders.pick({ write: true });
  assert.deepEqual(host.last("folders.pick"), { write: true });
  assert.equal(folder?.id, "F1");
  assert.equal(folder?.writable, true);
  assert.equal(await device({ call: () => Promise.resolve(null) }).folders.pick(), null);
  await assert.rejects(device(host).folders.pick({ write: "yes" as unknown as boolean }), code("failed"));
});

test("list gives each granted folder", async () => {
  const folders = await device(new FolderHost()).folders.list();
  assert.deepEqual(
    folders.map((f) => [f.id, f.name, f.writable]),
    [
      ["F1", "Data", true],
      ["F2", "Photos", false],
    ],
  );
});

test("a folder's calls name it and a path in it", async () => {
  const host = new FolderHost();
  const [folder] = await device(host).folders.list();

  const entries = await folder.entries();
  assert.deepEqual(host.last("folders.entries"), { folder: "F1" });
  assert.deepEqual(entries[0], { name: "a.csv", kind: "file", size: 12, modified: new Date("2026-11-09T10:00:00.000Z") });
  assert.deepEqual(entries[1], { name: "sub", kind: "directory" });
  assert.deepEqual(entries[2], { name: "latest", kind: "link" });
  await folder.entries("sub");
  assert.deepEqual(host.last("folders.entries"), { folder: "F1", path: "sub" });

  assert.deepEqual([...(await folder.read("a.csv"))], [104, 105]);
  assert.deepEqual(host.last("folders.read"), { folder: "F1", path: "a.csv" });

  await folder.write("notes/today.txt", "hi");
  const write = host.last("folders.write")!;
  assert.equal(write.path, "notes/today.txt");
  assert.deepEqual([...(write.data as Uint8Array)], [104, 105]);
  await folder.write("b.bin", new Uint8Array([1, 2]));
  assert.deepEqual([...(host.last("folders.write")!.data as Uint8Array)], [1, 2]);

  await folder.remove("b.bin");
  assert.deepEqual(host.last("folders.remove"), { folder: "F1", path: "b.bin" });
});

test("paths that leave the folder are refused before calling", async () => {
  const host = new FolderHost();
  const [folder] = await device(host).folders.list();
  const before = host.calls.length;
  await assert.rejects(folder.read("/etc/passwd"), code("denied"));
  await assert.rejects(folder.read("../secret"), code("denied"));
  await assert.rejects(folder.entries("a/../../b"), code("denied"));
  await assert.rejects(folder.read(""), code("failed"));
  await assert.rejects(folder.write(42 as unknown as string, "x"), code("failed"));
  assert.equal(host.calls.length, before);
});

test("malformed replies fail", async () => {
  const bad = { call: (method: string) => Promise.resolve(method === "folders.pick" ? { id: 1 } : [{ name: "x", kind: "pipe" }]) };
  await assert.rejects(device(bad).folders.pick(), code("failed"));
  await assert.rejects(device(bad).folders.list(), code("failed"));
});

test("without the host's methods, calls are unavailable", async () => {
  await assert.rejects(device(new FolderHost(), []).folders.pick(), code("unavailable"));
  const [folder] = await device(new FolderHost(), ["folders.list"]).folders.list();
  await assert.rejects(folder.write("a", "b"), code("unavailable"));
});
