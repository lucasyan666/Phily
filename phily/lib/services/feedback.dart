import 'dart:io' show Platform;

import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:phily/services/backend.dart';

/// What a message is about. The names are the wire values; they must match
/// `KINDS` in firebase/functions/src/rules.ts.
enum FeedbackKind { idea, issue, composition }

/// A send that failed, with a message worth showing the user.
class FeedbackError implements Exception {
  final String message;
  const FeedbackError(this.message);
  @override
  String toString() => message;
}

/// Sends feedback to the `submitFeedback` function, which stores it in
/// Firestore and forwards it to the developer's WhatsApp.
class FeedbackService {
  FeedbackService._();

  /// The consent wording shown beside the switch, by version. Must match
  /// `CONSENT` in firebase/functions/src/rules.ts. The server stores the
  /// version and its text with each email, so change the words by adding a
  /// new version there first, then bumping this.
  static const int consentVersion = 1;

  /// The switch's label and the line under it read as this one sentence.
  static const String consentTitle = 'You can reply to me about this';
  static const String consentDetail =
      'Your email is used only to answer this message.';

  static const int maxLength = 2000;

  // Deliberately loose; the server applies the same rule (rules.ts isEmail).
  static final RegExp _email = RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]{2,}$');

  static bool isEmail(String s) {
    final t = s.trim();
    return t.length <= 254 && _email.hasMatch(t);
  }

  /// Replaces the network call in tests. Receives exactly what would be sent.
  @visibleForTesting
  static Future<void> Function(Map<String, Object?> payload)? debugSender;

  /// Sends one message. [email] is sent only when the user switched on
  /// consent; pass null otherwise and it is never collected. [mode] names the
  /// composition guide the user came from, if any.
  static Future<void> send({
    required FeedbackKind kind,
    required String message,
    String? email,
    String? mode,
  }) async {
    final Map<String, Object?> payload = {
      'kind': kind.name,
      'message': message.trim(),
      'contact': email != null,
      if (email != null) 'email': email.trim(),
      if (email != null) 'consentVersion': consentVersion,
      'context': await _context(mode),
    };

    final sender = debugSender;
    if (sender != null) return sender(payload);

    if (!await Backend.ensure()) {
      throw const FeedbackError('Feedback isn\'t connected in this build yet.');
    }
    try {
      await Backend.call('submitFeedback').call<Object?>(payload);
    } on FirebaseFunctionsException catch (e) {
      throw FeedbackError(switch (e.code) {
        // The server's own words for these: a bad email, a limit hit.
        'invalid-argument' ||
        'resource-exhausted' => e.message ?? 'That couldn\'t be sent.',
        'unavailable' || 'deadline-exceeded' || 'internal' =>
          'Couldn\'t reach Phily. Check your connection and try again.',
        _ => 'That didn\'t send. Try again in a moment.',
      });
    }
  }

  /// App version, iOS version and the guide in use — what a bug report needs
  /// and nothing that identifies the phone. No device model, no identifiers.
  static Future<Map<String, String>> _context(String? mode) async {
    final Map<String, String> ctx = {};
    try {
      final info = await PackageInfo.fromPlatform();
      ctx['appVersion'] = info.version;
      ctx['build'] = info.buildNumber;
    } catch (_) {}
    try {
      // "Version 18.6 (Build 22G86)" → "iOS 18.6".
      final m = RegExp(r'[\d.]+').firstMatch(Platform.operatingSystemVersion);
      if (m != null) ctx['os'] = 'iOS ${m.group(0)}';
    } catch (_) {}
    if (mode != null) ctx['mode'] = mode;
    return ctx;
  }
}
