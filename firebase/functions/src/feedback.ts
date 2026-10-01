import { createHash } from "node:crypto";

import { FieldValue, Firestore, Timestamp, getFirestore } from "firebase-admin/firestore";
import { logger } from "firebase-functions";
import { HttpsError, onCall } from "firebase-functions/v2/https";

import {
  ENFORCE_APP_CHECK,
  REGION,
  TELEGRAM_BOT_TOKEN,
  TELEGRAM_CHAT_ID,
} from "./config";
import { pingTelegram } from "./notify";
import { InvalidInput, formatNotification, parseFeedback } from "./rules";

/** How long feedback is kept before Firestore's TTL policy deletes it. */
const RETENTION_DAYS = 730;

/** Sends per sender per hour: plenty for a person, useless to a script. */
const PER_HOUR = 6;

/**
 * Telegram pings per day, across everyone. Past this, feedback is still
 * stored, just not forwarded, so a flood can't keep your phone buzzing all
 * night.
 */
const PINGS_PER_DAY = 60;

const DAY_MS = 86_400_000;

/**
 * The app's feedback form posts here. Stores the message in Firestore, then
 * forwards it to your Telegram.
 *
 * With App Check enforced, only genuine copies of Phily can call it, so a
 * leaked URL or config file can't be scripted into spamming your phone (see
 * ENFORCE_APP_CHECK for when it's off).
 */
export const submitFeedback = onCall(
  {
    region: REGION,
    enforceAppCheck: ENFORCE_APP_CHECK,
    secrets: [TELEGRAM_BOT_TOKEN, TELEGRAM_CHAT_ID],
    maxInstances: 5,
    timeoutSeconds: 20,
  },
  async (request) => {
    let input;
    try {
      input = parseFeedback(request.data);
    } catch (err) {
      if (err instanceof InvalidInput) {
        throw new HttpsError("invalid-argument", err.message);
      }
      throw err;
    }

    const db = getFirestore();
    const uid = request.auth?.uid ?? null;
    await enforceRateLimit(db, senderKey(uid, request.rawRequest));

    const now = Date.now();
    const ref = db.collection("feedback").doc();
    await ref.set({
      kind: input.kind,
      message: input.message,
      // Present only with consent. No consent means no email on record.
      contact: input.contact
        ? {
            granted: true,
            email: input.contact.email,
            consentVersion: input.contact.consentVersion,
            consentText: input.contact.consentText,
            at: FieldValue.serverTimestamp(),
          }
        : { granted: false },
      // Linked to the account only so deleting the account can delete this.
      uid,
      context: input.context,
      status: "new",
      notified: false,
      createdAt: FieldValue.serverTimestamp(),
      expireAt: Timestamp.fromMillis(now + RETENTION_DAYS * DAY_MS),
    });

    if (await takePing(db, now)) {
      const sent = await pingTelegram(
        TELEGRAM_BOT_TOKEN.value(),
        TELEGRAM_CHAT_ID.value(),
        formatNotification(input, ref.id.slice(0, 8)),
      );
      if (sent) await ref.update({ notified: true });
    } else {
      logger.info("Daily ping cap reached; stored without a ping", { id: ref.id });
    }

    return { id: ref.id };
  },
);

/**
 * Who is sending, for rate limiting: the account when signed in, else a
 * hash of the IP address. The raw IP is never stored.
 */
function senderKey(
  uid: string | null,
  raw: { headers: Record<string, unknown>; ip?: string },
): string {
  if (uid) return `u_${uid}`;
  const fwd = raw.headers["x-forwarded-for"];
  const ip =
    (typeof fwd === "string" ? fwd.split(",")[0].trim() : undefined) ??
    raw.ip ??
    "unknown";
  const salt = process.env.GCLOUD_PROJECT ?? "phily";
  return `ip_${createHash("sha256").update(`${salt}:${ip}`).digest("hex").slice(0, 32)}`;
}

async function enforceRateLimit(
  db: Firestore,
  key: string,
): Promise<void> {
  const doc = db.collection("rateLimits").doc(key);
  const hour = 3_600_000;
  const allowed = await db.runTransaction(async (tx) => {
    const snap = await tx.get(doc);
    const now = Date.now();
    const start = snap.get("windowStart") as number | undefined;
    const count = (snap.get("count") as number | undefined) ?? 0;
    const fresh = start === undefined || now - start >= hour;
    if (!fresh && count >= PER_HOUR) return false;
    tx.set(doc, {
      windowStart: fresh ? now : start,
      count: fresh ? 1 : count + 1,
      // TTL: rate-limit rows clean themselves up a day later.
      expireAt: Timestamp.fromMillis(now + DAY_MS),
    });
    return true;
  });
  if (!allowed) {
    throw new HttpsError(
      "resource-exhausted",
      "You've sent a lot in the last hour. Try again a little later.",
    );
  }
}

/** Claims one of today's Telegram pings; false once the cap is used up. */
async function takePing(
  db: Firestore,
  now: number,
): Promise<boolean> {
  const day = new Date(now).toISOString().slice(0, 10);
  const doc = db.collection("rateLimits").doc(`pings_${day}`);
  return db.runTransaction(async (tx) => {
    const n = ((await tx.get(doc)).get("count") as number | undefined) ?? 0;
    if (n >= PINGS_PER_DAY) return false;
    tx.set(doc, {
      count: n + 1,
      expireAt: Timestamp.fromMillis(now + 2 * DAY_MS),
    });
    return true;
  });
}
