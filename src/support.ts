// Which methods work where: the one table the docs, `has()` tests and the
// conformance suite read, so they can't drift (docs/plan.md, "Documentation").
// `supportTable()` renders it as the Markdown table and notes in ganymede-ui's
// docs/device.md, and a test there fails when the two differ.

/**
 * Where a method works today: "yes" it ships, "planned" it doesn't yet but
 * will, "no" it can't (the platform has no such API).
 */
export type Support = "yes" | "planned" | "no";

export interface SupportRow {
  /** The call as the docs show it, without the leading `device.`. */
  call: string;
  /** What the call resolves to, for the docs. */
  returns: string;
  /** An on-device kernel in the Mac, iPad or iPhone app. */
  onDevice: Support;
  /** Shown instead of "yes" on-device when only some devices have it, such as "iPhone". */
  devices?: string;
  /** A remote kernel driven from the app: only features that need no permission. */
  remote: Support;
  /** A remote kernel driven from a browser, through web APIs. */
  browser: Support;
  /** The browser lets a page call it only after a click on a prompt the page shows. */
  browserClick?: boolean;
  /**
   * The system permission the call needs on-device, such as "location",
   * the namespace whose trio (`authorizationStatus()`,
   * `requestAuthorization()`) covers it. A permissioned method is `no` for
   * remote kernels and browsers. None when absent.
   */
  permission?: string;
  /** Why a column is "no", or what limits it, for the docs' footnotes. */
  note?: string;
}

export const SUPPORT = {
  info: {
    call: "info()",
    returns: "platform, version, methods, and the device's current state",
    onDevice: "yes",
    remote: "yes",
    browser: "yes",
    note: "A browser has no model or battery.",
  },
  "clipboard.readText": {
    call: "clipboard.readText()",
    returns: "`string`, or `null`",
    onDevice: "yes",
    remote: "yes",
    browser: "yes",
    browserClick: true,
    note: "iPadOS shows its paste prompt; a browser needs a click for the Clipboard API.",
  },
  "clipboard.writeText": {
    call: "clipboard.writeText(text)",
    returns: "nothing",
    onDevice: "yes",
    remote: "yes",
    browser: "yes",
    browserClick: true,
    note: "A browser needs a click for the Clipboard API.",
  },
  "clipboard.readImage": {
    call: "clipboard.readImage()",
    returns: "PNG bytes, or `null`",
    onDevice: "yes",
    remote: "yes",
    browser: "yes",
    browserClick: true,
    note: "PNG. iPadOS shows its paste prompt; a browser needs a click for the Clipboard API.",
  },
  "clipboard.writeImage": {
    call: "clipboard.writeImage(image)",
    returns: "nothing",
    onDevice: "yes",
    remote: "yes",
    browser: "yes",
    browserClick: true,
    note: "A browser needs a click for the Clipboard API, and takes PNG only.",
  },
  "haptics.impact": {
    call: "haptics.impact(style)",
    returns: "nothing",
    onDevice: "yes",
    devices: "iPhone",
    remote: "yes",
    browser: "no",
    note: "iPhone only: iPads and Macs have no Taptic Engine. A browser has no haptics API Safari supports.",
  },
  "haptics.notification": {
    call: "haptics.notification(type)",
    returns: "nothing",
    onDevice: "yes",
    devices: "iPhone",
    remote: "yes",
    browser: "no",
    note: "iPhone only: iPads and Macs have no Taptic Engine.",
  },
  "haptics.selection": {
    call: "haptics.selection()",
    returns: "nothing",
    onDevice: "yes",
    devices: "iPhone",
    remote: "yes",
    browser: "no",
    note: "iPhone only: iPads and Macs have no Taptic Engine.",
  },
  openURL: {
    call: "openURL(url, { inApp })",
    returns: "nothing",
    onDevice: "yes",
    remote: "yes",
    browser: "yes",
    browserClick: true,
    note: "http, https and mailto only. `inApp` works on iPhone and iPad, not the Mac; a browser opens a tab after a click, and ignores `inApp`.",
  },
  "ui.alert": {
    call: "ui.alert(message, { title })",
    returns: "nothing, once closed",
    onDevice: "yes",
    remote: "yes",
    browser: "planned",
    note: "A sheet on the Mac, an alert on iPhone and iPad; a browser will show it in the cell's output.",
  },
  "ui.confirm": {
    call: "ui.confirm(message, { title, destructive, okLabel })",
    returns: "`boolean`",
    onDevice: "yes",
    remote: "yes",
    browser: "planned",
  },
  "ui.prompt": {
    call: "ui.prompt(message, { title, placeholder, defaultValue, secure })",
    returns: "`string`, or `null`",
    onDevice: "yes",
    remote: "yes",
    browser: "planned",
  },
  "ui.actionSheet": {
    call: "ui.actionSheet(title, options, { message, cancel, destructive })",
    returns: "the option's index, or `null`",
    onDevice: "yes",
    remote: "yes",
    browser: "planned",
  },
  "ui.pickDate": {
    call: "ui.pickDate({ mode, title, value, min, max })",
    returns: "`Date`, or `null`",
    onDevice: "yes",
    remote: "yes",
    browser: "planned",
  },
  share: {
    call: "share({ text, url, files })",
    returns: "`true` when sent, `false` when dismissed",
    onDevice: "yes",
    remote: "yes",
    browser: "yes",
    browserClick: true,
    note: "The share sheet; `NSSharingServicePicker` on the Mac. A browser uses the Web Share API, after a click, and shares files only where it can.",
  },
  preview: {
    call: "preview(files)",
    returns: "nothing, once closed",
    onDevice: "yes",
    remote: "yes",
    browser: "no",
    note: "Quick Look, which picks the viewer from each file name's extension. A browser has no Quick Look.",
  },
  "files.pick": {
    call: "files.pick({ types, multiple })",
    returns: "`File[]`, `[]` when cancelled",
    onDevice: "yes",
    remote: "yes",
    browser: "yes",
    browserClick: true,
    note: "The open panel on the Mac, the document picker on iPad and iPhone. Files are copied in; no access to where they came from is kept. A browser can't filter by a type identifier such as `public.json`, so with one it allows any file.",
  },
  "files.export": {
    call: "files.export(data, { name })",
    returns: "`true` when saved, `false` when cancelled",
    onDevice: "yes",
    remote: "yes",
    browser: "yes",
    browserClick: true,
    note: "The save panel on the Mac, the document picker on iPad and iPhone. A browser downloads it after a click, and answers `true` then, since it can't tell whether it was saved.",
  },
  "sound.play": {
    call: "sound.play(data, { volume })",
    returns: "nothing, once it starts",
    onDevice: "yes",
    remote: "yes",
    browser: "yes",
    browserClick: true,
    note: "A browser asks for a click only until the page has had one.",
  },
  "sound.player": {
    call: "sound.player(data)",
    returns: "a `SoundPlayer`",
    onDevice: "yes",
    remote: "no",
    browser: "no",
    note: "Play, pause, stop, seek and volume; close it, or hold it with `await using`. Remote kernels and browsers: a handle wouldn't survive a disconnect.",
  },
  "photos.pick": {
    call: "photos.pick({ limit })",
    returns: "`File[]`, `[]` when cancelled",
    onDevice: "yes",
    remote: "yes",
    browser: "yes",
    browserClick: true,
    note: "The system photo picker, which needs no photo library permission. A browser shows a file picker for images, and keeps the first `limit` picked.",
  },
  "photos.save": {
    call: "photos.save(image)",
    returns: "nothing",
    onDevice: "yes",
    remote: "no",
    browser: "no",
    permission: "photos",
    note: "Add-only access: the app may add photos, never read the library.",
  },
  "notifications.schedule": {
    call: "notifications.schedule(body, { delay, title })",
    returns: "the notification's id",
    onDevice: "yes",
    remote: "no",
    browser: "no",
    permission: "notifications",
    note: "After `delay` seconds, even when the notebook is closed. iOS and iPadOS keep at most 64 per app.",
  },
  "notifications.pending": {
    call: "notifications.pending()",
    returns: "this notebook's `PendingNotification[]`",
    onDevice: "yes",
    remote: "no",
    browser: "no",
    note: "Only the calling notebook's.",
  },
  "notifications.cancel": {
    call: "notifications.cancel(id)",
    returns: "nothing",
    onDevice: "yes",
    remote: "no",
    browser: "no",
    note: "Only the calling notebook's.",
  },
  "notifications.cancelAll": {
    call: "notifications.cancelAll()",
    returns: "nothing",
    onDevice: "yes",
    remote: "no",
    browser: "no",
    note: "Only the calling notebook's.",
  },
  "location.current": {
    call: "location.current({ accuracy })",
    returns: "a `LocationFix`",
    onDevice: "yes",
    remote: "no",
    browser: "no",
    permission: "location",
    note: "While the app is in use only. With precise location off, within a few kilometres.",
  },
  "location.watch": {
    call: "location.watch({ accuracy })",
    returns: "a stream of `LocationFix`",
    onDevice: "yes",
    remote: "no",
    browser: "no",
    permission: "location",
    note: "Until the loop ends or the cell is interrupted; keeps the newest 16.",
  },
  "location.geocode": {
    call: "location.geocode(address)",
    returns: "`Place[]`",
    onDevice: "yes",
    remote: "no",
    browser: "no",
    note: "Needs the network, not the location permission.",
  },
  "location.reverseGeocode": {
    call: "location.reverseGeocode({ latitude, longitude })",
    returns: "`Place[]`",
    onDevice: "yes",
    remote: "no",
    browser: "no",
    note: "Needs the network, not the location permission.",
  },
  "motion.watch": {
    call: "motion.watch({ interval })",
    returns: "a stream of `MotionSample`",
    onDevice: "yes",
    devices: "iPad, iPhone",
    remote: "no",
    browser: "no",
    permission: "motion",
    note: "Attitude, rotation rate, gravity and acceleration every `interval` seconds (0.01 to 1); keeps the newest 64. A Mac has no motion sensors.",
  },
  "motion.latest": {
    call: "motion.latest()",
    returns: "the newest `MotionSample`",
    onDevice: "yes",
    devices: "iPad, iPhone",
    remote: "no",
    browser: "no",
    permission: "motion",
    note: "Starts the sensors and keeps them running while calls keep coming; they stop about 10 seconds after the last.",
  },
  "contacts.search": {
    call: "contacts.search(query)",
    returns: "`Contact[]`",
    onDevice: "yes",
    remote: "no",
    browser: "no",
    permission: "contacts",
    note: "By name, or by email or phone number when the query is one. With limited access, only the contacts shared with the app.",
  },
  "contacts.get": {
    call: "contacts.get(id)",
    returns: "a `Contact`, or `null`",
    onDevice: "yes",
    remote: "no",
    browser: "no",
    permission: "contacts",
  },
  "contacts.all": {
    call: "contacts.all()",
    returns: "`Contact[]`",
    onDevice: "yes",
    remote: "no",
    browser: "no",
    permission: "contacts",
  },
  "contacts.add": {
    call: "contacts.add(contact)",
    returns: "the new contact's id",
    onDevice: "yes",
    remote: "no",
    browser: "no",
    permission: "contacts",
    note: "To the default account; groups and accounts aren't wrapped.",
  },
  "contacts.delete": {
    call: "contacts.delete(id)",
    returns: "`true`, or `false` when there was none",
    onDevice: "yes",
    remote: "no",
    browser: "no",
    permission: "contacts",
  },
  "camera.capture": {
    call: "camera.capture()",
    returns: "JPEG bytes, or `null` when cancelled",
    onDevice: "yes",
    devices: "iPad, iPhone",
    remote: "no",
    browser: "no",
    permission: "camera",
    note: "The system camera screen. A Mac has none in the app; a browser would need its own camera view.",
  },
  "reminders.calendars": {
    call: "reminders.calendars()",
    returns: "`ReminderCalendar[]`",
    onDevice: "yes",
    remote: "no",
    browser: "no",
    permission: "reminders",
  },
  "reminders.list": {
    call: "reminders.list({ calendar, completed })",
    returns: "`Reminder[]`",
    onDevice: "yes",
    remote: "no",
    browser: "no",
    permission: "reminders",
  },
  "reminders.add": {
    call: "reminders.add(reminder)",
    returns: "the new reminder's id",
    onDevice: "yes",
    remote: "no",
    browser: "no",
    permission: "reminders",
    note: "No recurrence or alarms.",
  },
  "reminders.complete": {
    call: "reminders.complete(id)",
    returns: "`true`, or `false` when there was none",
    onDevice: "yes",
    remote: "no",
    browser: "no",
    permission: "reminders",
  },
  "reminders.uncomplete": {
    call: "reminders.uncomplete(id)",
    returns: "`true`, or `false` when there was none",
    onDevice: "yes",
    remote: "no",
    browser: "no",
    permission: "reminders",
  },
  "reminders.delete": {
    call: "reminders.delete(id)",
    returns: "`true`, or `false` when there was none",
    onDevice: "yes",
    remote: "no",
    browser: "no",
    permission: "reminders",
  },
  on: {
    call: "on(event, handler)",
    returns: "a function that removes the handler",
    onDevice: "yes",
    remote: "no",
    browser: "no",
    note: "Appearance, foreground, background, battery and locale changes; an interrupt doesn't remove a handler.",
  },
} as const satisfies Record<string, SupportRow>;

export type Method = keyof typeof SUPPORT;

export function cell(support: Support, detail?: string): string {
  if (support === "yes") return detail ?? "yes";
  return detail && support === "planned" ? `planned, ${detail}` : support;
}

/**
 * SUPPORT as Markdown: a table with one row per method, then a list of the
 * notes. A list, not footnotes, so it renders where footnotes don't
 * (VitePress without a plugin). Unpadded: run Prettier on the page that
 * embeds it.
 */
export function supportTable(support: Record<string, SupportRow> = SUPPORT): string {
  const rows: string[] = [];
  const notes: string[] = [];
  // The Permission column shows once a method needs one.
  const permissions = Object.values(support).some((row) => row.permission);
  for (const row of Object.values(support)) {
    const method = `\`device.${row.call}\``;
    const browser = cell(row.browser, row.browserClick ? "after a click" : undefined);
    const permission = permissions ? ` ${row.permission ?? "none"} |` : "";
    rows.push(`| ${method} | ${row.returns} | ${cell(row.onDevice, row.devices)} |${permission} ${cell(row.remote)} | ${browser} |`);
    if (row.note) notes.push(`- ${method}: ${row.note}`);
  }
  return [
    `| Method | Returns | In the app |${permissions ? " Permission |" : ""} Remote kernel | Browser |`,
    `| --- | --- | --- |${permissions ? " --- |" : ""} --- | --- |`,
    ...rows,
    ...(notes.length ? ["", ...notes] : []),
  ].join("\n");
}
