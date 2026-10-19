// Which methods work where: the one table the docs, `has()` tests and the
// conformance suite read, so they can't drift (PLAN.md, "Documentation").

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
} as const satisfies Record<string, SupportRow>;

export type Method = keyof typeof SUPPORT;
