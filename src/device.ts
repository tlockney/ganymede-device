// The `device` object cells use. It knows nothing about where it runs: every
// call goes through a DeviceTransport, which each kernel placement supplies
// (a Worker's host channel today; a host function in an embedded engine, or
// a Jupyter comm for remote kernels, later). See docs/protocol.md.

import { type Bytes, MAX_BINARY_BYTES, toBytes } from "./binary.ts";
import { DeviceError } from "./errors.ts";
import { type Authorization, authorization } from "./permission.ts";
import { type DeviceStream, openStream } from "./stream.ts";

/**
 * Every method takes these. Aborting `signal`, or interrupting the kernel,
 * cancels the call: it rejects with a `DeviceError` whose code is
 * `cancelled` (`timeout` for `AbortSignal.timeout()`), and the host drops
 * any dialog or prompt it showed for it.
 *
 * Where each method works is in `SUPPORT` (src/support.ts); the docs'
 * table and the reference's Availability lines are generated from it.
 */
export interface CallOptions {
  /** Cancels the call when aborted. In a cdp-kernel cell, `jupyter.signal` aborts when the cell is interrupted. */
  signal?: AbortSignal;
}

/** Carries one request to the native host and back. */
export interface DeviceTransport {
  call(method: string, params: Record<string, unknown>, options?: CallOptions): Promise<unknown>;
}

/** What the host answers to `hello`, once, before the first cell, and the current state when it answers `info`. */
export interface DeviceInfo {
  /** `"macos"`, `"ipados"`, `"ios"` or `"browser"`. */
  platform: string;
  /** The app's version, such as `"0.5.0"`. */
  appVersion: string;
  /** The hardware model identifier, such as `"Mac14,2"` or `"iPad13,4"`. */
  model?: string;
  /** The operating system's version, such as `"26.1.0"`. */
  osVersion?: string;
  /** The methods this host answers, such as `"clipboard.readText"`. */
  capabilities: string[];
  /** True on an iPad. This and the properties after it are read when `info()` is called, on hosts that answer it. */
  isPad?: boolean;
  /** The main screen in points, and its points-to-pixels scale. */
  screen?: { width: number; height: number; scale: number };
  /** Absent on a device without a battery. `level` is 0 to 1, or null when unknown. */
  battery?: { level: number | null; charging: boolean };
  /** Whether the system appearance is dark. */
  darkMode?: boolean;
  /** The person's locale as a BCP 47 tag, such as `"en-US"`. */
  locale?: string;
}

/** The strength of a `haptics.impact` tap. */
export type ImpactStyle = "light" | "medium" | "heavy" | "soft" | "rigid";
/** The pattern `haptics.notification` plays. */
export type NotificationFeedback = "success" | "warning" | "error";

/**
 * Taptic feedback. iPhone only: iPads and Macs have no Taptic Engine, so
 * there `device.has("haptics.impact")` is false and calls fail
 * `unavailable`.
 */
export interface Haptics {
  /**
   * Plays a tap.
   *
   * @param style How strong a tap: `"light"`, `"medium"` (the default), `"heavy"`, `"soft"` or `"rigid"`.
   * @param options The call's `signal`. Cancel rejects `cancelled`; the tap may already have played.
   * @example
   * ```ts
   * if (device.has("haptics.impact")) await device.haptics.impact("heavy");
   * ```
   */
  impact(style?: ImpactStyle, options?: CallOptions): Promise<void>;
  /**
   * Plays the system's success, warning or error pattern.
   *
   * @param type `"success"`, `"warning"` or `"error"`.
   * @param options The call's `signal`. Cancel rejects `cancelled`.
   * @example
   * ```ts
   * await device.haptics.notification("success");
   * ```
   */
  notification(type: NotificationFeedback, options?: CallOptions): Promise<void>;
  /**
   * Plays the tick of a picker moving to a new value.
   *
   * @param options The call's `signal`. Cancel rejects `cancelled`.
   * @example
   * ```ts
   * for (let i = 0; i < 3; i++) {
   *   await device.haptics.selection();
   *   await new Promise((done) => setTimeout(done, 200));
   * }
   * ```
   */
  selection(options?: CallOptions): Promise<void>;
}

/** Options for `device.openURL`. */
export interface OpenURLOptions extends CallOptions {
  /** On iPhone and iPad, show a web page in the app (Safari view) instead of switching to Safari. Ignored on the Mac. */
  inApp?: boolean;
}

/** The system clipboard. iPadOS may show its paste prompt on a read. */
export interface Clipboard {
  /**
   * Reads the clipboard's text.
   *
   * @param options The call's `signal`. Cancel rejects `cancelled`.
   * @returns The text, or `null` when the clipboard holds none.
   * @example
   * ```ts
   * const text = await device.clipboard.readText();
   * if (text !== null) console.log(text.split(/\s+/).length, "words");
   * ```
   */
  readText(options?: CallOptions): Promise<string | null>;
  /**
   * Replaces the clipboard's contents with `text`.
   *
   * @param text The text to copy.
   * @param options The call's `signal`. Cancel rejects `cancelled`; the write may already have happened.
   * @example
   * ```ts
   * await device.clipboard.writeText(JSON.stringify({ rows: 3 }, null, 2));
   * ```
   */
  writeText(text: string, options?: CallOptions): Promise<void>;
  /**
   * Reads the clipboard's image as PNG bytes, whatever format was copied.
   *
   * @param options The call's `signal`. Cancel rejects `cancelled`.
   * @returns PNG bytes, or `null` when the clipboard holds no image.
   * @example
   * ```ts
   * const png = await device.clipboard.readImage();
   * if (png) console.log(`${png.byteLength} bytes`);
   * ```
   */
  readImage(options?: CallOptions): Promise<Uint8Array | null>;
  /**
   * Replaces the clipboard's contents with an image.
   *
   * @param image PNG, JPEG, GIF, HEIC or TIFF bytes, at most 16 MiB.
   * @param options The call's `signal`. Cancel rejects `cancelled`; the write may already have happened.
   * @throws {DeviceError} `failed` when the bytes aren't an image the device reads.
   * @example
   * ```ts
   * const [photo] = await device.photos.pick();
   * if (photo) await device.clipboard.writeImage(photo);
   * ```
   */
  writeImage(image: Bytes, options?: CallOptions): Promise<void>;
}

/** Options for `device.ui.alert`. */
export interface AlertOptions extends CallOptions {
  /** A heading above the message. */
  title?: string;
}

/** Options for `device.ui.confirm`. */
export interface ConfirmOptions extends AlertOptions {
  /** Shows the confirming button as destructive (red). */
  destructive?: boolean;
  /** The confirming button's label; "OK" by default. */
  okLabel?: string;
}

/** Options for `device.ui.prompt`. */
export interface PromptOptions extends AlertOptions {
  /** Grey text shown while the field is empty. */
  placeholder?: string;
  /** Text the field starts with. */
  defaultValue?: string;
  /** Hides what is typed, as for a password. */
  secure?: boolean;
}

/** Options for `device.ui.actionSheet`. */
export interface ActionSheetOptions extends CallOptions {
  /** A line under the title. */
  message?: string;
  /** The cancel button's label; "Cancel" by default. */
  cancel?: string;
  /** The index of an option to show as destructive (red). */
  destructive?: number;
}

/** What `device.ui.pickDate` picks. */
export type DateMode = "date" | "time" | "datetime";

/** Options for `device.ui.pickDate`. */
export interface PickDateOptions extends CallOptions {
  /** What to pick; "datetime" by default. */
  mode?: DateMode;
  /** A heading above the picker. */
  title?: string;
  /** The date the picker starts at; now by default. */
  value?: Date;
  /** The earliest date that can be picked. */
  min?: Date;
  /** The latest date that can be picked. */
  max?: Date;
}

/** A file a cell hands over: a `File`, or bytes with the name to show and save them under. */
export type NamedBytes = File | { name: string; data: Bytes };

/** What `device.share` shares: at least one of `text`, `url` and `files`. */
export interface ShareOptions extends CallOptions {
  /** Text to share, such as a message or a caption. */
  text?: string;
  /** A link to share: `http`, `https` or `mailto`. */
  url?: string | URL;
  /** Files to share, together at most 16 MiB; their names are what the receiving app sees. */
  files?: NamedBytes[];
}

/** Options for `device.files.pick`. */
export interface PickFilesOptions extends CallOptions {
  /**
   * What may be picked: MIME types (`"text/csv"`), wildcards (`"image/*"`)
   * or extensions (`".parquet"`). Anything by default.
   */
  types?: string[];
  /** Whether several files may be picked; one by default. */
  multiple?: boolean;
}

/** Options for `device.files.export`. */
export interface ExportFileOptions extends CallOptions {
  /** The name the save panel suggests: a plain file name, without slashes. */
  name: string;
}

/** Options for `device.photos.pick`. */
export interface PickPhotosOptions extends CallOptions {
  /** How many photos may be picked; 1 by default, 0 for no limit. */
  limit?: number;
}

/**
 * Files in and out through the system's own pickers, which are the
 * person's consent, so no permission. A picked file is copied in by value:
 * the notebook keeps no access to where it came from.
 */
export interface Files {
  /**
   * Shows the open panel on the Mac, or the document picker on iPad and
   * iPhone, and reads the files the person picks. Together they are at
   * most 16 MiB.
   *
   * @param options `types` limits what can be picked, `multiple` allows more than one, and `signal` cancels: it closes the picker and rejects `cancelled`.
   * @returns The picked files, with their names and MIME types, or `[]` when the person cancels.
   * @throws {DeviceError} `failed` when the files together are over 16 MiB.
   * @example
   * ```ts
   * const [file] = await device.files.pick({ types: [".csv", "text/csv"] });
   * if (file) {
   *   const rows = (await file.text()).trim().split("\n");
   *   console.log(file.name, rows.length, "rows");
   * }
   * ```
   */
  pick(options?: PickFilesOptions): Promise<File[]>;
  /**
   * Asks where to save `data`, and saves it there: the save panel on the
   * Mac, the document picker on iPad and iPhone.
   *
   * @param data The file's contents, at most 16 MiB.
   * @param options `name` is the file name the panel suggests; `signal` cancels: it closes the panel and rejects `cancelled`.
   * @returns `true` when saved, `false` when the person cancels.
   * @throws {DeviceError} `failed` when `name` isn't a plain file name, or `data` is over 16 MiB.
   * @example
   * ```ts
   * const csv = "city,temp\nOslo,4\nLima,19\n";
   * const saved = await device.files.export(new TextEncoder().encode(csv), { name: "temps.csv" });
   * console.log(saved ? "saved" : "cancelled");
   * ```
   */
  export(data: Bytes, options: ExportFileOptions): Promise<boolean>;
}

/** The photo library, through the system photo picker. */
export interface ScheduleNotificationOptions extends CallOptions {
  /** Seconds from now, more than 0. */
  delay: number;
  /** Shown above the body. */
  title?: string;
}

/** A notification this notebook scheduled that hasn't been delivered. */
export interface PendingNotification {
  /** What `schedule()` returned. */
  id: string;
  title?: string;
  body: string;
  /** When it is due, when the host knows. */
  date?: Date;
}

/**
 * Local notifications after a delay: the app posts them even when the
 * notebook or the app is closed. Delay only, no calendar times or
 * repeats. Each notification belongs to the notebook that scheduled it:
 * `pending()`, `cancel()` and `cancelAll()` see only that notebook's.
 *
 * Needs the notifications permission, for `schedule()`: the first call
 * asks (the app's prompt for this notebook, then the system's) and a
 * refusal rejects `denied`. On-device: Mac, iPad and iPhone. Remote
 * kernels and the browser: no.
 */
export interface Notifications extends Authorization {
  /**
   * Schedules `body` to show `delay` seconds from now; resolves with its
   * id. iOS and iPadOS keep at most 64 per app, dropping the soonest
   * beyond that. Cancel rejects `cancelled`; it may already be scheduled.
   */
  schedule(body: string, options: ScheduleNotificationOptions): Promise<string>;
  /** This notebook's notifications not yet delivered. Cancel rejects `cancelled`. */
  pending(options?: CallOptions): Promise<PendingNotification[]>;
  /** Takes one of this notebook's off the schedule; an id that's gone, or another notebook's, changes nothing. */
  cancel(id: string, options?: CallOptions): Promise<void>;
  /** Takes all of this notebook's off the schedule. */
  cancelAll(options?: CallOptions): Promise<void>;
}

export interface Photos {
  /**
   * Shows the system photo picker and reads the photos the person picks.
   * The picker shows the library without the app being let in, so no
   * permission. Together the photos are at most 16 MiB.
   *
   * @param options `limit` is how many may be picked (1 by default, 0 for no limit); `signal` cancels: it closes the picker and rejects `cancelled`.
   * @returns The picked photos as image `File`s in their stored format (often HEIC or JPEG), or `[]` when the person cancels.
   * @throws {DeviceError} `failed` when the photos together are over 16 MiB.
   * @example
   * ```ts
   * const photos = await device.photos.pick({ limit: 3 });
   * for (const photo of photos) console.log(photo.name, photo.type, photo.size);
   * ```
   */
  pick(options?: PickPhotosOptions): Promise<File[]>;
}

/** Options for `device.sound.play`. */
export interface PlaySoundOptions extends CallOptions {
  /** From 0 to 1; 1 by default. */
  volume?: number;
}

/** Where a player is: whether it is playing, and its time and length in seconds. */
export interface SoundState {
  /** Whether it is playing now. */
  playing: boolean;
  /** Where it is, in seconds from the start. */
  time: number;
  /** The sound's length in seconds. */
  duration: number;
}

/**
 * A loaded sound a cell controls, from `device.sound.player`. Close it when
 * done, or hold it with `await using`. The app closes a kernel's players
 * when that kernel restarts or shuts down; a kernel has at most 32 open.
 * Each method answers the player's state after the change.
 */
export interface SoundPlayer extends AsyncDisposable {
  /** The sound's length in seconds. */
  readonly duration: number;
  /**
   * Plays from the current time.
   *
   * @param options The call's `signal`.
   * @returns The player's state after the change.
   * @throws {DeviceError} `failed` when the sound can't start, or the player is closed.
   * @example
   * ```ts
   * const state = await player.play();
   * console.log(state.playing, state.duration);
   * ```
   */
  play(options?: CallOptions): Promise<SoundState>;
  /**
   * Pauses at the current time.
   *
   * @param options The call's `signal`.
   * @returns The player's state after the change.
   * @example
   * ```ts
   * const { time } = await player.pause();
   * console.log(`paused at ${time.toFixed(1)} s`);
   * ```
   */
  pause(options?: CallOptions): Promise<SoundState>;
  /**
   * Pauses and goes back to the start.
   *
   * @param options The call's `signal`.
   * @returns The player's state after the change.
   * @example
   * ```ts
   * await player.stop();
   * ```
   */
  stop(options?: CallOptions): Promise<SoundState>;
  /**
   * Moves to a time, playing or not.
   *
   * @param seconds The time to move to, in seconds from the start: 0 or more.
   * @param options The call's `signal`.
   * @returns The player's state after the change.
   * @throws {DeviceError} `failed` when `seconds` is negative or not a number.
   * @example
   * ```ts
   * await player.seek(player.duration / 2);
   * await player.play();
   * ```
   */
  seek(seconds: number, options?: CallOptions): Promise<SoundState>;
  /**
   * Sets the volume.
   *
   * @param volume From 0 to 1.
   * @param options The call's `signal`.
   * @returns The player's state after the change.
   * @throws {DeviceError} `failed` when `volume` is outside 0 to 1.
   * @example
   * ```ts
   * await player.setVolume(0.25);
   * ```
   */
  setVolume(volume: number, options?: CallOptions): Promise<SoundState>;
  /**
   * Reads the player's state, changing nothing.
   *
   * @param options The call's `signal`.
   * @returns Whether it is playing, its time and its length.
   * @example
   * ```ts
   * const { playing, time } = await player.state();
   * ```
   */
  state(options?: CallOptions): Promise<SoundState>;
  /**
   * Stops the player and frees it; later calls fail `failed`. Closing
   * twice is fine. Leaving an `await using` block closes it too.
   *
   * @example
   * ```ts
   * await player.close();
   * ```
   */
  close(): Promise<void>;
}

/**
 * Sound from bytes in any format the device reads (WAV, AIFF, MP3,
 * AAC/M4A, CAF, FLAC), at most 16 MiB. No permission. On iPhone the
 * ring/silent switch can silence it.
 */
export interface Sound {
  /**
   * Starts playing a sound, which plays to its end on its own.
   *
   * @param data The sound's bytes, at most 16 MiB.
   * @param options `volume` from 0 to 1 (1 by default), and the call's `signal`. Cancel rejects `cancelled`; the sound may already be playing.
   * @returns Once the sound has started.
   * @throws {DeviceError} `failed` when `data` is empty, over 16 MiB, or not a sound the device reads.
   * @example
   * ```ts
   * const [file] = await device.files.pick({ types: ["audio/*"] });
   * if (file) await device.sound.play(file, { volume: 0.5 });
   * ```
   */
  play(data: Bytes, options?: PlaySoundOptions): Promise<void>;
  /**
   * Loads a sound into a player, paused at the start, for a cell to play,
   * pause, seek and close. A kernel has at most 32 open at once.
   *
   * @param data The sound's bytes, at most 16 MiB.
   * @param options The call's `signal`.
   * @returns A `SoundPlayer`.
   * @throws {DeviceError} `failed` when `data` is empty, over 16 MiB, or not a sound the device reads, or the kernel has 32 players open.
   * @example
   * ```ts
   * const [file] = await device.files.pick({ types: ["audio/*"] });
   * if (file) {
   *   await using player = await device.sound.player(file);
   *   await player.play();
   *   // Leaving the block closes the player, which stops it: wait for the end.
   *   await new Promise((done) => setTimeout(done, player.duration * 1000));
   * }
   * ```
   */
  player(data: Bytes, options?: CallOptions): Promise<SoundPlayer>;
}

/**
 * Dialogs the app shows over the notebook: sheets on the Mac, alerts on
 * iPhone and iPad. One shows at a time; a second call waits for the first
 * to close. Dismissing one is not an error: it returns `null` or `false`.
 * An interrupt or an aborted `signal` closes it and rejects `cancelled`
 * (`timeout` for `AbortSignal.timeout()`).
 */
export interface UI {
  /**
   * Shows a message with an OK button.
   *
   * @param message The message.
   * @param options `title` is a heading above it; `signal` cancels: it closes the alert and rejects `cancelled`.
   * @returns Once the person closes it.
   * @example
   * ```ts
   * await device.ui.alert("The import finished: 1,204 rows.", { title: "Done" });
   * ```
   */
  alert(message: string, options?: AlertOptions): Promise<void>;
  /**
   * Asks a yes-or-no question.
   *
   * @param message The question.
   * @param options `title`, `okLabel` for the confirming button, `destructive` to show it red, and the call's `signal`.
   * @returns `true` when the person confirms, `false` when they cancel or dismiss it.
   * @example
   * ```ts
   * if (await device.ui.confirm("Delete the scratch files?", { destructive: true, okLabel: "Delete" })) {
   *   console.log("deleting");
   * }
   * ```
   */
  confirm(message: string, options?: ConfirmOptions): Promise<boolean>;
  /**
   * Asks for a line of text.
   *
   * @param message The question.
   * @param options `title`, `placeholder`, `defaultValue`, `secure` to hide what is typed, and the call's `signal`.
   * @returns The text entered, or `null` when the person cancels.
   * @example
   * ```ts
   * const name = await device.ui.prompt("Name the run", { defaultValue: "baseline" });
   * if (name !== null) console.log(`saving ${name}`);
   * ```
   */
  prompt(message: string, options?: PromptOptions): Promise<string | null>;
  /**
   * Asks the person to choose one of several options.
   *
   * @param title The sheet's heading.
   * @param options The choices' labels, at least one.
   * @param sheetOptions `message` under the title, `cancel` for the cancel button's label, `destructive` for the index of an option to show red, and the call's `signal`.
   * @returns The index of the option chosen, or `null` when the person cancels.
   * @throws {DeviceError} `failed` when `options` is empty.
   * @example
   * ```ts
   * const formats = ["CSV", "JSON", "Parquet"];
   * const i = await device.ui.actionSheet("Export as", formats);
   * if (i !== null) console.log(`exporting ${formats[i]}`);
   * ```
   */
  actionSheet(title: string, options: string[], sheetOptions?: ActionSheetOptions): Promise<number | null>;
  /**
   * Asks for a date, a time, or both.
   *
   * @param options `mode` (`"date"`, `"time"` or `"datetime"`, the default), `title`, `value` to start at, `min` and `max`, and the call's `signal`.
   * @returns The date chosen, or `null` when the person cancels.
   * @throws {DeviceError} `failed` when `value`, `min` or `max` isn't a valid `Date`.
   * @example
   * ```ts
   * const start = await device.ui.pickDate({ mode: "date", title: "Report from", max: new Date() });
   * if (start) console.log(start.toISOString().slice(0, 10));
   * ```
   */
  pickDate(options?: PickDateOptions): Promise<Date | null>;
}

/**
 * The `device` global: native features of the Mac, iPad and iPhone apps.
 * Undefined on kernels the app doesn't host, so check for it first.
 */
export interface Device {
  /**
   * Reads what the host is and the device's current state.
   *
   * @param options The call's `signal`. Cancel rejects `cancelled`.
   * @returns The host's answer to `hello` as it was when the kernel started, with the current screen, battery, appearance and locale where the host reads them.
   * @example
   * ```ts
   * const info = await device.info();
   * console.log(info.platform, info.osVersion, info.battery?.level);
   * ```
   */
  info(options?: CallOptions): Promise<DeviceInfo>;
  /**
   * Whether the host answers a method. Synchronous: it reads what the host
   * said when the kernel started, so it can't be cancelled.
   *
   * @param method A method's name as `SUPPORT` lists it, such as `"clipboard.readText"` or `"openURL"`.
   * @returns `true` when the host answers it; calling a method it doesn't fails `unavailable`.
   * @example
   * ```ts
   * if (device.has("haptics.impact")) await device.haptics.impact();
   * else console.log("no haptics on", (await device.info()).platform);
   * ```
   */
  has(method: string): boolean;
  /** The system clipboard: see `Clipboard`. */
  readonly clipboard: Clipboard;
  /** Taptic feedback, on iPhone: see `Haptics`. */
  readonly haptics: Haptics;
  /**
   * Opens a link: in the browser, or the mail app for `mailto`.
   *
   * @param url An `http`, `https` or `mailto` URL.
   * @param options `inApp` shows a web page in the app on iPhone and iPad, and the call's `signal`. Cancel rejects `cancelled`; the URL may already have opened.
   * @throws {DeviceError} `failed` for any other scheme.
   * @example
   * ```ts
   * await device.openURL("https://ganymede-server.com/docs/", { inApp: true });
   * ```
   */
  openURL(url: string | URL, options?: OpenURLOptions): Promise<void>;
  /** Dialogs over the notebook: see `UI`. */
  readonly ui: UI;
  /**
   * Shows the system share sheet (`NSSharingServicePicker` on the Mac).
   * The sheet is its own consent, so no permission.
   *
   * @param options `text`, `url` and `files` to share (at least one; files together at most 16 MiB), and the call's `signal`, which closes the sheet and rejects `cancelled`.
   * @returns `true` when the person picked where to send them (on iPhone and iPad once the share completes; on the Mac as soon as they pick a service), `false` when they dismissed it.
   * @throws {DeviceError} `failed` when there is nothing to share, a file has no plain name, or the files are over 16 MiB.
   * @example
   * ```ts
   * const csv = "city,temp\nOslo,4\nLima,19\n";
   * await device.share({
   *   text: "Today's temperatures",
   *   files: [{ name: "temps.csv", data: new TextEncoder().encode(csv) }],
   * });
   * ```
   */
  share(options: ShareOptions): Promise<boolean>;
  /**
   * Shows files in Quick Look. Quick Look picks the viewer from each
   * name's extension, so name a PNG `*.png`.
   *
   * @param files The files, together at most 16 MiB.
   * @param options The call's `signal`, which closes Quick Look and rejects `cancelled`.
   * @returns Once the person closes it.
   * @throws {DeviceError} `failed` when `files` is empty, a file has no plain name, or the files are over 16 MiB.
   * @example
   * ```ts
   * const png = await device.clipboard.readImage();
   * if (png) await device.preview([{ name: "clipboard.png", data: png }]);
   * ```
   */
  preview(files: NamedBytes[], options?: CallOptions): Promise<void>;
  /** The system's file pickers: see `Files`. */
  readonly files: Files;
  /** The system photo picker: see `Photos`. */
  readonly photos: Photos;
  /** Sound playback: see `Sound`. */
  readonly sound: Sound;
  readonly notifications: Notifications;
}

/** Asks the host who it is. Rejects when there is no host to ask. */
export async function hello(transport: DeviceTransport): Promise<DeviceInfo> {
  return helloInfo(await transport.call("hello", {}));
}

/** A `hello` reply checked and tidied: a platform and a list of method names. */
export function helloInfo(info: unknown): DeviceInfo {
  if (!isRecord(info) || typeof info.platform !== "string" || !Array.isArray(info.capabilities)) {
    throw new DeviceError("failed", "the host's hello reply is malformed");
  }
  return {
    ...info,
    platform: info.platform,
    appVersion: typeof info.appVersion === "string" ? info.appVersion : "",
    capabilities: info.capabilities.filter((c): c is string => typeof c === "string"),
  };
}

export interface CreateDeviceOptions {
  /**
   * The running cell's interrupt signal (cdp-kernel's `jupyter.signal`),
   * read when a stream opens, so an interrupt stops the stream even while
   * the cell isn't waiting on it.
   */
  cellSignal?: () => AbortSignal | undefined;
}

export function createDevice(transport: DeviceTransport, info: DeviceInfo, deviceOptions: CreateDeviceOptions = {}): Device {
  const capabilities = new Set(info.capabilities);
  function requireMethod(method: string): void {
    if (!capabilities.has(method)) throw new DeviceError("unavailable", `${method} isn't available on ${info.platform}`);
  }
  async function call(method: string, params: Record<string, unknown>, options?: CallOptions): Promise<unknown> {
    requireMethod(method);
    try {
      return await transport.call(method, params, options);
    } catch (err) {
      throw DeviceError.from(err);
    }
  }
  /** A streaming method's values (src/stream.ts), for the namespaces that stream. */
  function stream<T>(method: string, params: Record<string, unknown>, options: CallOptions, read: (value: unknown) => T): DeviceStream<T> {
    requireMethod(method);
    return openStream(transport, method, params, { ...options, cellSignal: readCellSignal() }, read);
  }
  /** A permissioned namespace's trio (src/permission.ts). */
  function permission(namespace: string): Authorization {
    return authorization(call, namespace);
  }
  function readCellSignal(): AbortSignal | undefined {
    try {
      return deviceOptions.cellSignal?.();
    } catch {
      return undefined;
    }
  }
  function soundPlayer(id: number, duration: number): SoundPlayer {
    let closed = false;
    async function control(action: string, extra: Record<string, unknown>, options?: CallOptions): Promise<SoundState> {
      if (closed) throw new DeviceError("failed", "this sound player is closed");
      const state = await call("sound.control", { player: id, action, ...extra }, options);
      if (!isRecord(state)) throw new DeviceError("failed", "the host's sound.control reply is malformed");
      return { playing: state.playing === true, time: Number(state.time), duration: Number(state.duration) };
    }
    async function close(): Promise<void> {
      if (closed) return;
      // Closed only once the host has it, so a failed close can be retried.
      await call("sound.close", { player: id });
      closed = true;
    }
    return {
      duration,
      play: (options) => control("play", {}, options),
      pause: (options) => control("pause", {}, options),
      stop: (options) => control("stop", {}, options),
      seek(seconds, options) {
        if (typeof seconds !== "number" || !Number.isFinite(seconds) || seconds < 0) {
          return Promise.reject(new DeviceError("failed", "seek takes a time in seconds, 0 or more"));
        }
        return control("seek", { time: seconds }, options);
      },
      setVolume(volume, options) {
        try {
          // Required here: an omitted volume would change nothing.
          checkVolume(volume ?? NaN);
        } catch (err) {
          return Promise.reject(err);
        }
        return control("state", { volume }, options);
      },
      state: (options) => control("state", {}, options),
      close,
      [asyncDispose]: close,
    };
  }
  return {
    async info(options) {
      const snapshot = structuredClone(info);
      if (!capabilities.has("info")) return snapshot;
      const current = await call("info", {}, options);
      // What `hello` said stays as it said it: the capabilities are what
      // this device was built with.
      return {
        ...snapshot,
        ...(isRecord(current) ? current : {}),
        platform: snapshot.platform,
        appVersion: snapshot.appVersion,
        capabilities: snapshot.capabilities,
      };
    },
    has: (method) => capabilities.has(method),
    clipboard: {
      async readText(options) {
        const text = await call("clipboard.readText", {}, options);
        return typeof text === "string" ? text : null;
      },
      async writeText(text, options) {
        await call("clipboard.writeText", { text: String(text) }, options);
      },
      async readImage(options) {
        const image = await call("clipboard.readImage", {}, options);
        if (image instanceof Uint8Array) return image;
        if (image instanceof ArrayBuffer) return new Uint8Array(image);
        return null;
      },
      async writeImage(image, options) {
        // Checked first, so a host without it fails `unavailable` before a Blob is read.
        requireMethod("clipboard.writeImage");
        await call("clipboard.writeImage", { image: await toBytes(image) }, options);
      },
    },
    haptics: {
      async impact(style = "medium", options) {
        await call("haptics.impact", { style }, options);
      },
      async notification(type, options) {
        await call("haptics.notification", { type }, options);
      },
      async selection(options) {
        await call("haptics.selection", {}, options);
      },
    },
    async openURL(url, options = {}) {
      const { inApp = false, ...callOptions } = options;
      await call("openURL", { url: String(url), inApp }, callOptions);
    },
    ui: {
      async alert(message, options = {}) {
        const { signal, title } = options;
        await call("ui.alert", { message: String(message), ...defined({ title }) }, { signal });
      },
      async confirm(message, options = {}) {
        const { signal, title, destructive = false, okLabel } = options;
        const result = await call("ui.confirm", { message: String(message), destructive, ...defined({ title, okLabel }) }, { signal });
        return result === true;
      },
      async prompt(message, options = {}) {
        const { signal, title, placeholder, defaultValue, secure = false } = options;
        const result = await call("ui.prompt", { message: String(message), secure, ...defined({ title, placeholder, defaultValue }) }, { signal });
        return typeof result === "string" ? result : null;
      },
      async actionSheet(title, choices, options = {}) {
        const { signal, message, cancel, destructive } = options;
        if (!Array.isArray(choices) || choices.length === 0) throw new DeviceError("failed", "actionSheet needs at least one option");
        const params = { title: String(title), options: choices.map(String), ...defined({ message, cancel, destructive }) };
        const result = await call("ui.actionSheet", params, { signal });
        return typeof result === "number" && Number.isInteger(result) && result >= 0 && result < choices.length ? result : null;
      },
      async pickDate(options = {}) {
        const { signal, mode = "datetime", title, value, min, max } = options;
        const params = { mode, ...defined({ title, value: iso(value), min: iso(min), max: iso(max) }) };
        const result = await call("ui.pickDate", params, { signal });
        if (typeof result !== "string") return null;
        const date = new Date(result);
        if (Number.isNaN(date.getTime())) throw new DeviceError("failed", `ui.pickDate answered a date it can't read: ${result}`);
        return date;
      },
    },
    async share(options) {
      const { signal, text, url, files } = options ?? {};
      if (text === undefined && url === undefined && (files === undefined || files.length === 0)) {
        throw new DeviceError("failed", "share needs text, a url or files");
      }
      // Checked first, so a host without it fails `unavailable` before files are read.
      requireMethod("share");
      const params = {
        ...defined({ text: text === undefined ? undefined : String(text), url: url === undefined ? undefined : String(url) }),
        files: files === undefined ? [] : await namedFiles("share", files),
      };
      return (await call("share", params, { signal })) === true;
    },
    async preview(files, options = {}) {
      if (!Array.isArray(files) || files.length === 0) throw new DeviceError("failed", "preview needs at least one file");
      requireMethod("preview");
      await call("preview", { files: await namedFiles("preview", files) }, options);
    },
    files: {
      async pick(options = {}) {
        const { signal, types, multiple = false } = options;
        if (types !== undefined && (!Array.isArray(types) || types.some((t) => typeof t !== "string" || !t))) {
          throw new DeviceError("failed", "files.pick: types must be an array of MIME types or extensions");
        }
        if (typeof multiple !== "boolean") throw new DeviceError("failed", "files.pick: multiple must be a boolean");
        return pickedFiles("files.pick", await call("files.pick", { multiple, ...defined({ types }) }, { signal }));
      },
      async export(data, options) {
        const { signal, name } = options ?? ({} as ExportFileOptions);
        if (!isPlainName(name)) throw new DeviceError("failed", "files.export needs a plain file name (no slashes)");
        requireMethod("files.export");
        // toBytes refuses anything over MAX_BINARY_BYTES.
        const bytes = await toBytes(data);
        return (await call("files.export", { name, data: bytes }, { signal })) === true;
      },
    },
    sound: {
      async play(data, options = {}) {
        const { signal, volume } = options;
        checkVolume(volume);
        requireMethod("sound.play");
        await call("sound.play", { data: await audioBytes("sound.play", data), ...defined({ volume }) }, { signal });
      },
      async player(data, options = {}) {
        requireMethod("sound.player");
        const opened = await call("sound.player", { data: await audioBytes("sound.player", data) }, options);
        if (!isRecord(opened) || typeof opened.player !== "number") throw new DeviceError("failed", "the host's sound.player reply is malformed");
        return soundPlayer(opened.player, typeof opened.duration === "number" ? opened.duration : NaN);
      },
    },
    notifications: {
      ...permission("notifications"),
      async schedule(body, options) {
        const { signal, delay, title } = options ?? ({} as ScheduleNotificationOptions);
        if (typeof body !== "string" || body === "") throw new DeviceError("failed", "notifications.schedule needs a body");
        if (typeof delay !== "number" || !Number.isFinite(delay) || delay <= 0) {
          throw new DeviceError("failed", "notifications.schedule needs a delay in seconds, more than 0");
        }
        if (title !== undefined && typeof title !== "string") throw new DeviceError("failed", "notifications.schedule: title must be a string");
        const id = await call("notifications.schedule", { body, delay, ...defined({ title }) }, { signal });
        if (typeof id !== "string") throw new DeviceError("failed", "the host's notifications.schedule reply is malformed");
        return id;
      },
      async pending(options = {}) {
        const result = await call("notifications.pending", {}, options);
        if (!Array.isArray(result)) throw new DeviceError("failed", "the host's notifications.pending reply is malformed");
        return result.map((item): PendingNotification => {
          if (!isRecord(item) || typeof item.id !== "string" || typeof item.body !== "string") {
            throw new DeviceError("failed", "the host's notifications.pending reply is malformed");
          }
          const date = typeof item.date === "string" ? new Date(item.date) : undefined;
          return {
            id: item.id,
            body: item.body,
            ...(typeof item.title === "string" ? { title: item.title } : {}),
            ...(date && !Number.isNaN(date.getTime()) ? { date } : {}),
          };
        });
      },
      async cancel(id, options = {}) {
        if (typeof id !== "string" || id === "") throw new DeviceError("failed", "notifications.cancel needs the id schedule returned");
        await call("notifications.cancel", { id }, options);
      },
      async cancelAll(options = {}) {
        await call("notifications.cancelAll", {}, options);
      },
    },
    photos: {
      async pick(options = {}) {
        const { signal, limit = 1 } = options;
        if (!Number.isInteger(limit) || limit < 0) throw new DeviceError("failed", "photos.pick: limit must be a whole number, 0 for no limit");
        return pickedFiles("photos.pick", await call("photos.pick", { limit }, { signal }));
      },
    },
  };
}

/** Each file as `{ name, data }` bytes, checked for a name and a total within the binary limit. */
async function namedFiles(method: string, files: NamedBytes[]): Promise<{ name: string; data: Uint8Array }[]> {
  if (!Array.isArray(files)) throw new DeviceError("failed", `${method} takes an array of files`);
  const out: { name: string; data: Uint8Array }[] = [];
  let total = 0;
  for (const file of files) {
    const isFile = typeof File !== "undefined" && file instanceof File;
    const name = isFile ? file.name : (file as { name?: unknown })?.name;
    if (!isPlainName(name)) {
      throw new DeviceError("failed", `${method}: each file needs a plain file name (no slashes)`);
    }
    // A Blob's (or File's) size is known before reading it.
    const source = isFile ? file : (file as { data: Bytes }).data;
    if (typeof Blob !== "undefined" && source instanceof Blob && total + source.size > MAX_BINARY_BYTES) {
      throw new DeviceError("failed", `${method}: files together are limited to ${MAX_BINARY_BYTES} bytes`);
    }
    const data = await toBytes(source);
    total += data.byteLength;
    if (total > MAX_BINARY_BYTES) {
      throw new DeviceError("failed", `${method}: files together are limited to ${MAX_BINARY_BYTES} bytes`);
    }
    out.push({ name, data });
  }
  return out;
}

// Symbol.asyncDispose where the engine has it; the registered symbol
// TypeScript's `using` downlevel looks for otherwise.
const asyncDispose: typeof Symbol.asyncDispose = Symbol.asyncDispose ?? (Symbol.for("Symbol.asyncDispose") as typeof Symbol.asyncDispose);

function checkVolume(volume: unknown): void {
  if (volume !== undefined && (typeof volume !== "number" || !(volume >= 0 && volume <= 1))) {
    throw new DeviceError("failed", "volume must be a number from 0 to 1");
  }
}

/** Sound bytes, checked against the binary limit before the host is asked. */
async function audioBytes(method: string, data: Bytes): Promise<Uint8Array> {
  const bytes = await toBytes(data);
  if (bytes.byteLength === 0) throw new DeviceError("failed", `${method} needs some bytes`);
  if (bytes.byteLength > MAX_BINARY_BYTES) throw new DeviceError("failed", `${method}: sounds are limited to ${MAX_BINARY_BYTES} bytes`);
  return bytes;
}

/** A name a file can be saved under as it is: no slashes, NUL, `.` or `..`. */
function isPlainName(name: unknown): name is string {
  return typeof name === "string" && name.trim() !== "" && name !== "." && name !== ".." && !/[/\\\0]/.test(name);
}

/** The host's `[{ name, type, data }]` as `File`s; anything else is no files. */
function pickedFiles(method: string, result: unknown): File[] {
  if (!Array.isArray(result)) return [];
  return result.map((item) => {
    if (!isRecord(item) || typeof item.name !== "string" || !(item.data instanceof Uint8Array)) {
      throw new DeviceError("failed", `${method} answered a file it can't read`);
    }
    const type = typeof item.type === "string" ? item.type : "";
    return new File([item.data as Uint8Array<ArrayBuffer>], item.name, { type });
  });
}

/** `fields` without its undefined values, so they aren't sent. */
function defined(fields: Record<string, unknown>): Record<string, unknown> {
  return Object.fromEntries(Object.entries(fields).filter(([, v]) => v !== undefined));
}

/** A date as the ISO 8601 string the host reads, or undefined. */
function iso(date: Date | undefined): string | undefined {
  if (date === undefined) return undefined;
  if (!(date instanceof Date) || Number.isNaN(date.getTime())) throw new DeviceError("failed", "pickDate takes Date values");
  return date.toISOString();
}

/** A Device whose every call rejects `unavailable`: what `import` gives on a kernel with no host. */
export function unavailableDevice(): Device {
  const transport: DeviceTransport = { call: () => Promise.reject(new DeviceError("unavailable", "this kernel has no device host")) };
  return createDevice(transport, { platform: "none", appVersion: "", capabilities: [] });
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
