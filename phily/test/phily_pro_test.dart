// Trial + entitlement math for PhilyPro — the logic that decides whether a
// user is Pro, and the one place a silent regression costs real money (either
// locking out paying users or giving Pro away free).
//
// Runs entirely against the pure layer: time is pinned through PhilyPro.clock
// and SharedPreferences is mocked, so no StoreKit/platform channels are hit.
// init() (store wiring, purchase stream, restore) is deliberately not covered —
// it talks to the real IAP plugin and can only be exercised on-device.
import 'package:flutter_test/flutter_test.dart';
import 'package:phily/services/phily_pro.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // An arbitrary fixed "install" moment; every test moves the clock from here.
  final t0 = DateTime(2026, 3, 10, 14, 30);
  final pro = PhilyPro.instance;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    PhilyPro.clock = () => t0;
    await pro.debugSetTrial(expired: false); // first launch = t0
    await pro.debugSetSubscribed(false); // clears the lifetime flag too
  });

  tearDownAll(() {
    PhilyPro.clock = DateTime.now;
  });

  group('trial window', () {
    test('fresh install: full trial, Pro, badge shown', () {
      expect(pro.trialActive, isTrue);
      expect(pro.trialDaysLeft, PhilyPro.trialDays);
      expect(pro.isPro, isTrue);
      expect(pro.showTrialBadge, isTrue);
    });

    test('last hour of the trial still counts, with 1 day left', () {
      PhilyPro.clock = () =>
          t0.add(const Duration(days: PhilyPro.trialDays, hours: -1));
      expect(pro.trialActive, isTrue);
      expect(pro.trialDaysLeft, 1);
      expect(pro.isPro, isTrue);
    });

    test('exactly trialDays x 24h after install the trial is over', () {
      PhilyPro.clock = () => t0.add(const Duration(days: PhilyPro.trialDays));
      expect(pro.trialActive, isFalse);
      expect(pro.trialDaysLeft, 0);
      expect(pro.isPro, isFalse);
      expect(pro.showTrialBadge, isFalse);
    });

    test('daysLeft clamps to 0 long after expiry, never negative', () {
      PhilyPro.clock = () => t0.add(const Duration(days: 400));
      expect(pro.trialDaysLeft, 0);
    });

    test('trialEndDate is install + trialDays', () {
      expect(
        pro.trialEndDate,
        t0.add(const Duration(days: PhilyPro.trialDays)),
      );
    });
  });

  group('entitlement truth table', () {
    test('a subscription rescues an expired trial', () async {
      PhilyPro.clock = () => t0.add(const Duration(days: 30));
      expect(pro.isPro, isFalse);
      await pro.debugSetSubscribed(true);
      expect(pro.isPro, isTrue);
      expect(pro.showTrialBadge, isFalse);
    });

    test('the lifetime unlock rescues an expired trial', () async {
      PhilyPro.clock = () => t0.add(const Duration(days: 30));
      expect(pro.isPro, isFalse);
      await pro.debugSetLifetime(true);
      expect(pro.isPro, isTrue);
      expect(pro.showTrialBadge, isFalse);
    });

    test('subscribing during the trial hides the countdown badge', () async {
      await pro.debugSetSubscribed(true);
      expect(pro.trialActive, isTrue);
      expect(pro.isPro, isTrue);
      expect(pro.showTrialBadge, isFalse);
    });

    test('clearing all entitlements after expiry locks the app', () async {
      await pro.debugSetSubscribed(true);
      await pro.debugSetLifetime(true);
      PhilyPro.clock = () => t0.add(const Duration(days: 30));
      await pro.debugSetSubscribed(false); // also clears lifetime
      expect(pro.subscribed, isFalse);
      expect(pro.lifetime, isFalse);
      expect(pro.isPro, isFalse);
    });
  });

  group('persistence', () {
    test('entitlement flags round-trip through prefs', () async {
      await pro.debugSetSubscribed(true);
      var prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('phily_subscribed'), isTrue);

      await pro.debugSetLifetime(true);
      expect(prefs.getBool('phily_lifetime'), isTrue);

      await pro.debugSetSubscribed(false);
      expect(prefs.getBool('phily_subscribed'), isFalse);
      expect(prefs.getBool('phily_lifetime'), isFalse);
    });

    test('the trial clock is persisted on (debug) reset', () async {
      await pro.debugSetTrial(expired: false);
      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getInt('phily_first_launch_ms'),
        t0.millisecondsSinceEpoch,
      );
    });
  });
}
