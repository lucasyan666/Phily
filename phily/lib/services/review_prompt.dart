import 'package:flutter/foundation.dart';
import 'package:in_app_review/in_app_review.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:phily/debug.dart';
import 'package:phily/services/phily_pro.dart';
import 'package:phily/services/shot_guide_log.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Asks for an App Store rating with Apple's own star sheet.
///
/// Apple decides whether the sheet actually appears (at most three times a
/// year per user), so asking is cheap; the rules here decide *when* it's
/// worth asking. Only someone who has used the app for a few days and has
/// several shots that landed on their guide, so they've seen it work. Never
/// twice in one app version, and never within [minGap] of the last ask.
///
/// The question is never "do you like Phily?" first: routing only happy
/// users to the store is review gating, which App Review rejects.
///
/// In debug builds the sheet always appears (Apple marks it "submitting is
/// disabled"); in TestFlight it never does.
class ReviewPrompt {
  ReviewPrompt._();

  static const int minLandedShots = 5;
  static const Duration minAge = Duration(days: 3);
  static const Duration minGap = Duration(days: 120);

  static const String _kLastAsked = 'phily_review_last_asked_ms';
  static const String _kAskedVersion = 'phily_review_asked_version';

  static bool _askedThisSession = false;

  /// The rule, separated out so it can be tested without a store.
  @visibleForTesting
  static bool shouldAsk({
    required int landedShots,
    required DateTime firstLaunch,
    required DateTime now,
    required String version,
    DateTime? lastAsked,
    String? askedVersion,
  }) {
    if (landedShots < minLandedShots) return false;
    if (now.difference(firstLaunch) < minAge) return false;
    if (askedVersion == version) return false;
    if (lastAsked != null && now.difference(lastAsked) < minGap) return false;
    return true;
  }

  /// Shows Apple's rating sheet if it's time. Safe to call often.
  static Future<void> maybeAsk() async {
    if (_askedThisSession) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final String version = (await PackageInfo.fromPlatform()).version;
      final int? last = prefs.getInt(_kLastAsked);
      final bool due = shouldAsk(
        landedShots: ShotGuideLog.instance.onGuideCount,
        firstLaunch: PhilyPro.instance.firstLaunch,
        now: DateTime.now(),
        version: version,
        lastAsked: last == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(last),
        askedVersion: prefs.getString(_kAskedVersion),
      );
      if (!due) return;
      final review = InAppReview.instance;
      if (!await review.isAvailable()) return;
      _askedThisSession = true;
      await prefs.setInt(_kLastAsked, DateTime.now().millisecondsSinceEpoch);
      await prefs.setString(_kAskedVersion, version);
      await review.requestReview();
    } catch (e) {
      debugLog('[ReviewPrompt] skipped: $e');
    }
  }
}
