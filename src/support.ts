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
  /** An on-device kernel in the Mac or iPad app. */
  onDevice: Support;
  /** Shown instead of "yes" on-device when only some devices have it, such as "iPhone". */
  devices?: string;
  /** A remote kernel driven from the app: only features that need no permission. */
  remote: Support;
  /** A remote kernel driven from a browser, through web APIs. */
  browser: Support;
  /** The browser lets a page call it only after a click on a prompt the page shows. */
  browserClick?: boolean;
  /** Why a column is "no", or what limits it, for the docs' footnotes. */
  note?: string;
}

export const SUPPORT = {
  info: {
    call: "info()",
    returns: "platform, version, methods",
    onDevice: "yes",
    remote: "planned",
    browser: "planned",
    note: "A browser has no model or battery.",
  },
  "clipboard.readText": {
    call: "clipboard.readText()",
    returns: "`string`, or `null`",
    onDevice: "yes",
    remote: "planned",
    browser: "planned",
    browserClick: true,
    note: "iPadOS shows its paste prompt; a browser needs a click for the Clipboard API.",
  },
  "clipboard.writeText": {
    call: "clipboard.writeText(text)",
    returns: "nothing",
    onDevice: "yes",
    remote: "planned",
    browser: "planned",
    browserClick: true,
    note: "A browser needs a click for the Clipboard API.",
  },
  "clipboard.readImage": {
    call: "clipboard.readImage()",
    returns: "PNG bytes, or `null`",
    onDevice: "yes",
    remote: "planned",
    browser: "planned",
    browserClick: true,
    note: "PNG. iPadOS shows its paste prompt; a browser needs a click for the Clipboard API.",
  },
  "clipboard.writeImage": {
    call: "clipboard.writeImage(image)",
    returns: "nothing",
    onDevice: "yes",
    remote: "planned",
    browser: "planned",
    browserClick: true,
    note: "A browser needs a click for the Clipboard API, and takes PNG only.",
  },
  "haptics.impact": {
    call: "haptics.impact(style)",
    returns: "nothing",
    onDevice: "yes",
    devices: "iPhone",
    remote: "planned",
    browser: "no",
    note: "iPhone only: iPads and Macs have no Taptic Engine. A browser has no haptics API Safari supports.",
  },
  "haptics.notification": {
    call: "haptics.notification(type)",
    returns: "nothing",
    onDevice: "yes",
    devices: "iPhone",
    remote: "planned",
    browser: "no",
    note: "iPhone only: iPads and Macs have no Taptic Engine.",
  },
  "haptics.selection": {
    call: "haptics.selection()",
    returns: "nothing",
    onDevice: "yes",
    devices: "iPhone",
    remote: "planned",
    browser: "no",
    note: "iPhone only: iPads and Macs have no Taptic Engine.",
  },
  openURL: {
    call: "openURL(url, { inApp })",
    returns: "nothing",
    onDevice: "yes",
    remote: "planned",
    browser: "planned",
    browserClick: true,
    note: "http, https and mailto only. `inApp` works on iPhone and iPad, not the Mac; a browser opens a tab after a click.",
  },
} as const satisfies Record<string, SupportRow>;

export type Method = keyof typeof SUPPORT;

function cell(support: Support, detail?: string): string {
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
  for (const row of Object.values(support)) {
    const method = `\`device.${row.call}\``;
    const browser = cell(row.browser, row.browserClick ? "after a click" : undefined);
    rows.push(`| ${method} | ${row.returns} | ${cell(row.onDevice, row.devices)} | ${cell(row.remote)} | ${browser} |`);
    if (row.note) notes.push(`- ${method}: ${row.note}`);
  }
  return [
    "| Method | Returns | In the app | Remote kernel | Browser |",
    "| --- | --- | --- | --- | --- |",
    ...rows,
    ...(notes.length ? ["", ...notes] : []),
  ].join("\n");
}
