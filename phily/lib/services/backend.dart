import 'dart:async';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:phily/debug.dart';

/// Phily's server side — Firebase, in London (see firebase/README.md).
///
/// Everything here is optional at runtime. A build without
/// `ios/Runner/GoogleService-Info.plist` (a fresh clone, or before the project
/// is set up) runs exactly as before: the camera, gallery and paywall never
/// touch this, and feedback and sign-in explain that they're unavailable
/// instead of crashing.
class Backend {
  Backend._();

  /// Must match `REGION` in firebase/functions/src/config.ts.
  static const String region = 'europe-west2';

  static const MethodChannel _platform = MethodChannel('phily/platform');

  static Future<bool>? _ready;

  /// Starts Firebase once; every later call returns the same answer. Never
  /// throws: false means "carry on without a server".
  static Future<bool> ensure() => _ready ??= _start();

  static Future<bool> _start() async {
    try {
      // Asked natively first: with no plist, Firebase's own configure() raises
      // an Objective-C exception that Dart can't catch.
      final bool configured =
          await _platform.invokeMethod<bool>('hasFirebaseConfig') ?? false;
      if (!configured) {
        debugLog('[Backend] no GoogleService-Info.plist — running offline');
        return false;
      }
      await Firebase.initializeApp();
      // App Check proves each call comes from a genuine copy of Phily on a
      // real device (App Attest), which is what stops a script from flooding
      // the feedback relay. Only release builds (TestFlight, App Store) can
      // attest; debug and profile builds use a debug token instead — register
      // the one printed in the Xcode console (see firebase/README.md).
      await FirebaseAppCheck.instance.activate(
        providerApple: kReleaseMode
            ? const AppleAppAttestWithDeviceCheckFallbackProvider()
            : const AppleDebugProvider(),
      );
      return true;
    } catch (e) {
      debugLog('[Backend] Firebase unavailable: $e');
      return false;
    }
  }

  /// A callable function in [region], with a timeout short enough that a
  /// dead connection fails while the user is still watching the button.
  static HttpsCallable call(String name) =>
      FirebaseFunctions.instanceFor(region: region).httpsCallable(
        name,
        options: HttpsCallableOptions(timeout: const Duration(seconds: 20)),
      );

  /// A base64 DeviceCheck token for this device, or null where DeviceCheck
  /// isn't supported (the Simulator).
  static Future<String?> deviceCheckToken() async {
    try {
      return await _platform.invokeMethod<String>('deviceCheckToken');
    } catch (_) {
      return null;
    }
  }

  static final StreamController<Uri> _links = StreamController.broadcast();

  /// Universal links opened while the app is running — the email sign-in
  /// link. Delivered by `IncomingLinks` in AppDelegate.swift.
  static Stream<Uri> get links => _links.stream;

  /// Starts [links] and returns the link that launched the app, if any.
  /// Call once, from the root of the app.
  static Future<Uri?> listenForLinks() async {
    _platform.setMethodCallHandler((call) async {
      if (call.method == 'link' && call.arguments is String) {
        final Uri? uri = Uri.tryParse(call.arguments as String);
        if (uri != null) _links.add(uri);
      }
    });
    try {
      final String? s = await _platform.invokeMethod<String>('initialLink');
      return s == null ? null : Uri.tryParse(s);
    } catch (_) {
      return null;
    }
  }
}
