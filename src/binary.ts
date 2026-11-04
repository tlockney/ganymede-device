// Binary values. Inside the kernel they are bytes (`Uint8Array`), and the
// Worker's postMessage copies them. The WebKit hop to Swift carries only
// property-list values, so webkitHost() turns bytes into `{ base64 }`
// objects on the way out and back into `Uint8Array`s on the way in
// (docs/protocol.md, "Binary values").

import { DeviceError } from "./errors.ts";

/** Bytes a device method takes. */
export type Bytes = Uint8Array | ArrayBuffer | Blob;

/**
 * The largest binary value one call carries, either way: 16 MiB. Base64
 * grows it by a third and WebKit copies it twice more, so the limit keeps
 * one call well short of what a web content process can hold.
 */
export const MAX_BINARY_BYTES = 16 * 1024 * 1024;

/** `value` as a `Uint8Array`, or a `failed` DeviceError when it isn't bytes or is over the limit. */
export async function toBytes(value: Bytes): Promise<Uint8Array> {
  let bytes: Uint8Array;
  if (value instanceof Uint8Array) bytes = value;
  else if (value instanceof ArrayBuffer) bytes = new Uint8Array(value);
  else if (typeof Blob !== "undefined" && value instanceof Blob) {
    checkSize(value.size);
    bytes = new Uint8Array(await value.arrayBuffer());
  } else throw new DeviceError("failed", "expected a Uint8Array, ArrayBuffer or Blob");
  checkSize(bytes.byteLength);
  return bytes;
}

/** `value` with every `Uint8Array`, `ArrayBuffer` and `Blob` in it replaced by `{ base64 }`. */
export async function encodeBinary(value: unknown): Promise<unknown> {
  if (value instanceof Uint8Array || value instanceof ArrayBuffer || (typeof Blob !== "undefined" && value instanceof Blob)) {
    return { base64: encodeBase64(await toBytes(value)) };
  }
  if (ArrayBuffer.isView(value)) {
    // Another typed array or a DataView: its bytes, as they lie in memory.
    return { base64: encodeBase64(await toBytes(new Uint8Array(value.buffer, value.byteOffset, value.byteLength))) };
  }
  if (Array.isArray(value)) return Promise.all(value.map(encodeBinary));
  if (isPlainObject(value)) {
    const out: Record<string, unknown> = {};
    for (const [key, item] of Object.entries(value)) out[key] = await encodeBinary(item);
    return out;
  }
  return value;
}

/** `value` with every `{ base64 }` object (that key alone, a string) replaced by a `Uint8Array`. */
export function decodeBinary(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(decodeBinary);
  if (isPlainObject(value)) {
    const keys = Object.keys(value);
    if (keys.length === 1 && keys[0] === "base64" && typeof value.base64 === "string") return decodeBase64(value.base64);
    const out: Record<string, unknown> = {};
    for (const [key, item] of Object.entries(value)) out[key] = decodeBinary(item);
    return out;
  }
  return value;
}

// Uint8Array.prototype.toBase64 and Uint8Array.fromBase64 (Safari 18.2,
// Node 25); btoa and atob elsewhere.
type Base64Native = {
  toBase64?: (this: Uint8Array) => string;
};
type Base64Static = { fromBase64?: (text: string) => Uint8Array };

const ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
/** Every 12-bit value as its two base64 characters. */
const PAIRS: string[] = Array.from({ length: 4096 }, (_, n) => ALPHABET[n >> 6] + ALPHABET[n & 63]);

export function encodeBase64(bytes: Uint8Array): string {
  const native = (Uint8Array.prototype as Base64Native).toBase64;
  if (native) return native.call(bytes);
  // A table lookup per 3 bytes: btoa needs a byte string first, which
  // costs more than encoding directly.
  const out: string[] = [];
  const full = bytes.length - (bytes.length % 3);
  for (let start = 0; start < full; start += 0x6000) {
    const end = Math.min(start + 0x6000, full);
    const chunk = new Array<string>((end - start) / 3);
    for (let i = start, j = 0; i < end; i += 3, j++) {
      const n = (bytes[i] << 16) | (bytes[i + 1] << 8) | bytes[i + 2];
      chunk[j] = PAIRS[n >> 12] + PAIRS[n & 0xfff];
    }
    out.push(chunk.join(""));
  }
  const rest = bytes.length - full;
  if (rest === 1) {
    const n = bytes[full] << 16;
    out.push(PAIRS[n >> 12] + "==");
  } else if (rest === 2) {
    const n = (bytes[full] << 16) | (bytes[full + 1] << 8);
    out.push(PAIRS[n >> 12] + ALPHABET[(n >> 6) & 63] + "=");
  }
  return out.join("");
}

export function decodeBase64(text: string): Uint8Array {
  // Every 4 characters are 3 bytes, less the padding; check before decoding.
  const padding = text.endsWith("==") ? 2 : text.endsWith("=") ? 1 : 0;
  checkSize(Math.floor((text.length * 3) / 4) - padding);
  const native = (Uint8Array as Base64Static).fromBase64;
  try {
    if (native) return native(text);
    const binary = atob(text);
    const bytes = new Uint8Array(binary.length);
    for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
    return bytes;
  } catch {
    throw new DeviceError("failed", "the host sent malformed base64");
  }
}

function checkSize(size: number): void {
  if (size > MAX_BINARY_BYTES) {
    throw new DeviceError("failed", `binary values are limited to ${MAX_BINARY_BYTES} bytes; this one is ${size}`);
  }
}

function isPlainObject(value: unknown): value is Record<string, unknown> {
  if (typeof value !== "object" || value === null) return false;
  const proto = Object.getPrototypeOf(value);
  return proto === Object.prototype || proto === null;
}
