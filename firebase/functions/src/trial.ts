import { randomUUID, sign } from "node:crypto";

import { logger } from "firebase-functions";
import { HttpsError, onCall } from "firebase-functions/v2/https";

import {
  APPLE_DEVICECHECK_KEY,
  APPLE_DEVICECHECK_KEY_ID,
  APPLE_TEAM_ID,
  ENFORCE_APP_CHECK,
  REGION,
} from "./config";
import { TwoBits, isMonth, trialVerdict } from "./rules";

/**
 * Production first. A token from a development-signed build (Xcode, `flutter
 * run`) is rejected there with a 400 and only accepted by the development
 * host, so trying both in turn serves both builds without asking the app
 * which one it is.
 */
const HOSTS = [
  "https://api.devicecheck.apple.com",
  "https://api.development.devicecheck.apple.com",
];

/**
 * Has this device already had a free trial?
 *
 * The app calls this when its Keychain has no record of a trial: a first
 * install, or a phone that was wiped. Apple's DeviceCheck stores two bits per
 * device for this developer, and they survive both reinstalling the app and
 * erasing the phone. See trialVerdict in rules.ts for the decision itself.
 */
export const claimTrial = onCall(
  {
    region: REGION,
    enforceAppCheck: ENFORCE_APP_CHECK,
    secrets: [APPLE_TEAM_ID, APPLE_DEVICECHECK_KEY_ID, APPLE_DEVICECHECK_KEY],
    maxInstances: 5,
    timeoutSeconds: 20,
  },
  async (request) => {
    const token = request.data?.deviceToken;
    const startMonth = request.data?.startMonth;
    if (typeof token !== "string" || token.length < 16 || token.length > 8192) {
      throw new HttpsError("invalid-argument", "deviceToken required");
    }
    if (!isMonth(startMonth)) {
      throw new HttpsError("invalid-argument", "startMonth must be YYYY-MM");
    }

    const jwt = appleJwt(
      APPLE_TEAM_ID.value().trim(),
      APPLE_DEVICECHECK_KEY_ID.value().trim(),
      APPLE_DEVICECHECK_KEY.value(),
    );
    const { host, bits } = await queryBits(token, jwt);
    const verdict = trialVerdict(bits, startMonth);

    // First sighting: mark the device. Later sightings leave the bits alone,
    // so Apple's month stamp keeps pointing at the device's first trial.
    if (!bits?.bit0) {
      await deviceCheck(host, "update_two_bits", jwt, {
        device_token: token,
        bit0: true,
        bit1: false,
      });
    }
    return { verdict, since: bits?.bit0 ? bits.lastUpdate : null };
  },
);

async function queryBits(
  token: string,
  jwt: string,
): Promise<{ host: string; bits: TwoBits | null }> {
  for (const host of HOSTS) {
    const res = await deviceCheck(host, "query_two_bits", jwt, {
      device_token: token,
    });
    if (res.status === 400) continue; // the other environment's token
    const text = (await res.text()).trim();
    // A device Apple has never seen answers 200 with the plain-text body
    // "Failed to find bit state", not JSON.
    if (!text.startsWith("{")) return { host, bits: null };
    const json = JSON.parse(text) as { bit0?: boolean; last_update_time?: string };
    return {
      host,
      bits: { bit0: json.bit0 === true, lastUpdate: json.last_update_time ?? "" },
    };
  }
  throw new HttpsError("failed-precondition", "DeviceCheck rejected the device token");
}

async function deviceCheck(
  host: string,
  endpoint: "query_two_bits" | "update_two_bits",
  jwt: string,
  body: Record<string, unknown>,
): Promise<Response> {
  const res = await fetch(`${host}/v1/${endpoint}`, {
    method: "POST",
    headers: { Authorization: `Bearer ${jwt}`, "Content-Type": "application/json" },
    body: JSON.stringify({ ...body, transaction_id: randomUUID(), timestamp: Date.now() }),
    signal: AbortSignal.timeout(8000),
  });
  if (res.status !== 200 && res.status !== 400) {
    logger.error("DeviceCheck error", { endpoint, status: res.status, body: await res.text() });
    throw new HttpsError("unavailable", "DeviceCheck unavailable");
  }
  return res;
}

/** The ES256 bearer token Apple's server APIs expect, signed with the .p8. */
function appleJwt(teamId: string, keyId: string, p8: string): string {
  const b64url = (b: Buffer) => b.toString("base64url");
  const header = b64url(Buffer.from(JSON.stringify({ alg: "ES256", kid: keyId })));
  const claims = b64url(
    Buffer.from(JSON.stringify({ iss: teamId, iat: Math.floor(Date.now() / 1000) })),
  );
  const unsigned = `${header}.${claims}`;
  // Secrets pasted on one line arrive with literal "\n"s; the PEM parser needs
  // real ones.
  const key = p8.includes("\\n") ? p8.replace(/\\n/g, "\n") : p8;
  const sig = sign("sha256", Buffer.from(unsigned), { key, dsaEncoding: "ieee-p1363" });
  return `${unsigned}.${b64url(sig)}`;
}
