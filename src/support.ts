// Which methods work where: the one table the docs, `has()` tests and the
// conformance suite read, so they can't drift (docs/plan.md, "Documentation").

/** Where a method works. "click" means only after a click on a prompt the page shows. */
export type Support = boolean | "click";

export interface SupportRow {
  /** An on-device kernel in the Mac or iPad app. */
  onDevice: Support;
  /** A remote kernel driven from the app: only features that need no permission. */
  remote: Support;
  /** A remote kernel driven from a browser, through web APIs. */
  browser: Support;
  /** Why a column is false or "click", for the docs. */
  note?: string;
}

export const SUPPORT = {
  "clipboard.readText": {
    onDevice: true,
    remote: true,
    browser: "click",
    note: "iPadOS shows its paste prompt; a browser needs a click for the Clipboard API.",
  },
  "clipboard.writeText": { onDevice: true, remote: true, browser: "click", note: "A browser needs a click for the Clipboard API." },
  "clipboard.readImage": {
    onDevice: true,
    remote: true,
    browser: "click",
    note: "PNG. iPadOS shows its paste prompt; a browser needs a click for the Clipboard API.",
  },
  "clipboard.writeImage": { onDevice: true, remote: true, browser: "click", note: "A browser needs a click for the Clipboard API, and takes PNG only." },
  info: {
    onDevice: true,
    remote: true,
    browser: true,
    note: "A browser has no model or battery.",
  },
  "haptics.impact": { onDevice: true, remote: true, browser: false, note: "iPhone only: iPads and Macs have no Taptic Engine. A browser has no haptics API Safari supports." },
  "haptics.notification": { onDevice: true, remote: true, browser: false, note: "iPhone only: iPads and Macs have no Taptic Engine." },
  "haptics.selection": { onDevice: true, remote: true, browser: false, note: "iPhone only: iPads and Macs have no Taptic Engine." },
  openURL: {
    onDevice: true,
    remote: true,
    browser: "click",
    note: "http, https and mailto only. `inApp` works on iPhone and iPad, not the Mac; a browser opens a tab after a click.",
  },
} as const satisfies Record<string, SupportRow>;

export type Method = keyof typeof SUPPORT;
