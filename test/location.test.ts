// device.location over a fake transport: what crosses the wire, and how
// replies are read. The stream's own behaviour is in stream.test.ts.
import { test } from "node:test";
import assert from "node:assert/strict";
import { createDevice, DeviceError, type DeviceTransport } from "../src/mod.ts";

const METHODS = [
  "location.authorizationStatus",
  "location.requestAuthorization",
  "location.current",
  "location.watch",
  "location.geocode",
  "location.reverseGeocode",
];

function host(answers: Record<string, (params: Record<string, unknown>) => unknown>, capabilities = METHODS) {
  const sent: { method: string; params: Record<string, unknown> }[] = [];
  const transport: DeviceTransport = {
    async call(method, params) {
      sent.push({ method, params });
      const answer = answers[method];
      if (!answer) throw new DeviceError("unavailable", `no ${method}`);
      return answer(params);
    },
  };
  return { device: createDevice(transport, { platform: "macos", appVersion: "", capabilities }), sent };
}

const isCode = (code: string) => (err: unknown) => err instanceof DeviceError && err.code === code;
const FIX = { latitude: 48.85, longitude: 2.35, accuracy: 5, timestamp: 1_700_000_000_000 };

test("current sends the accuracy and reads the fix, keeping only numeric extras", async () => {
  const { device, sent } = host({
    "location.current": () => ({ ...FIX, altitude: 35, speed: "fast", course: null, extra: 1 }),
  });
  assert.deepEqual(await device.location.current({ accuracy: "city" }), { ...FIX, altitude: 35 });
  await device.location.current();
  assert.deepEqual(sent, [
    { method: "location.current", params: { accuracy: "city" } },
    { method: "location.current", params: {} },
  ]);
});

test("current and watch check the accuracy before asking the host", async () => {
  const { device, sent } = host({ "location.current": () => FIX });
  await assert.rejects(device.location.current({ accuracy: "street" as "city" }), isCode("failed"));
  assert.throws(() => device.location.watch({ accuracy: 3 as unknown as "city" }), isCode("failed"));
  assert.equal(sent.length, 0);
});

test("a malformed fix fails", async () => {
  for (const reply of [null, {}, { ...FIX, latitude: 91 }, { ...FIX, accuracy: "5" }, { ...FIX, timestamp: undefined }]) {
    const { device } = host({ "location.current": () => reply });
    await assert.rejects(device.location.current(), isCode("failed"));
  }
});

test("watch streams fixes, and leaving the loop closes it", async () => {
  let reads = 0;
  const { device, sent } = host({
    "location.watch": () => ({ stream: 9 }),
    "stream.next": () => (reads++ === 0 ? { values: [FIX, { ...FIX, latitude: 1 }], dropped: 0 } : { values: [], dropped: 0, end: true }),
    "stream.close": () => null,
  });
  const got: number[] = [];
  for await (const fix of device.location.watch({ accuracy: "block" })) {
    got.push(fix.latitude);
    if (got.length === 2) break;
  }
  assert.deepEqual(got, [48.85, 1]);
  assert.deepEqual(sent[0], { method: "location.watch", params: { accuracy: "block" } });
  assert.deepEqual(sent.at(-1), { method: "stream.close", params: { stream: 9 } });
});

test("geocode and reverseGeocode send their arguments and read places", async () => {
  const place = { name: "Eiffel Tower", city: "Paris", country: "France", countryCode: "FR", latitude: 48.86, longitude: 2.29 };
  const { device, sent } = host({
    "location.geocode": () => [place, { street: "", region: 5, latitude: 200, longitude: 0 }],
    "location.reverseGeocode": () => [place],
  });
  assert.deepEqual(await device.location.geocode("Champ de Mars"), [place, {}]);
  assert.deepEqual(await device.location.reverseGeocode(FIX), [place]);
  assert.deepEqual(sent, [
    { method: "location.geocode", params: { address: "Champ de Mars" } },
    { method: "location.reverseGeocode", params: { latitude: 48.85, longitude: 2.35 } },
  ]);
});

test("geocoding checks its arguments and replies", async () => {
  const { device, sent } = host({ "location.geocode": () => "nope" });
  await assert.rejects(device.location.geocode("  "), isCode("failed"));
  await assert.rejects(device.location.reverseGeocode({ latitude: 0, longitude: 181 }), isCode("failed"));
  await assert.rejects(device.location.reverseGeocode(undefined as unknown as { latitude: number; longitude: number }), isCode("failed"));
  assert.equal(sent.length, 0);
  await assert.rejects(device.location.geocode("Paris"), isCode("failed"));
});

test("the trio is there, and a host without location says unavailable", async () => {
  const { device } = host({ "location.authorizationStatus": () => "reducedAccuracy" });
  assert.equal(await device.location.authorizationStatus(), "reducedAccuracy");
  const bare = host({}, []).device;
  assert.equal(bare.has("location.current"), false);
  await assert.rejects(bare.location.current(), isCode("unavailable"));
  assert.throws(() => bare.location.watch(), isCode("unavailable"));
});
