import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Entitlement + subscription manager for **Phily Pro**.
///
/// Free trial: every composition mode is unlocked for the first [trialDays]
/// after install. After that only `None` stays free — the rest require an active
/// Phily Pro subscription.
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

  /// Must match the auto-renewable subscription you create in App Store Connect.
  static const String subscriptionId = 'phily_pro_monthly';
  static const int trialDays = 7;

  static const String _kFirstLaunch = 'phily_first_launch_ms';
  static const String _kSubscribed = 'phily_subscribed';

  final InAppPurchase _iap = InAppPurchase.instance;
  StreamSubscription<List<PurchaseDetails>>? _sub;

  DateTime _firstLaunch = DateTime.now();
  bool _subscribed = false;
  bool _storeReady = false;
  ProductDetails? _product;

  bool get subscribed => _subscribed;
  bool get storeReady => _storeReady;
  ProductDetails? get product => _product;

  /// Localised price string (e.g. "$2.99"), or empty until the store responds.
  String get priceLabel => _product?.price ?? '';

  bool get trialActive =>
      DateTime.now().difference(_firstLaunch).inDays < trialDays;

  int get trialDaysLeft =>
      (trialDays - DateTime.now().difference(_firstLaunch).inDays).clamp(
        0,
        trialDays,
      );

  /// True when the user may use the paid composition modes (active trial or sub).
  bool get isPro => _subscribed || trialActive;

  /// Call once at launch. Loads the trial clock + wires the store.
  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    final ms = prefs.getInt(_kFirstLaunch);
    if (ms == null) {
      _firstLaunch = DateTime.now();
      await prefs.setInt(_kFirstLaunch, _firstLaunch.millisecondsSinceEpoch);
    } else {
      _firstLaunch = DateTime.fromMillisecondsSinceEpoch(ms);
    }
    _subscribed = prefs.getBool(_kSubscribed) ?? false;
    notifyListeners();

    _storeReady = await _iap.isAvailable();
    if (!_storeReady) return;

    _sub = _iap.purchaseStream.listen(_onPurchases, onError: (_) {});
    final resp = await _iap.queryProductDetails({subscriptionId});
    if (resp.productDetails.isNotEmpty) _product = resp.productDetails.first;
    notifyListeners();
    // Pick up an existing subscription (reinstall / new device / re-login).
    await _iap.restorePurchases();
  }

  /// Start the subscription purchase flow. Returns false if the product isn't
  /// loaded yet (store unavailable / id mismatch).
  Future<bool> subscribe() async {
    final p = _product;
    if (p == null) return false;
    return _iap.buyNonConsumable(
      purchaseParam: PurchaseParam(productDetails: p),
    );
  }

  Future<void> restore() => _iap.restorePurchases();

  Future<void> _onPurchases(List<PurchaseDetails> purchases) async {
    for (final pd in purchases) {
      if ((pd.status == PurchaseStatus.purchased ||
              pd.status == PurchaseStatus.restored) &&
          pd.productID == subscriptionId) {
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

  // ── Debug helpers — for testing the lock without waiting / editing constants.
  // Only ever called from kDebugMode UI.

  /// Start a fresh trial ([expired] == false), or pretend it began long ago so
  /// the app is locked right now ([expired] == true).
  Future<void> debugSetTrial({required bool expired}) async {
    _firstLaunch = expired
        ? DateTime.now().subtract(const Duration(days: 3650))
        : DateTime.now();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_kFirstLaunch, _firstLaunch.millisecondsSinceEpoch);
    notifyListeners();
  }

  /// Force the subscribed flag (simulate a purchase / cancellation) sans StoreKit.
  Future<void> debugSetSubscribed(bool v) => _setSubscribed(v);

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }
}
