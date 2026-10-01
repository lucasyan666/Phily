// Pure decisions for the functions in this folder — no Firebase imports, so
// `npm test` can exercise every rule without an emulator or credentials.

export const KINDS = ["idea", "issue", "composition"] as const;
export type Kind = (typeof KINDS)[number];

export const LIMITS = {
  messageMin: 3,
  messageMax: 2000,
  emailMax: 254,
  contextValueMax: 64,
} as const;

/**
 * The consent sentence, by version. The app shows `CONSENT[v]` beside the
 * switch and sends back `v`; the stored record keeps the version *and* the
 * text, so you can always show exactly what someone agreed to.
 *
 * The text is exactly what the app shows: the switch's label, then the line
 * beneath it (FeedbackService.consentTitle and consentDetail in
 * lib/services/feedback.dart). Never edit a published entry. Add a new
 * version here, then bump FeedbackService.consentVersion to match.
 */
export const CONSENT: Readonly<Record<number, string>> = {
  1: "You can reply to me about this. Your email is used only to answer this message.",
};

/** The only context keys the app may attach, so nothing unplanned is stored. */
const CONTEXT_KEYS = ["appVersion", "build", "os", "mode"] as const;

export interface Contact {
  email: string;
  consentVersion: number;
  consentText: string;
}

export interface FeedbackInput {
  kind: Kind;
  message: string;
  contact: Contact | null;
  context: Partial<Record<(typeof CONTEXT_KEYS)[number], string>>;
}

export class InvalidInput extends Error {}

// Deliberately loose: the address is for a human to reply to, not an identity
// check, and a strict pattern rejects real addresses more often than it
// catches typos. The app shows the same rule, so the two never disagree.
const EMAIL = /^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/;

export function isEmail(s: string): boolean {
  return s.length <= LIMITS.emailMax && EMAIL.test(s);
}

/**
 * Validates what the app sent. Throws [InvalidInput] with a message safe to
 * show the user. An email arriving without consent is dropped here, never
 * stored: the only reason to hold an address is permission to use it.
 */
export function parseFeedback(data: unknown): FeedbackInput {
  if (typeof data !== "object" || data === null) {
    throw new InvalidInput("Nothing to send.");
  }
  const d = data as Record<string, unknown>;

  const kind = d.kind;
  if (typeof kind !== "string" || !(KINDS as readonly string[]).includes(kind)) {
    throw new InvalidInput("Unknown feedback type.");
  }

  const message = typeof d.message === "string" ? d.message.trim() : "";
  if (message.length < LIMITS.messageMin) {
    throw new InvalidInput("Write a few words first.");
  }
  if (message.length > LIMITS.messageMax) {
    throw new InvalidInput(`Keep it under ${LIMITS.messageMax} characters.`);
  }

  let contact: Contact | null = null;
  if (d.contact === true) {
    const email = typeof d.email === "string" ? d.email.trim() : "";
    if (!isEmail(email)) throw new InvalidInput("That email doesn't look right.");
    const version = d.consentVersion;
    if (typeof version !== "number" || !(version in CONSENT)) {
      throw new InvalidInput("Please update Phily to send this.");
    }
    contact = { email, consentVersion: version, consentText: CONSENT[version] };
  }

  const context: FeedbackInput["context"] = {};
  const raw = d.context;
  if (typeof raw === "object" && raw !== null) {
    for (const key of CONTEXT_KEYS) {
      const v = (raw as Record<string, unknown>)[key];
      if (typeof v === "string" && v.trim()) {
        context[key] = v.trim().slice(0, LIMITS.contextValueMax);
      }
    }
  }

  return { kind: kind as Kind, message, contact, context };
}

const HEADLINE: Record<Kind, string> = {
  idea: "💡 <b>Idea</b>",
  issue: "🛠️ <b>Something's off</b>",
  composition: "📐 <b>Composition request</b>",
};

/**
 * Makes user text safe inside Telegram's HTML. Without this, a message
 * containing "<" or "&" makes Telegram reject the whole ping.
 */
export function escapeHtml(s: string): string {
  return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}

/**
 * The Telegram message you receive, in Telegram's HTML subset. A whole
 * message always fits: feedback is capped at 2,000 characters and Telegram
 * allows 4,096.
 */
export function formatNotification(input: FeedbackInput, ref: string): string {
  const reply = input.contact
    ? `↩︎ Reply OK: ${escapeHtml(input.contact.email)}`
    : "— no reply requested";
  const c = input.context;
  const meta = [
    c.appVersion && `v${c.appVersion}${c.build ? ` (${c.build})` : ""}`,
    c.os,
    c.mode && `from the ${c.mode} guide`,
  ]
    .filter(Boolean)
    .join(" · ");
  return [
    `${HEADLINE[input.kind]} · Phily`,
    "",
    escapeHtml(input.message),
    "",
    reply,
    meta && `<i>${escapeHtml(meta)}</i>`,
    `<code>ref ${escapeHtml(ref)}</code>`,
  ]
    .filter((line) => line !== undefined)
    .join("\n")
    .trim();
}

/** "YYYY-MM" in UTC — the granularity Apple's DeviceCheck reports. */
export function monthOf(d: Date): string {
  return `${d.getUTCFullYear()}-${String(d.getUTCMonth() + 1).padStart(2, "0")}`;
}

const MONTH = /^\d{4}-(0[1-9]|1[0-2])$/;

export function isMonth(s: unknown): s is string {
  return typeof s === "string" && MONTH.test(s);
}

export interface TwoBits {
  bit0: boolean;
  /** "YYYY-MM", as Apple returns it. */
  lastUpdate: string;
}

/**
 * Has this device already had its trial?
 *
 * bit0 means "a trial started on this device", and Apple stamps the month it
 * was set. The device counts as used only when that stamp is from a month
 * *before* this install's own trial began. Two cases this protects:
 *
 * - The app set the bit, but the response never arrived (the phone went
 *   offline). On the retry, the stamp is this install's own, so the trial
 *   stands.
 * - Someone wipes their phone during the trial week. Same month, so they
 *   keep the trial. Wiping a phone for seven more days isn't a real threat.
 *
 * "YYYY-MM" strings compare correctly as plain strings.
 */
export function trialVerdict(
  bits: TwoBits | null,
  localStartMonth: string,
): "fresh" | "used" {
  if (!bits || !bits.bit0) return "fresh";
  if (!isMonth(bits.lastUpdate)) return "fresh"; // unreadable stamp: benefit of the doubt
  return bits.lastUpdate < localStartMonth ? "used" : "fresh";
}
