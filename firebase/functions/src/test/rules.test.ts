import assert from "node:assert/strict";
import { describe, it } from "node:test";

import {
  CONSENT,
  InvalidInput,
  LIMITS,
  escapeHtml,
  formatNotification,
  monthOf,
  parseFeedback,
  trialVerdict,
} from "../rules";

describe("parseFeedback", () => {
  const base = { kind: "idea", message: "A diagonal guide would be lovely" };

  it("accepts a plain message with no contact", () => {
    const f = parseFeedback(base);
    assert.equal(f.kind, "idea");
    assert.equal(f.contact, null);
  });

  it("drops an email sent without consent", () => {
    const f = parseFeedback({ ...base, contact: false, email: "a@b.co" });
    assert.equal(f.contact, null);
    assert.ok(!JSON.stringify(f).includes("a@b.co"));
  });

  it("records the consent wording alongside the email", () => {
    const f = parseFeedback({ ...base, contact: true, email: " a@b.co ", consentVersion: 1 });
    assert.deepEqual(f.contact, {
      email: "a@b.co",
      consentVersion: 1,
      consentText: CONSENT[1],
    });
  });

  it("rejects consent with a bad email or an unknown wording", () => {
    assert.throws(() => parseFeedback({ ...base, contact: true, email: "nope", consentVersion: 1 }), InvalidInput);
    assert.throws(() => parseFeedback({ ...base, contact: true, email: "a@b.co", consentVersion: 99 }), InvalidInput);
  });

  it("rejects unknown kinds and out-of-range messages", () => {
    assert.throws(() => parseFeedback({ ...base, kind: "rant" }), InvalidInput);
    assert.throws(() => parseFeedback({ ...base, message: "  hi " }), InvalidInput);
    assert.throws(() => parseFeedback({ ...base, message: "x".repeat(LIMITS.messageMax + 1) }), InvalidInput);
  });

  it("keeps only whitelisted, trimmed context", () => {
    const f = parseFeedback({
      ...base,
      context: { appVersion: " 1.2.0 ", os: "iOS 18.6", deviceId: "leak", mode: "x".repeat(200) },
    });
    assert.deepEqual(Object.keys(f.context).sort(), ["appVersion", "mode", "os"]);
    assert.equal(f.context.appVersion, "1.2.0");
    assert.equal(f.context.mode?.length, LIMITS.contextValueMax);
  });
});

describe("formatNotification", () => {
  it("names the reply address only when consent was given", () => {
    const yes = parseFeedback({ kind: "composition", message: "Frame within a frame", contact: true, email: "a@b.co", consentVersion: 1 });
    const no = parseFeedback({ kind: "composition", message: "Frame within a frame" });
    assert.match(formatNotification(yes, "abc"), /Reply OK: a@b\.co/);
    assert.match(formatNotification(no, "abc"), /no reply requested/);
    assert.ok(!formatNotification(no, "abc").includes("@"));
  });

  it("sends the whole message: the 2,000 cap fits Telegram's 4,096", () => {
    const f = parseFeedback({ kind: "issue", message: "y".repeat(LIMITS.messageMax) });
    const text = formatNotification(f, "abc");
    assert.ok(text.includes("y".repeat(LIMITS.messageMax)));
    assert.ok(text.length < 4096);
  });

  it("escapes what the user typed, so Telegram's HTML can't break", () => {
    const f = parseFeedback({
      kind: "idea",
      message: "Make <b>this</b> & that",
      contact: true,
      email: "a<b>@c.co",
      consentVersion: 1,
    });
    const text = formatNotification(f, "abc");
    assert.ok(text.includes("Make &lt;b&gt;this&lt;/b&gt; &amp; that"));
    assert.ok(!text.includes("<b>this</b>"));
    assert.equal(escapeHtml("a<b>&"), "a&lt;b&gt;&amp;");
  });
});

describe("trialVerdict", () => {
  it("is fresh for a device Apple has never seen", () => {
    assert.equal(trialVerdict(null, "2026-09"), "fresh");
    assert.equal(trialVerdict({ bit0: false, lastUpdate: "2026-01" }, "2026-09"), "fresh");
  });

  it("is used when the bit predates this install's trial", () => {
    assert.equal(trialVerdict({ bit0: true, lastUpdate: "2026-06" }, "2026-09"), "used");
    assert.equal(trialVerdict({ bit0: true, lastUpdate: "2025-12" }, "2026-01"), "used");
  });

  it("stays fresh when the bit is this install's own (lost response, retried later)", () => {
    assert.equal(trialVerdict({ bit0: true, lastUpdate: "2026-09" }, "2026-09"), "fresh");
    assert.equal(trialVerdict({ bit0: true, lastUpdate: "2026-10" }, "2026-09"), "fresh");
  });

  it("gives the benefit of the doubt to an unreadable stamp", () => {
    assert.equal(trialVerdict({ bit0: true, lastUpdate: "" }, "2026-09"), "fresh");
  });
});

describe("monthOf", () => {
  it("uses UTC", () => {
    assert.equal(monthOf(new Date(Date.UTC(2026, 8, 30, 23, 30))), "2026-09");
    assert.equal(monthOf(new Date(Date.UTC(2027, 0, 1))), "2027-01");
  });
});
