// device.camera over a fake transport: what crosses the wire, and how
// replies are read.
import { test } from "node:test";
import assert from "node:assert/strict";
import { createDevice, DeviceError, type DeviceTransport } from "../src/mod.ts";

const METHODS = ["camera.authorizationStatus", "camera.requestAuthorization", "camera.capture"];

function host(answer: () => unknown, capabilities = METHODS) {
  const sent: { method: string; params: Record<string, unknown> }[] = [];
  const transport: DeviceTransport = {
    async call(method, params) {
      sent.push({ method, params });
      return method === "camera.capture" ? answer() : "authorized";
    },
  };
  return { device: createDevice(transport, { platform: "ipados", appVersion: "", capabilities }), sent };
}

const isCode = (code: string) => (err: unknown) => err instanceof DeviceError && err.code === code;

test("capture reads the photo's bytes, and null on cancel", async () => {
  const jpeg = new Uint8Array([0xff, 0xd8, 0xff]);
  assert.deepEqual(await host(() => jpeg).device.camera.capture(), jpeg);
  assert.deepEqual(await host(() => jpeg.buffer).device.camera.capture(), jpeg);
  assert.equal(await host(() => null).device.camera.capture(), null);
  const { device, sent } = host(() => null);
  await device.camera.capture();
  assert.deepEqual(sent, [{ method: "camera.capture", params: {} }]);
});

test("a malformed reply fails", async () => {
  for (const reply of [undefined, "photo", { base64: "AA==" }, [1, 2]]) {
    await assert.rejects(host(() => reply).device.camera.capture(), isCode("failed"));
  }
});

test("the trio asks the host for the camera's status", async () => {
  const { device, sent } = host(() => null);
  assert.equal(await device.camera.authorizationStatus(), "authorized");
  assert.equal(await device.camera.isAuthorized(), true);
  assert.deepEqual(sent.map((m) => m.method), ["camera.authorizationStatus", "camera.authorizationStatus"]);
});

test("a Mac, with no camera.capture, rejects unavailable without asking", async () => {
  const { device, sent } = host(() => null, []);
  assert.equal(device.has("camera.capture"), false);
  await assert.rejects(device.camera.capture(), isCode("unavailable"));
  assert.equal(sent.length, 0);
});
