// The permission core (src/permission.ts) and the support table's
// Permission column.
import { test } from "node:test";
import assert from "node:assert/strict";
import { AUTHORIZATION_STATUSES, authorization, type CallOptions, DeviceError, isGranted, SUPPORT, type SupportRow, supportTable } from "../src/mod.ts";

/** A `call` as createDevice's: unknown methods fail `unavailable`, errors become DeviceErrors. */
function caller(answers: Record<string, (options?: CallOptions) => unknown>) {
  const sent: string[] = [];
  const call = async (method: string, _params: Record<string, unknown>, options?: CallOptions) => {
    sent.push(method);
    const answer = answers[method];
    if (!answer) throw new DeviceError("unavailable", `${method} isn't available`);
    try {
      return await answer(options);
    } catch (err) {
      throw DeviceError.from(err);
    }
  };
  return { call, sent };
}

test("the trio asks <namespace>.authorizationStatus and .requestAuthorization", async () => {
  let status = "notDetermined";
  const { call, sent } = caller({
    "test.authorizationStatus": () => status,
    "test.requestAuthorization": () => (status = "authorized"),
  });
  const trio = authorization(call, "test");
  assert.equal(await trio.authorizationStatus(), "notDetermined");
  assert.equal(await trio.isAuthorized(), false);
  assert.equal(await trio.requestAuthorization(), "authorized");
  assert.equal(await trio.isAuthorized(), true);
  assert.deepEqual(sent, ["test.authorizationStatus", "test.authorizationStatus", "test.requestAuthorization", "test.authorizationStatus"]);
});

test("partial grants are grants; denied, restricted and not determined aren't", () => {
  assert.deepEqual(
    AUTHORIZATION_STATUSES.filter(isGranted),
    ["authorized", "limited", "writeOnly", "reducedAccuracy"],
  );
});

test("a status the trio doesn't know fails `failed`; a namespace the host lacks, `unavailable`", async () => {
  const { call } = caller({ "test.authorizationStatus": () => "maybe" });
  await assert.rejects(authorization(call, "test").authorizationStatus(), (err: DeviceError) => err.code === "failed");
  await assert.rejects(authorization(call, "other").requestAuthorization(), (err: DeviceError) => err.code === "unavailable");
});

test("a host's `denied` reaches the cell as a DeviceError", async () => {
  const { call } = caller({
    "test.read": () => {
      throw Object.assign(new Error("test permission is denied"), { name: "DeviceError", code: "denied" });
    },
  });
  await assert.rejects(call("test.read", {}), (err: unknown) => err instanceof DeviceError && err.code === "denied");
});

test("a cancelled request rejects `cancelled`", async () => {
  const { call } = caller({
    "test.requestAuthorization": (options) =>
      new Promise((_, reject) => options?.signal?.addEventListener("abort", () => reject(options.signal!.reason))),
  });
  const controller = new AbortController();
  const asking = authorization(call, "test").requestAuthorization({ signal: controller.signal });
  controller.abort();
  await assert.rejects(asking, (err: DeviceError) => err.code === "cancelled");
});

test("a permissioned method is on-device only", () => {
  for (const [method, row] of Object.entries(SUPPORT) as [string, SupportRow][]) {
    if (!row.permission) continue;
    assert.equal(row.remote, "no", `${method} needs ${row.permission}, so remote kernels can't call it`);
    assert.equal(row.browser, "no", `${method} needs ${row.permission}, so browsers can't call it`);
  }
});

test("supportTable shows a Permission column once a method needs one", () => {
  const plain: Record<string, SupportRow> = {
    "clipboard.readText": { call: "clipboard.readText()", returns: "text", onDevice: "yes", remote: "yes", browser: "yes" },
  };
  assert.ok(!supportTable(plain).includes("Permission"));
  const table = supportTable({
    ...plain,
    "location.current": { call: "location.current()", returns: "a fix", onDevice: "yes", permission: "location", remote: "no", browser: "no" },
  });
  const lines = table.split("\n");
  assert.equal(lines[0], "| Method | Returns | In the app | Permission | Remote kernel | Browser |");
  assert.equal(lines[1], "| --- | --- | --- | --- | --- | --- |");
  assert.equal(lines[2], "| `device.clipboard.readText()` | text | yes | none | yes | yes |");
  assert.equal(lines[3], "| `device.location.current()` | a fix | yes | location | no | no |");
});
