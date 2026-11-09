// `device.bluetooth` (Phase 3): argument checks, reply parsing, and the
// peripheral handle, against a fake host that answers as DeviceBridge does
// once the transport has decoded `{ base64 }` into bytes.
import { test } from "node:test";
import assert from "node:assert/strict";
import { createDevice, DeviceError, type DeviceTransport } from "../src/mod.ts";

const STRAP = "6E400001-B5A3-F393-E0A9-E50E24DCCA9E";
const METHODS = [
  "bluetooth.authorizationStatus",
  "bluetooth.requestAuthorization",
  "bluetooth.scan",
  "bluetooth.known",
  "bluetooth.connect",
  "bluetooth.services",
  "bluetooth.read",
  "bluetooth.write",
  "bluetooth.notify",
  "bluetooth.rssi",
];

class BluetoothHost implements DeviceTransport {
  readonly calls: { method: string; params: Record<string, unknown> }[] = [];
  #batches: unknown[] = [];

  /** What the next `stream.next` answers. */
  queue(...batches: unknown[]): void {
    this.#batches.push(...batches);
  }

  call(method: string, params: Record<string, unknown> = {}): Promise<unknown> {
    this.calls.push({ method, params });
    switch (method) {
      case "bluetooth.scan":
      case "bluetooth.notify":
        return Promise.resolve({ stream: 1 });
      case "stream.next":
        return Promise.resolve(this.#batches.shift() ?? { values: [], dropped: 0, end: true });
      case "stream.close":
        return Promise.resolve(null);
      case "bluetooth.known":
        return Promise.resolve([{ id: STRAP, name: null }]);
      case "bluetooth.connect":
        return Promise.resolve({ peripheral: 4, id: STRAP, name: "Strap" });
      case "bluetooth.services":
        return Promise.resolve([{ uuid: "180D", characteristics: [{ uuid: "2A37", properties: ["notify", 7] }] }]);
      case "bluetooth.read":
        return Promise.resolve(new Uint8Array([42]));
      case "bluetooth.write":
      case "handle.close":
        return Promise.resolve(null);
      case "bluetooth.rssi":
        return Promise.resolve(-61);
      default:
        return Promise.reject(new DeviceError("unavailable", method));
    }
  }

  last(method: string): Record<string, unknown> | undefined {
    return this.calls.filter((c) => c.method === method).at(-1)?.params;
  }
}

function device(host: BluetoothHost, capabilities = METHODS) {
  return createDevice(host, { platform: "macos", appVersion: "", capabilities });
}

const failed = (err: unknown) => err instanceof DeviceError && err.code === "failed";

test("scan sends its filter and reads advertisements", async () => {
  const host = new BluetoothHost();
  host.queue({
    values: [
      { id: STRAP, name: null, rssi: -50, services: ["180D"], manufacturerData: new Uint8Array([1, 2]), serviceData: { "180D": new Uint8Array([3]), bad: 4 } },
    ],
    dropped: 0,
  });
  const ads = [];
  for await (const ad of device(host).bluetooth.scan({ services: ["180d"], allowDuplicates: true })) ads.push(ad);
  assert.deepEqual(host.last("bluetooth.scan"), { services: ["180d"], allowDuplicates: true });
  assert.equal(ads.length, 1);
  assert.equal(ads[0].name, null);
  assert.deepEqual([...ads[0].manufacturerData!], [1, 2]);
  assert.deepEqual(Object.keys(ads[0].serviceData), ["180D"]);
});

test("scan, known and connect refuse bad arguments before calling", async () => {
  const host = new BluetoothHost();
  const { bluetooth } = device(host);
  assert.throws(() => bluetooth.scan({ services: ["heart"] }), failed);
  assert.throws(() => bluetooth.scan({ allowDuplicates: "yes" as unknown as boolean }), failed);
  await assert.rejects(bluetooth.known(["nope"]), failed);
  await assert.rejects(bluetooth.connect("nope"), failed);
  await assert.rejects(bluetooth.connect(STRAP, { timeout: 0 }), failed);
  assert.equal(host.calls.length, 0);
});

test("known lists what the host knows", async () => {
  const host = new BluetoothHost();
  assert.deepEqual(await device(host).bluetooth.known([STRAP]), [{ id: STRAP, name: null }]);
  assert.deepEqual(host.last("bluetooth.known"), { ids: [STRAP] });
});

test("a connected peripheral's calls name its handle until it closes", async () => {
  const host = new BluetoothHost();
  const peripheral = await device(host).bluetooth.connect(STRAP, { timeout: 5 });
  assert.deepEqual(host.last("bluetooth.connect"), { id: STRAP, timeout: 5 });
  assert.equal(peripheral.id, STRAP);
  assert.equal(peripheral.name, "Strap");

  const services = await peripheral.services();
  assert.deepEqual(services, [{ uuid: "180D", characteristics: [{ uuid: "2A37", properties: ["notify"] }] }]);
  assert.deepEqual([...(await peripheral.read("180D", "2A37"))], [42]);
  assert.deepEqual(host.last("bluetooth.read"), { peripheral: 4, service: "180D", characteristic: "2A37" });
  await peripheral.write("180D", "2A39", new Uint8Array([1]), { withResponse: false });
  const write = host.last("bluetooth.write")!;
  assert.equal(write.withResponse, false);
  assert.deepEqual([...(write.data as Uint8Array)], [1]);
  assert.equal(await peripheral.rssi(), -61);

  host.queue({ values: [new Uint8Array([9])], dropped: 0 });
  const values = [];
  for await (const value of peripheral.notify("180D", "2A37")) values.push([...value]);
  assert.deepEqual(values, [[9]]);
  assert.deepEqual(host.last("bluetooth.notify"), { peripheral: 4, service: "180D", characteristic: "2A37" });

  await assert.rejects(peripheral.read("x", "2A37"), failed);
  await peripheral.close();
  assert.equal(peripheral.closed, true);
  assert.deepEqual(host.last("handle.close"), { handle: 4 });
  await assert.rejects(peripheral.rssi(), failed);
  assert.throws(() => peripheral.notify("180D", "2A37"), failed);
});

test("a disconnected call marks the peripheral closed", async () => {
  const host = new BluetoothHost();
  const peripheral = await device(host).bluetooth.connect(STRAP);
  const call = host.call.bind(host);
  host.call = (method, params) => (method === "bluetooth.rssi" ? Promise.reject(new DeviceError("disconnected", "gone")) : call(method, params));
  await assert.rejects(peripheral.rssi(), (err) => err instanceof DeviceError && err.code === "disconnected");
  assert.equal(peripheral.closed, true);
  await assert.rejects(peripheral.read("180D", "2A37"), failed);
});

test("malformed replies fail", async () => {
  const host = new BluetoothHost();
  host.call = (method) => Promise.resolve(method === "bluetooth.connect" ? { peripheral: "4" } : null);
  await assert.rejects(device(host).bluetooth.connect(STRAP), failed);
  await assert.rejects(device(host).bluetooth.known([STRAP]), failed);
});

test("without the host's methods, calls are unavailable", async () => {
  const { bluetooth } = device(new BluetoothHost(), []);
  await assert.rejects(bluetooth.connect(STRAP), (err) => err instanceof DeviceError && err.code === "unavailable");
  assert.throws(() => bluetooth.scan(), (err) => err instanceof DeviceError && err.code === "unavailable");
});
