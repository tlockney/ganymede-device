/**
 * Ambient types for notebook cells in the Mac and iPad apps: the `device`
 * global the preload module installs. Load it once per project, for example
 * with `/// <reference types="@tlockney/ganymede-device/globals" />`.
 *
 * `device` is undefined on kernels the app doesn't host.
 *
 * @module
 */

import type { Device } from "./device.ts";

export type { Device };

declare global {
  /** Native features of the Mac or iPad app. Undefined on kernels the app does not host. */
  var device: Device;
}
