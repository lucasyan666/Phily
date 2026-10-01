import { logger } from "firebase-functions";

/**
 * Sends [html] to your own Telegram chat through your feedback bot.
 *
 * Returns whether it went out, and never throws: the feedback is already in
 * Firestore by the time this runs, so a failed ping must not fail the user's
 * send. Check `notified: false` in the console to catch any that were missed.
 */
export async function pingTelegram(
  token: string,
  chatId: string,
  html: string,
): Promise<boolean> {
  try {
    const res = await fetch(`https://api.telegram.org/bot${token.trim()}/sendMessage`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        chat_id: chatId.trim(),
        text: html,
        parse_mode: "HTML",
        // A pasted link in feedback shouldn't unfurl into a big preview card.
        link_preview_options: { is_disabled: true },
      }),
      signal: AbortSignal.timeout(8000),
    });
    if (res.ok) return true;
    // Telegram's error text names the problem ("chat not found", "bot was
    // blocked by the user") without echoing the token or the message.
    const body = (await res.json().catch(() => ({}))) as { description?: string };
    logger.warn("Telegram rejected the message", {
      status: res.status,
      description: body.description,
    });
  } catch (err) {
    logger.warn("Telegram unreachable", { error: String(err) });
  }
  return false;
}
