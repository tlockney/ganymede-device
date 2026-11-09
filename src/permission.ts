// The permission core (docs/protocol.md, "Permissions"): the trio every
// permissioned namespace has, `authorizationStatus()`, `isAuthorized()` and
// `requestAuthorization()`, after Juno's. The host answers
// `<namespace>.authorizationStatus` and `<namespace>.requestAuthorization`;
// the namespace's other methods ask lazily, and reject `denied` without a
// grant.

import type { CallOptions } from "./device.ts";
import { DeviceError } from "./errors.ts";

/**
 * A capability's authorization. Partial grants count as granted:
 * `limited` (some contacts or photos), `writeOnly` (add reminders or
 * photos, not read them) and `reducedAccuracy` (approximate location).
 */
export type AuthorizationStatus = "notDetermined" | "denied" | "restricted" | "authorized" | "limited" | "writeOnly" | "reducedAccuracy";

export const AUTHORIZATION_STATUSES: readonly AuthorizationStatus[] = ["notDetermined", "denied", "restricted", "authorized", "limited", "writeOnly", "reducedAccuracy"];

/** Whether calls that need the permission may go ahead with `status`. */
export function isGranted(status: AuthorizationStatus): boolean {
  return status === "authorized" || status === "limited" || status === "writeOnly" || status === "reducedAccuracy";
}

/** The trio on every permissioned namespace, such as `device.location`. */
export interface Authorization {
  /**
   * Reads the permission's status, without asking.
   *
   * @param options The call's `signal`. Cancel rejects `cancelled`.
   * @returns `"notDetermined"` until the person is asked, then a grant (`"authorized"`, or a partial one) or `"denied"` or `"restricted"`.
   * @example
   * ```ts
   * console.log(await device.notifications.authorizationStatus());
   * ```
   */
  authorizationStatus(options?: CallOptions): Promise<AuthorizationStatus>;
  /**
   * Whether the permission is granted, without asking.
   *
   * @param options The call's `signal`. Cancel rejects `cancelled`.
   * @returns `true` when the status is a grant, partial ones included.
   * @example
   * ```ts
   * if (!(await device.notifications.isAuthorized())) console.log("notifications are off");
   * ```
   */
  isAuthorized(options?: CallOptions): Promise<boolean>;
  /**
   * Shows the system prompt when the person hasn't been asked, and
   * resolves with the status after it; otherwise resolves with the status
   * as it is. The namespace's methods ask on their own, so calling this
   * first is optional. Cancel rejects `cancelled`; a system prompt already
   * up stays, and its answer still counts for later calls.
   *
   * @param options The call's `signal`.
   * @returns The status after the prompt, or as it was when the person had already been asked.
   * @example
   * ```ts
   * const status = await device.notifications.requestAuthorization();
   * if (status === "denied") console.log("turn notifications on in Settings");
   * ```
   */
  requestAuthorization(options?: CallOptions): Promise<AuthorizationStatus>;
}

type Call = (method: string, params: Record<string, unknown>, options?: CallOptions) => Promise<unknown>;

/** The trio for `namespace`, over `call` (which checks `has()` and makes errors DeviceErrors). */
export function authorization(call: Call, namespace: string): Authorization {
  async function ask(method: string, options?: CallOptions): Promise<AuthorizationStatus> {
    const status = await call(`${namespace}.${method}`, {}, options);
    if (typeof status !== "string" || !(AUTHORIZATION_STATUSES as readonly string[]).includes(status)) {
      throw new DeviceError("failed", `the host's ${namespace}.${method} reply is malformed`);
    }
    return status as AuthorizationStatus;
  }
  return {
    authorizationStatus: (options) => ask("authorizationStatus", options),
    isAuthorized: async (options) => isGranted(await ask("authorizationStatus", options)),
    requestAuthorization: (options) => ask("requestAuthorization", options),
  };
}
