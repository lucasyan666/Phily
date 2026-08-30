import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Entitlement + subscription manager for **Phily Pro**.
///
/// Free trial: every composition mode is unlocked for the first [trialDays]
/// after install. After that only `None` stays free — the rest require an active
/// Phily Pro subscription (monthly/yearly) or the one-time lifetime unlock.
///
/// A `ChangeNotifier` so the UI can rebuild when entitlement changes (trial
/// expires, purchase completes, restore).
///
/// NOTE: subscription state here is the on-device flag set when StoreKit reports
/// a purchase/restore. A production app should *also* validate the receipt and
/// expiry server-side — this client check is fine to gate the UI and to start.
class PhilyPro extends ChangeNotifier {
  PhilyPro._();
  static final PhilyPro instance = PhilyPro._();

  /// Product ids — must match App Store Connect / the StoreKit config.
  static const String monthlyId = 'phily_pro_monthly';
  static const String yearlyId = 'phily_pro_yearly';
  static const String lifetimeId = 'phily_pro_lifetime';
  static const Set<String> _allIds = {monthlyId, yearlyId, lifetimeId};
  static const Set<String> _subIds = {monthlyId, yearlyId};

  static const int trialDays = 7;

  /// Test seam — all trial math reads the time through this so tests can pin
  /// the clock at exact day boundaries. Production never reassigns it.
  @visibleForTesting
  static DateTime Function() clock = DateTime.now;

  static const String _kFirstLaunch = 'phily_first_launch_ms';
  static const String _kSubscribed = 'phily_subscribed';
  static const String _kLifetime = 'phily_lifetime';
  static const String _kLastVerified = 'phily_last_verified_ms';

  /// How often to re-check an active subscription against the store. A lapsed
  /// subscription only clears client-side on a verify, so this bounds how long
  /// a cancelled subscriber can keep Pro after the fact — long enough to never
  /// add launch/resume latency (the check is throttled, never launch-blocking),
  /// short enough that the revenue leak this guards against stays small.
  static const Duration _verifyInterval = Duration(hours: 24);

  // Lazy: merely touching PhilyPro.instance must not spin up the store plugin
  // (it eagerly opens a billing connection on Android, and unit tests exercise
  // the trial math with no platform channels at all). First read is in init().
  late final InAppPurchase _iap = InAppPurchase.instance;
  StreamSubscription<List<PurchaseDetails>>? _sub;

  DateTime _firstLaunch = clock();
  bool _subscribed = false;
  bool _lifetime = false;
  bool _storeReady = false;
  DateTime? _lastVerified;
  bool _verifying = false;
  final Map<String, ProductDetails> _products = {};

  bool get subscribed => _subscribed;
  bool get lifetime => _lifetime;
  bool get storeReady => _storeReady;

  /// Loaded product (price/title) for a tier id, or null until the store replies.
  ProductDetails? productFor(String id) => _products[id];

  /// Localised monthly price (e.g. "$2.99"), or empty until the store responds.
  String get priceLabel => _products[monthlyId]?.price ?? '';

  bool get trialActive =>
      clock().difference(_firstLaunch).inDays < trialDays;

  int get trialDaysLeft =>
      (trialDays - clock().difference(_firstLaunch).inDays).clamp(
        0,
        trialDays,
      );

  /// Calendar date the trial lapses — for the on-screen trial signal.
  DateTime get trialEndDate =>
      _firstLaunch.add(const Duration(days: trialDays));

  /// Whether to show the trial countdown chip (on trial, not yet a paying user).
  bool get showTrialBadge => trialActive && !_subscribed && !_lifetime;

  /// True when the user may use the paid composition modes (trial, sub, or buy).
  bool get isPro => _subscribed || _lifetime || trialActive;

  /// Call once at launch. Loads the trial clock + wires the store.
  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    final ms = prefs.getInt(_kFirstLaunch);
    if (ms == null) {
      _firstLaunch = clock();
      await prefs.setInt(_kFirstLaunch, _firstLaunch.millisecondsSinceEpoch);
    } else {
      _firstLaunch = DateTime.fromMillisecondsSinceEpoch(ms);
    }
    _subscribed = prefs.getBool(_kSubscribed) ?? false;
    _lifetime = prefs.getBool(_kLifetime) ?? false;
    final verifiedMs = prefs.getInt(_kLastVerified);
    _lastVerified = verifiedMs == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(verifiedMs);
    notifyListeners();

    _storeReady = await _iap.isAvailable();
    if (!_storeReady) return;

    // Start listening BEFORE marking a subscriber as "seen this round" — a
    // subscription that lapsed since the last check only clears if we're
    // already listening when its absence is (implicitly) confirmed below.
    _sub = _iap.purchaseStream.listen(_onPurchases, onError: (_) {});
    final resp = await _iap.queryProductDetails(_allIds);
    for (final p in resp.productDetails) {
      _products[p.id] = p;
    }
    notifyListeners();
    // Pick up an existing entitlement (reinstall / new device / re-login) —
    // caller (the camera page) doesn't await init(), so this never blocks
    // launch. Also doubles as the first "verify" pass; see maybeReverify.
    await _reverifyEntitlement();
  }

  /// Re-checks the current entitlement against the store, throttled to once
  /// per [_verifyInterval]. Call opportunistically (e.g. on app resume) — it's
  /// a cheap no-op most of the time and the network round-trip, when it does
  /// run, never blocks the caller or gates any UI.
  void maybeReverify() {
    if (!_storeReady || _verifying) return;
    final last = _lastVerified;
    if (last != null && clock().difference(last) < _verifyInterval) return;
    unawaited(_reverifyEntitlement());
  }

  /// Asks StoreKit to re-emit the account's current entitlements. A lapsed
  /// subscription simply doesn't come back through the stream — [_onPurchases]
  /// only ever *sets* flags from what it's told, so the absence has to be
  /// noticed explicitly here, after giving the store a moment to respond.
  Future<void> _reverifyEntitlement() async {
    _verifying = true;
    final wasSubscribed = _subscribed;
    try {
      await _iap.restorePurchases();
      // restorePurchases() resolves once the request is sent, not once every
      // purchase update has arrived — give the stream a brief window to
      // deliver them before treating "still not subscribed" as authoritative.
      if (wasSubscribed) {
        await Future<void>.delayed(const Duration(seconds: 3));
        if (_subscribed == wasSubscribed && !_lifetime) {
          // The store had its chance to reassert the subscription and didn't
          // — it lapsed (cancelled, billing failure, refunded) since our last
          // check. Clear it so isPro reflects reality again.
          await _setSubscribed(false);
        }
      }
      _lastVerified = clock();
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_kLastVerified, _lastVerified!.millisecondsSinceEpoch);
    } catch (_) {
      // Offline or store hiccup — keep the last-known entitlement rather than
      // punishing a paying user for a network blip. We'll try again next
      // throttle window.
    } finally {
      _verifying = false;
    }
  }

  /// Start the purchase flow for a tier (monthly/yearly subscription or the
  /// one-time lifetime unlock). Returns false if the product isn't loaded.
  Future<bool> buy(ProductDetails product) {
    return _iap.buyNonConsumable(
      purchaseParam: PurchaseParam(productDetails: product),
    );
  }

  Future<void> restore() => _iap.restorePurchases();

  Future<void> _onPurchases(List<PurchaseDetails> purchases) async {
    for (final pd in purchases) {
      final bool ok =
          pd.status == PurchaseStatus.purchased ||
          pd.status == PurchaseStatus.restored;
      if (ok && pd.productID == lifetimeId) {
        await _setLifetime(true);
      } else if (ok && _subIds.contains(pd.productID)) {
        await _setSubscribed(true);
      }
      if (pd.pendingCompletePurchase) await _iap.completePurchase(pd);
    }
  }

  Future<void> _setSubscribed(bool v) async {
    if (_subscribed == v) return;
    _subscribed = v;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kSubscribed, v);
    notifyListeners();
  }

  Future<void> _setLifetime(bool v) async {
    if (_lifetime == v) return;
    _lifetime = v;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kLifetime, v);
    notifyListeners();
  }

  // ── Debug helpers — for testing the lock without waiting / editing constants.
  // Only ever called from kDebugMode UI.

  /// Start a fresh trial ([expired] == false), or pretend it began long ago so
  /// the app is locked right now ([expired] == true).
  Future<void> debugSetTrial({required bool expired}) async {
    _firstLaunch = expired
        ? clock().subtract(const Duration(days: 3650))
        : clock();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_kFirstLaunch, _firstLaunch.millisecondsSinceEpoch);
    notifyListeners();
  }

  /// Force the entitlement flags (simulate a purchase / cancellation) sans
  /// StoreKit — clears the lifetime flag too so "lock all" really locks.
  Future<void> debugSetSubscribed(bool v) async {
    if (!v) await _setLifetime(false);
    await _setSubscribed(v);
  }

  /// Force the lifetime flag alone — the debug menu only goes through
  /// [debugSetSubscribed]; tests use this to cover the lifetime path of [isPro].
  @visibleForTesting
  Future<void> debugSetLifetime(bool v) => _setLifetime(v);

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }
}
