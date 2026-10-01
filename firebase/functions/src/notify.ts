import { logger } from "firebase-functions";

/**
 * Sends [text] to your own WhatsApp through CallMeBot's free personal API.
 *
 * Returns whether it went out, and never throws: the feedback is already in
 * Firestore by the time this runs, so a failed ping must not fail the user's
 * send. Check `notified: false` in the console to catch any that were missed.
 */
export async function pingWhatsApp(
  phone: string,
  apiKey: string,
  text: string,
): Promise<boolean> {
  const url = new URL("https://api.callmebot.com/whatsapp.php");
  url.searchParams.set("phone", phone);
  url.searchParams.set("text", text);
  url.searchParams.set("apikey", apiKey);
  try {
    const res = await fetch(url, { signal: AbortSignal.timeout(8000) });
    if (res.ok) return true;
    // Log the status only. The URL carries the API key, and the body can
    // echo the message back, which may contain the user's email.
    logger.warn("CallMeBot rejected the message", { status: res.status });
  } catch (err) {
    logger.warn("CallMeBot unreachable", { error: String(err) });
  }
  return false;
}
