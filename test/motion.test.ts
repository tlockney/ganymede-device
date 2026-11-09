// device.motion over a fake transport: what crosses the wire, and how
// replies are read. The stream's own behaviour is in stream.test.ts.
import { test } from "node:test";
import assert from "node:assert/strict";
import { createDevice, DeviceError, type DeviceTransport } from "../src/mod.ts";

const METHODS = ["motion.authorizationStatus", "motion.requestAuthorization", "motion.watch", "motion.latest"];

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
  return { device: createDevice(transport, { platform: "ipados", appVersion: "", capabilities }), sent };
}

const isCode = (code: string) => (err: unknown) => err instanceof DeviceError && err.code === code;
const SAMPLE = {
  attitude: { roll: 0.1, pitch: 0.2, yaw: 0.3 },
  rotationRate: { x: 0, y: 0, z: 1 },
  gravity: { x: 0, y: -1, z: 0 },
  userAcceleration: { x: 0.01, y: 0, z: 0 },
  timestamp: 1_700_000_000_000,
};

test("latest reads a sample", async () => {
  const { device, sent } = host({ "motion.latest": () => SAMPLE });
  assert.deepEqual(await device.motion.latest(), SAMPLE);
  assert.deepEqual(sent, [{ method: "motion.latest", params: {} }]);
});

test("a malformed sample fails", async () => {
  for (const reply of [null, {}, { ...SAMPLE, gravity: { x: 0, y: "1", z: 0 } }, { ...SAMPLE, attitude: undefined }, { ...SAMPLE, timestamp: NaN }]) {
    const { device } = host({ "motion.latest": () => reply });
    await assert.rejects(device.motion.latest(), isCode("failed"));
  }
});

test("watch sends the interval, streams samples, and closes when the loop ends", async () => {
  const { device, sent } = host({
    "motion.watch": () => ({ stream: 4 }),
    "stream.next": () => ({ values: [SAMPLE, SAMPLE], dropped: 0 }),
    "stream.close": () => null,
  });
  let n = 0;
  for await (const sample of device.motion.watch({ interval: 0.05 })) {
    assert.equal(sample.attitude.yaw, 0.3);
    if (++n === 2) break;
  }
  assert.deepEqual(sent[0], { method: "motion.watch", params: { interval: 0.05 } });
  assert.deepEqual(sent.at(-1), { method: "stream.close", params: { stream: 4 } });
});

test("watch checks the interval before asking the host", () => {
  const { device, sent } = host({});
  for (const interval of [0, 0.001, 2, NaN, "0.1" as unknown as number]) {
    assert.throws(() => device.motion.watch({ interval }), isCode("failed"));
  }
  assert.equal(sent.length, 0);
});

test("a Mac lists no motion: every call is unavailable", async () => {
  const { device } = host({}, []);
  assert.equal(device.has("motion.watch"), false);
  await assert.rejects(device.motion.latest(), isCode("unavailable"));
  assert.throws(() => device.motion.watch(), isCode("unavailable"));
});
