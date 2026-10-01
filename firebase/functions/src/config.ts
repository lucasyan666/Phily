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

/** Your WhatsApp number in international form, e.g. +447700900123. */
export const CALLMEBOT_PHONE = defineSecret("CALLMEBOT_PHONE");
/** The key CallMeBot sends back after you message its bot. */
export const CALLMEBOT_APIKEY = defineSecret("CALLMEBOT_APIKEY");

/** Apple developer Team ID (10 characters, top-right of developer.apple.com). */
export const APPLE_TEAM_ID = defineSecret("APPLE_TEAM_ID");
/** Key ID of the DeviceCheck key (Certificates, IDs & Profiles → Keys). */
export const APPLE_DEVICECHECK_KEY_ID = defineSecret("APPLE_DEVICECHECK_KEY_ID");
/** Full contents of that key's AuthKey_XXXXXXXXXX.p8 file. */
export const APPLE_DEVICECHECK_KEY = defineSecret("APPLE_DEVICECHECK_KEY");
