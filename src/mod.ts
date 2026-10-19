// @tlockney/ganymede-device: the `device` API for TypeScript notebooks in the
// Ganymede Mac and iPad apps. See README.md and docs/protocol.md.

export { type CallOptions, type Clipboard, createDevice, type Device, type DeviceInfo, type DeviceTransport, hello, unavailableDevice } from "./device.ts";
export { DeviceError, type DeviceErrorCode } from "./errors.ts";
export { type Method, SUPPORT, type Support, type SupportRow } from "./support.ts";
