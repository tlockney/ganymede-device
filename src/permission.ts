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
  /** The current status, without asking. Cancel rejects `cancelled`. */
  authorizationStatus(options?: CallOptions): Promise<AuthorizationStatus>;
  /** True when the status is a grant, partial ones included. Cancel rejects `cancelled`. */
  isAuthorized(options?: CallOptions): Promise<boolean>;
  /**
   * Shows the system prompt when the person hasn't been asked, and
   * resolves with the status after it; otherwise resolves with the status
   * as it is. The namespace's methods ask on their own, so calling this
   * first is optional. Cancel rejects `cancelled`; a system prompt already
   * up stays, and its answer still counts for later calls.
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
