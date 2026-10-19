/** Why a `device` call failed. A person dismissing a picker or dialog is not an error. */
export type DeviceErrorCode =
  /** No native host, or this platform doesn't have the feature. */
  | "unavailable"
  /** The person or the system refused permission. */
  | "denied"
  /** Interrupted or aborted before the host answered. */
  | "cancelled"
  | "timeout"
  | "failed"
  /** The peer went away mid-call, such as a Bluetooth device or a remote link. */
  | "disconnected";

const CODES: ReadonlySet<string> = new Set(["unavailable", "denied", "cancelled", "timeout", "failed", "disconnected"]);

export class DeviceError extends Error {
  readonly code: DeviceErrorCode;

  constructor(code: DeviceErrorCode, message: string) {
    super(message);
    this.name = "DeviceError";
    this.code = code;
  }

  /**
   * The DeviceError an error stands for. A host's error loses its class
   * crossing postMessage but keeps `name`, `message` and `code`; an abort
   * becomes `cancelled`, anything else `failed`.
   */
  static from(err: unknown): DeviceError {
    if (err instanceof DeviceError) return err;
    const e = err as { name?: unknown; message?: unknown; code?: unknown } | null;
    const message = typeof e?.message === "string" ? e.message : String(err);
    if (e?.name === "AbortError") return new DeviceError("cancelled", message);
    if (typeof e?.code === "string" && CODES.has(e.code)) return new DeviceError(e.code as DeviceErrorCode, message);
    return new DeviceError("failed", message);
  }
}
