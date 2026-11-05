// @tlockney/ganymede-device: the `device` API for TypeScript notebooks in the
// Ganymede Mac and iPad apps. See README.md and docs/protocol.md.

export {
  type ActionSheetOptions,
  type AlertOptions,
  type CallOptions,
  type Clipboard,
  type ConfirmOptions,
  createDevice,
  type DateMode,
  type Device,
  type DeviceInfo,
  type DeviceTransport,
  type ExportFileOptions,
  type Files,
  hello,
  type NamedBytes,
  type Photos,
  type PickDateOptions,
  type PickFilesOptions,
  type PickPhotosOptions,
  type PlaySoundOptions,
  type PromptOptions,
  type ShareOptions,
  type Sound,
  type SoundPlayer,
  type SoundState,
  type UI,
  unavailableDevice,
} from "./device.ts";
export { type Bytes, MAX_BINARY_BYTES } from "./binary.ts";
export { DeviceError, type DeviceErrorCode } from "./errors.ts";
export { type Method, SUPPORT, type Support, type SupportRow, supportTable } from "./support.ts";
