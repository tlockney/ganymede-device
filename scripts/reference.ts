// Generates the `device` API reference (docs/reference.md) from the TSDoc
// on the types cells see (ganymede#596, #85), the way cdp-kernel generates
// its `jupyter` reference. The doc comments are the source: editors show
// the same text on hover. Where each method works comes from `SUPPORT`
// (src/support.ts), the table the docs' support matrix is generated from,
// so the two can't drift. `node scripts/reference.ts --write` rewrites the
// page; with no flag it checks it, which test/reference.test.ts does too.
//
// Tags read: the summary, @param, @returns, @throws {Type}, and @example
// (a ```ts block; CI type-checks each one against the package's types).

import ts from "typescript";
import { readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { cell as supportCell, SUPPORT, type SupportRow } from "../src/support.ts";

export const root = fileURLToPath(new URL("../", import.meta.url));

export const PAGE = "docs/reference.md";
const DEVICE = "src/device.ts";

interface Section {
  /** The interface whose members are documented. */
  iface: string;
  /** How a member is named in headings: `device.`, `device.clipboard.` */
  prefix: string;
  heading: string;
  /** A member's `SUPPORT` key is this plus its name; none for members with no row. */
  support?: string;
  intro?: string;
}

const sections: Section[] = [
  { iface: "Device", prefix: "device.", heading: "device", support: "" },
  { iface: "Clipboard", prefix: "device.clipboard.", heading: "device.clipboard", support: "clipboard." },
  { iface: "Haptics", prefix: "device.haptics.", heading: "device.haptics", support: "haptics." },
  { iface: "UI", prefix: "device.ui.", heading: "device.ui", support: "ui." },
  { iface: "Files", prefix: "device.files.", heading: "device.files", support: "files." },
  {
    iface: "Photos",
    prefix: "device.photos.",
    heading: "device.photos",
    support: "photos.",
    intro: "The permission methods (`authorizationStatus`, `isAuthorized`, `requestAuthorization`) are about `save`'s add-only access, and work where `save` does: in the app, not from a remote kernel or a browser.",
  },
  { iface: "Sound", prefix: "device.sound.", heading: "device.sound", support: "sound." },
  {
    iface: "Notifications",
    prefix: "device.notifications.",
    heading: "device.notifications",
    support: "notifications.",
    intro: "The permission methods (`authorizationStatus`, `isAuthorized`, `requestAuthorization`) work where the rest of the namespace does: in the app, not from a remote kernel or a browser.",
  },
  {
    iface: "DeviceLocation",
    prefix: "device.location.",
    heading: "device.location",
    support: "location.",
    intro: "Over Core Location, while the app is in use only. `current` and `watch` need the location permission; geocoding needs the network but no permission. With precise location off for the app, `authorizationStatus()` reads `reducedAccuracy` and fixes are within a few kilometres. The permission methods work where the rest of the namespace does.",
  },
  {
    iface: "DeviceMotion",
    prefix: "device.motion.",
    heading: "device.motion",
    support: "motion.",
    intro: "Over Core Motion, on iPad and iPhone; a Mac has no motion sensors. `watch` and `latest` share one source. The system has no prompt for these sensors, so the permission is the app's own, per notebook. The permission methods work where the rest of the namespace does.",
  },
  {
    iface: "Contacts",
    prefix: "device.contacts.",
    heading: "device.contacts",
    support: "contacts.",
    intro: "Over the Contacts framework, on the Mac, iPad and iPhone. Every method needs the contacts permission. Contacts are plain records (`Contact`); groups, accounts, photos and notes aren't wrapped. The permission methods work where the rest of the namespace does.",
  },
  {
    iface: "Camera",
    prefix: "device.camera.",
    heading: "device.camera",
    support: "camera.",
    intro: "The system camera screen, on iPad and iPhone. `capture` needs the camera permission. The permission methods work where the rest of the namespace does.",
  },
  {
    iface: "Reminders",
    prefix: "device.reminders.",
    heading: "device.reminders",
    support: "reminders.",
    intro: "Over EventKit, on the Mac, iPad and iPhone. Every method needs the reminders permission. Reminders are plain records (`Reminder`); recurrence, alarms and subtasks aren't wrapped. The permission methods work where the rest of the namespace does.",
  },
  {
    iface: "SoundPlayer",
    prefix: "player.",
    heading: "SoundPlayer",
    intro: "Its methods work wherever [`device.sound.player`](#device-sound-player-data-options) does.",
  },
];

/**
 * Interfaces a section's interface extends whose members it documents
 * too: the permission trio. They have no `SUPPORT` rows of their own; they
 * work wherever the namespace does.
 */
const INHERITED: Record<string, string> = { Authorization: "src/permission.ts" };

/** Members that are answered in the kernel, so have no `SUPPORT` row. */
const LOCAL = new Set(["has"]);

const types: { name: string; file: string }[] = [
  { name: "CallOptions", file: DEVICE },
  { name: "DeviceInfo", file: DEVICE },
  { name: "OpenURLOptions", file: DEVICE },
  { name: "ImpactStyle", file: DEVICE },
  { name: "NotificationFeedback", file: DEVICE },
  { name: "AlertOptions", file: DEVICE },
  { name: "ConfirmOptions", file: DEVICE },
  { name: "PromptOptions", file: DEVICE },
  { name: "ActionSheetOptions", file: DEVICE },
  { name: "PickDateOptions", file: DEVICE },
  { name: "DateMode", file: DEVICE },
  { name: "ShareOptions", file: DEVICE },
  { name: "NamedBytes", file: DEVICE },
  { name: "Bytes", file: "src/binary.ts" },
  { name: "PickFilesOptions", file: DEVICE },
  { name: "ExportFileOptions", file: DEVICE },
  { name: "PickPhotosOptions", file: DEVICE },
  { name: "PlaySoundOptions", file: DEVICE },
  { name: "SoundState", file: DEVICE },
  { name: "NativeHandle", file: DEVICE },
  { name: "ScheduleNotificationOptions", file: DEVICE },
  { name: "PendingNotification", file: DEVICE },
  { name: "LocationOptions", file: DEVICE },
  { name: "LocationAccuracy", file: DEVICE },
  { name: "LocationFix", file: DEVICE },
  { name: "Place", file: DEVICE },
  { name: "MotionWatchOptions", file: DEVICE },
  { name: "MotionSample", file: DEVICE },
  { name: "Attitude", file: DEVICE },
  { name: "Vector3", file: DEVICE },
  { name: "Contact", file: DEVICE },
  { name: "LabeledValue", file: DEVICE },
  { name: "PostalAddress", file: DEVICE },
  { name: "ReminderCalendar", file: DEVICE },
  { name: "Reminder", file: DEVICE },
  { name: "NewReminder", file: DEVICE },
  { name: "ListRemindersOptions", file: DEVICE },
  { name: "AuthorizationStatus", file: "src/permission.ts" },
];

const ERRORS = "src/errors.ts";

const intro = `Every method of the \`device\` global, with its arguments, return value,
errors, where it works, and an example. The
[Device API guide](https://ganymede-server.com/docs/ganymede-ui/device)
explains where \`device\` exists and how to call it from a server kernel
or a browser.

\`device\` is \`undefined\` on kernels the app doesn't host, so a cell
checks for it first (\`device?.clipboard.readText()\`, or
\`if (device) …\`). The examples skip that check, and the
[\`SoundPlayer\`](#soundplayer) examples use a \`player\` from
[\`device.sound.player\`](#device-sound-player-data-options).

For editor types, add this line once to a cell or a project file:

\`\`\`ts
/// <reference types="@tlockney/ganymede-device/globals" />
\`\`\`

Every method takes a last \`options\` argument with a \`signal\`
([\`CallOptions\`](#calloptions)), and fails with a
[\`DeviceError\`](#errors). **Availability** says where each method
works: in the app (a kernel the Mac, iPad or iPhone app runs itself),
the system permission it needs there, from a [remote
kernel](https://ganymede-server.com/docs/ganymede-ui/device#from-a-server-kernel)
in the app, and from a kernel driven from a
[browser](https://ganymede-server.com/docs/ganymede-ui/device#in-a-browser).
"planned" means it doesn't yet but will; "no" means the platform has no
such API.`;

interface Doc {
  summary: string;
  params: Map<string, string>;
  returns?: string;
  throws: { type: string; text: string }[];
  examples: string[];
}

export interface Example {
  where: string;
  code: string;
}

export interface Result {
  content: string;
  problems: string[];
  examples: Example[];
}

function text(comment: string | ts.NodeArray<ts.JSDocComment> | undefined): string {
  return (ts.getTextOfJSDocComment(comment) ?? "").trim();
}

/** One paragraph: the wrapped lines of a tag joined with spaces. */
function oneLine(s: string): string {
  return s.replace(/\s*\n\s*/g, " ").trim();
}

function readDoc(node: ts.Node): Doc | undefined {
  const jsDoc = (node as { jsDoc?: ts.JSDoc[] }).jsDoc?.at(-1);
  if (!jsDoc) return;
  const doc: Doc = { summary: text(jsDoc.comment), params: new Map(), throws: [], examples: [] };
  for (const tag of jsDoc.tags ?? []) {
    const body = text(tag.comment);
    if (ts.isJSDocParameterTag(tag)) doc.params.set(tag.name.getText(), oneLine(body));
    else if (ts.isJSDocReturnTag(tag)) doc.returns = oneLine(body);
    else if (ts.isJSDocThrowsTag(tag)) {
      doc.throws.push({ type: tag.typeExpression?.type.getText() ?? "Error", text: oneLine(body) });
    } else if (tag.tagName.text === "example") doc.examples.push(body);
  }
  return doc;
}

function memberName(m: ts.TypeElement): string | undefined {
  if (!m.name || ts.isComputedPropertyName(m.name)) return;
  return m.name.getText();
}

/** `share(options)` from a signature's parameters. */
function callShape(sig: ts.SignatureDeclarationBase): string {
  return sig.parameters
    .map((p) => `${p.dotDotDotToken ? "..." : ""}${p.name.getText()}${p.questionToken ? "?" : ""}`)
    .join(", ");
}

/** VitePress's heading slug (vitepress/dist/node: slugify) of a heading's text. */
export function slugify(heading: string): string {
  return heading
    .replace(/`/g, "")
    .replace(/\[([^\]]*)\]\([^)]*\)/g, "$1")
    .normalize("NFKD")
    .replace(/[̀-ͯ]/g, "")
    .replace(/[\u0000-\u001f]/g, "")
    .replace(/[\s~`!@#$%^&*()\-_+=[\]{}|\\;:"'“”‘’<>,.?/]+/g, "-")
    .replace(/-{2,}/g, "-")
    .replace(/^-+|-+$/g, "")
    .replace(/^(\d)/, "_$1")
    .toLowerCase();
}

/** A declaration's source, without the indentation of the lines after the first. */
function source(node: ts.Node, sf: ts.SourceFile): string {
  const { character } = sf.getLineAndCharacterOfPosition(node.getStart(sf));
  return node.getText(sf).replace(new RegExp(`\n {${character}}`, "g"), "\n");
}

function cell(s: string): string {
  return s.replace(/\|/g, "\\|").replace(/\n/g, " ");
}

/** A `SUPPORT` row as a one-row table and its note. */
function availability(out: string[], row: SupportRow) {
  const browser = supportCell(row.browser, row.browserClick ? "after a click" : undefined);
  out.push(
    "**Availability**",
    "",
    "| In the app | Permission | Remote kernel | Browser |",
    "| --- | --- | --- | --- |",
    `| ${supportCell(row.onDevice, row.devices)} | ${row.permission ?? "none"} | ${supportCell(row.remote)} | ${browser} |`,
    "",
  );
  if (row.note) out.push(row.note, "");
}

function renderDoc(out: string[], doc: Doc, sigs: ts.SignatureDeclarationBase[], where: string, row: SupportRow | undefined, r: Result) {
  out.push(doc.summary, "");
  const params = new Map<string, ts.ParameterDeclaration>();
  for (const sig of sigs) for (const p of sig.parameters) if (!params.has(p.name.getText())) params.set(p.name.getText(), p);
  for (const name of doc.params.keys()) {
    if (!params.has(name)) r.problems.push(`${where}: @param ${name} names no parameter`);
  }
  if (params.size > 0) {
    out.push("| Parameter | Type | Required | Description |", "| --- | --- | --- | --- |");
    for (const [name, p] of params) {
      const desc = doc.params.get(name);
      if (!desc) r.problems.push(`${where}: parameter ${name} has no @param`);
      const optional = p.questionToken !== undefined || p.initializer !== undefined;
      out.push(`| \`${name}\` | \`${cell(p.type?.getText() ?? "unknown")}\` | ${optional ? "no" : "yes"} | ${cell(desc ?? "")} |`);
    }
    out.push("");
  }
  const type = sigs[0].type?.getText();
  // Not cell(): outside a table, a `\|` in a code span shows the backslash.
  if (type && !/^(Promise<void>|void)$/.test(type)) {
    out.push(`**Returns** \`${oneLine(type)}\`${doc.returns ? `: ${doc.returns}` : ""}`, "");
  } else if (doc.returns) out.push(`**Returns** ${doc.returns.replace(/^./, (c) => c.toLowerCase())}`, "");
  for (const t of doc.throws) out.push(`**Throws** \`${t.type}\`: ${t.text}`, "");
  if (row) availability(out, row);
  if (doc.examples.length === 0) r.problems.push(`${where}: no @example`);
  for (const example of doc.examples) {
    const m = /^```ts\n([\s\S]*?)\n```$/.exec(example);
    if (!m) {
      r.problems.push(`${where}: an @example is not a \`\`\`ts block`);
      continue;
    }
    r.examples.push({ where, code: m[1] });
    out.push("```ts", m[1], "```", "");
  }
}

function renderSection(
  out: string[],
  index: string[],
  section: Section,
  sourceFile: (file: string) => ts.SourceFile,
  covered: Set<string>,
  r: Result,
) {
  const sf = sourceFile(DEVICE);
  const decl = sf.statements.find((s): s is ts.InterfaceDeclaration => ts.isInterfaceDeclaration(s) && s.name.text === section.iface);
  if (!decl) {
    r.problems.push(`${DEVICE}: no interface ${section.iface}`);
    return;
  }
  out.push(`## \`${section.heading}\``, "");
  const ifaceDoc = readDoc(decl);
  if (!ifaceDoc?.summary) r.problems.push(`${section.iface}: no doc comment`);
  else out.push(ifaceDoc.summary, "");
  if (section.intro) out.push(section.intro, "");

  // Inherited members (the permission trio) first, from their own file.
  const members: { m: ts.TypeElement; sf: ts.SourceFile; inherited: boolean }[] = [];
  for (const clause of decl.heritageClauses ?? []) {
    for (const base of clause.types) {
      const file = INHERITED[base.expression.getText(sf)];
      if (!file) continue;
      const bsf = sourceFile(file);
      const b = bsf.statements.find((s): s is ts.InterfaceDeclaration => ts.isInterfaceDeclaration(s) && s.name.text === base.expression.getText(sf));
      if (!b) r.problems.push(`${file}: no interface ${base.expression.getText(sf)}`);
      for (const m of b?.members ?? []) members.push({ m, sf: bsf, inherited: true });
    }
  }
  for (const m of decl.members) members.push({ m, sf, inherited: false });
  const props: string[] = [];
  for (const { m, sf, inherited } of members) {
    const name = memberName(m);
    const where = `${section.iface}.${name ?? m.name?.getText(sf)}`;
    const doc = readDoc(m);
    if (!name || !doc?.summary) {
      r.problems.push(`${where}: no doc comment`);
      continue;
    }
    if (!ts.isMethodSignature(m)) {
      const p = m as ts.PropertySignature;
      props.push(`| \`${name}\` | \`${cell(p.type?.getText() ?? "")}\` | ${cell(oneLine(doc.summary))} |`);
      continue;
    }
    const key = section.support === undefined || inherited ? undefined : `${section.support}${name}`;
    const row = key === undefined ? undefined : (SUPPORT as Record<string, SupportRow>)[key];
    if (key !== undefined) {
      if (row) covered.add(key);
      else if (!LOCAL.has(key)) r.problems.push(`${where}: no SUPPORT row ${key}`);
    }
    const title = `\`${section.prefix}${name}(${callShape(m)})\``;
    index.push(`| [${title}](#${slugify(title)}) | ${cell(oneLine(doc.summary.split(/(?<=\.)\s/)[0]))} |`);
    out.push(`### ${title}`, "");
    out.push("```ts", source(m, sf), "```", "");
    // The trio's examples are written for `device.notifications`; under
    // another namespace they call that namespace.
    const shown = inherited ? { ...doc, examples: doc.examples.map((e) => e.replaceAll("device.notifications.", section.prefix)) } : doc;
    renderDoc(out, shown, [m], where, row, r);
  }
  if (props.length > 0) {
    out.push("### Properties", "", "| Property | Type | Description |", "| --- | --- | --- |", ...props, "");
  }
}

/** The last `/** … *\/` comment between `from` and a node, such as a union member, which TS attaches no JSDoc to. */
function leadingDoc(from: number, node: ts.Node, sf: ts.SourceFile): string | undefined {
  const raw = sf.text.slice(from, node.getStart(sf)).match(/\/\*\*[\s\S]*?\*\//g)?.at(-1);
  if (!raw) return;
  return oneLine(raw.replace(/^\/\*\*|\*\/$/g, "").replace(/^\s*\* ?/gm, ""));
}

function renderType(out: string[], name: string, sf: ts.SourceFile, r: Result) {
  const decl = sf.statements.find(
    (s): s is ts.InterfaceDeclaration | ts.TypeAliasDeclaration =>
      (ts.isInterfaceDeclaration(s) || ts.isTypeAliasDeclaration(s)) && s.name.text === name,
  );
  const doc = decl && readDoc(decl);
  if (!decl || !doc?.summary) {
    r.problems.push(`type ${name} is missing or undocumented`);
    return;
  }
  out.push(`### \`${name}\``, "", doc.summary, "");
  if (ts.isTypeAliasDeclaration(decl)) {
    out.push("```ts", decl.getText(sf), "```", "");
    return;
  }
  out.push("| Property | Type | Required | Description |", "| --- | --- | --- | --- |");
  for (const m of decl.members) {
    const p = m as ts.PropertySignature;
    const key = m.name?.getText(sf);
    const desc = readDoc(m)?.summary;
    if (!desc) r.problems.push(`${name}.${key}: no doc comment`);
    out.push(`| \`${key}\` | \`${cell(oneLine(p.type?.getText(sf) ?? ""))}\` | ${p.questionToken ? "no" : "yes"} | ${cell(oneLine(desc ?? ""))} |`);
  }
  out.push("");
  // Inherited properties, such as `signal`, are on the base type's table.
  for (const clause of decl.heritageClauses ?? []) {
    for (const base of clause.types) {
      const b = base.expression.getText(sf);
      if (b === "AsyncDisposable") continue;
      out.push(`It also takes [\`${b}\`](#${slugify(b)})'s properties.`, "");
    }
  }
}

/** `DeviceErrorCode`'s members and their doc comments, as a table. */
function renderErrors(out: string[], sf: ts.SourceFile, r: Result) {
  const decl = sf.statements.find((s): s is ts.TypeAliasDeclaration => ts.isTypeAliasDeclaration(s) && s.name.text === "DeviceErrorCode");
  const doc = decl && readDoc(decl);
  if (!decl || !doc?.summary || !ts.isUnionTypeNode(decl.type)) {
    r.problems.push(`${ERRORS}: DeviceErrorCode is missing, undocumented or not a union`);
    return;
  }
  out.push(
    "## Errors",
    "",
    // The summary's first sentence says what the type is; the rest is for readers.
    `A call that fails rejects with a \`DeviceError\`, an \`Error\` whose \`code\` says why. ${oneLine(doc.summary).split(/(?<=\.)\s/).slice(1).join(" ")}`.trim(),
    "",
    "| `code` | Meaning |",
    "| --- | --- |",
  );
  let from = decl.type.getFullStart();
  for (const member of decl.type.types) {
    const meaning = leadingDoc(from, member, sf);
    from = member.getEnd();
    if (!meaning) r.problems.push(`DeviceErrorCode ${member.getText(sf)}: no doc comment`);
    out.push(`| \`${member.getText(sf).replace(/"/g, "")}\` | ${cell(meaning ?? "")} |`);
  }
  out.push("");
}

export function generate(): Result {
  const r: Result = { content: "", problems: [], examples: [] };
  const files = new Map<string, ts.SourceFile>();
  const sourceFile = (file: string) => {
    let sf = files.get(file);
    if (!sf) {
      sf = ts.createSourceFile(file, readFileSync(join(root, file), "utf8"), ts.ScriptTarget.Latest, true);
      files.set(file, sf);
    }
    return sf;
  };
  const body: string[] = [];
  const index: string[] = [];
  const covered = new Set<string>();
  for (const section of sections) renderSection(body, index, section, sourceFile, covered, r);
  for (const key of Object.keys(SUPPORT)) {
    if (!covered.has(key)) r.problems.push(`SUPPORT row ${key} is on no method in the reference`);
  }
  renderErrors(body, sourceFile(ERRORS), r);
  body.push("## Types", "");
  for (const t of types) renderType(body, t.name, sourceFile(t.file), r);
  // Links and the outline use VitePress's heading slugs, so a member's
  // must be unique on the page ("Properties" repeats, and isn't linked).
  const slugs = body.filter((l) => /^#{2,3} /.test(l) && l !== "### Properties").map((l) => slugify(l.replace(/^#+ /, "")));
  for (const slug of new Set(slugs.filter((s, i) => slugs.indexOf(s) !== i))) {
    r.problems.push(`${PAGE}: two headings have the slug #${slug}`);
  }
  // Links within the page must land on a heading.
  for (const [, id] of [intro, ...index, ...body].join("\n").matchAll(/\]\(#([^)]+)\)/g)) {
    if (!slugs.includes(id) && id !== "errors") r.problems.push(`${PAGE}: link #${id} goes to no heading`);
  }
  const sources = [...new Set([DEVICE, ERRORS, ...types.map((t) => t.file), "src/support.ts"])];
  const out = [
    `<!-- Generated by scripts/reference.ts from the doc comments in ${sources.join(", ")}. Edit those, then run \`node scripts/reference.ts --write\`. -->`,
    "",
    "# `device` reference",
    "",
    intro,
    "",
    "| Method | What it does |",
    "| --- | --- |",
    ...index,
    "",
    ...body,
  ];
  r.content = `${out.join("\n").replace(/\n{3,}/g, "\n\n").trimEnd()}\n`;
  return r;
}

/** Whether the page on disk differs from what the doc comments generate. */
export function stale(r: Result): boolean {
  try {
    return readFileSync(join(root, PAGE), "utf8") !== r.content;
  } catch {
    return true;
  }
}

if (import.meta.main) {
  const r = generate();
  for (const p of r.problems) console.error(p);
  if (process.argv.includes("--write")) writeFileSync(join(root, PAGE), r.content);
  else if (stale(r)) {
    console.error(`${PAGE} is out of date: run node scripts/reference.ts --write`);
    process.exitCode = 1;
  }
  if (r.problems.length > 0) process.exitCode = 1;
}
