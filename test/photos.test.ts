// device.photos.save over a fake transport: what crosses the wire.
import { test } from "node:test";
import assert from "node:assert/strict";
import { createDevice, DeviceError, type DeviceTransport } from "../src/mod.ts";

function host(capabilities = ["photos.save", "photos.authorizationStatus", "photos.requestAuthorization"]) {
  const sent: { method: string; params: Record<string, unknown> }[] = [];
  const transport: DeviceTransport = {
    async call(method, params) {
      sent.push({ method, params });
      return method === "photos.authorizationStatus" ? "writeOnly" : null;
    },
  };
  return { device: createDevice(transport, { platform: "macos", appVersion: "", capabilities }), sent };
}

const isCode = (code: string) => (err: unknown) => err instanceof DeviceError && err.code === code;

test("save sends the image's bytes, from bytes or a Blob", async () => {
  const { device, sent } = host();
  await device.photos.save(new Uint8Array([1, 2, 3]));
  await device.photos.save(new Blob([new Uint8Array([4, 5])], { type: "image/png" }));
  assert.equal(sent.length, 2);
  assert.equal(sent[0].method, "photos.save");
  assert.deepEqual([...(sent[0].params.image as Uint8Array)], [1, 2, 3]);
  assert.deepEqual([...(sent[1].params.image as Uint8Array)], [4, 5]);
});

test("the trio reads add-only access as granted", async () => {
  const { device } = host();
  assert.equal(await device.photos.authorizationStatus(), "writeOnly");
  assert.equal(await device.photos.isAuthorized(), true);
});

test("a host without save fails unavailable before reading the Blob", async () => {
  const { device, sent } = host(["photos.pick"]);
  let read = false;
  const blob = { arrayBuffer: async () => ((read = true), new ArrayBuffer(1)) } as unknown as Blob;
  await assert.rejects(device.photos.save(blob), isCode("unavailable"));
  assert.equal(read, false);
  assert.equal(sent.length, 0);
});
