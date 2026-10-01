import { getAuth } from "firebase-admin/auth";
import { getFirestore } from "firebase-admin/firestore";
import { HttpsError, onCall } from "firebase-functions/v2/https";

import { REGION } from "./config";

/**
 * Deletes the caller's account and everything linked to it: required by App
 * Store guideline 5.1.1(v), and the right to erasure under UK GDPR.
 *
 * Runs server-side so it doesn't need a recent sign-in. Firebase's client-side
 * `user.delete()` refuses after five minutes, which would force an email-link
 * user through a fresh email round trip just to leave. For Sign in with Apple
 * accounts, the app revokes the Apple token before calling this.
 */
export const deleteAccount = onCall(
  { region: REGION, enforceAppCheck: true, maxInstances: 5, timeoutSeconds: 60 },
  async (request) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Sign in first.");

    const db = getFirestore();
    const writer = db.bulkWriter();
    const feedback = await db.collection("feedback").where("uid", "==", uid).get();
    feedback.docs.forEach((d) => void writer.delete(d.ref));
    void writer.delete(db.collection("rateLimits").doc(`u_${uid}`));
    await writer.close();

    await getAuth().deleteUser(uid);
    return { deleted: feedback.size };
  },
);
