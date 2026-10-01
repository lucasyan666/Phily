import { defineSecret } from "firebase-functions/params";

/**
 * London. Firestore and every function live here, so feedback and the emails
 * in it are stored and processed in the UK. The database must be created in
 * the same region (europe-west2) — see firebase/README.md.
 */
export const REGION = "europe-west2";

// ── Secrets (Google Secret Manager) ─────────────────────────────────────────
// Set with `firebase functions:secrets:set NAME`. Never in the app: anything
// shipped in the binary can be extracted, and these would let a stranger
// message your phone or impersonate the app to Apple.

/** The token @BotFather gave your feedback bot. */
export const TELEGRAM_BOT_TOKEN = defineSecret("TELEGRAM_BOT_TOKEN");
/** Your own chat with that bot (find it with tools/telegram-chat-id.sh). */
export const TELEGRAM_CHAT_ID = defineSecret("TELEGRAM_CHAT_ID");

/**
 * Whether the functions refuse calls without a valid App Check token.
 *
 * Off (`ENFORCE_APP_CHECK=false` in functions/.env) only while the app is
 * built with a free Apple team: App Attest needs a paid one, and debug and
 * profile builds would otherwise need a registered debug token. Until then
 * the rate limits are the only guard. Delete the line before release, so
 * only genuine copies of Phily can call in.
 */
export const ENFORCE_APP_CHECK = process.env.ENFORCE_APP_CHECK !== "false";

/** Apple developer Team ID (10 characters, top-right of developer.apple.com). */
export const APPLE_TEAM_ID = defineSecret("APPLE_TEAM_ID");
/** Key ID of the DeviceCheck key (Certificates, IDs & Profiles → Keys). */
export const APPLE_DEVICECHECK_KEY_ID = defineSecret("APPLE_DEVICECHECK_KEY_ID");
/** Full contents of that key's AuthKey_XXXXXXXXXX.p8 file. */
export const APPLE_DEVICECHECK_KEY = defineSecret("APPLE_DEVICECHECK_KEY");
