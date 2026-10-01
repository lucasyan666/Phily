import 'dart:async';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:phily/debug.dart';
import 'package:phily/services/backend.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Something the user should read: a sign-in that failed for a reason they
/// can act on. Cancelling a sign-in sheet is not an error and never throws.
class AccountException implements Exception {
  final String message;
  const AccountException(this.message);
  @override
  String toString() => message;
}

/// The optional Phily account: Sign in with Apple, Google, or a one-time
/// email link, via Firebase Auth.
///
/// Nothing in the camera needs it — App Store guideline 5.1.1(v) forbids
/// making a camera sign in — so every screen must work signed out. Today it
/// fills in the feedback form's reply address and ties feedback to an
/// account so deleting the account deletes it.
class PhilyAccount extends ChangeNotifier {
  PhilyAccount._();
  static final PhilyAccount instance = PhilyAccount._();

  static const String _kPendingEmail = 'phily_email_link_pending';

  Future<bool>? _started;
  StreamSubscription<User?>? _sub;
  User? _user;
  bool _available = false;
  String? _pendingEmail;
  String? _linkAwaitingEmail;
  bool _googleReady = false;

  /// Whether this build can reach the server at all (see [Backend]).
  bool get available => _available;
  bool get signedIn => _user != null;
  String? get email => _user?.email;
  String? get photoUrl => _user?.photoURL;

  /// "Lucas" from "Lucas Yan"; null when the provider gave no name — Apple
  /// shares one only on the very first sign-in, and email links never do.
  String? get firstName {
    final String? n = _user?.displayName?.trim();
    if (n == null || n.isEmpty) return null;
    return n.split(RegExp(r'\s+')).first;
  }

  /// The address a sign-in link was last sent to, while it waits to be
  /// opened.
  String? get pendingEmail => _pendingEmail;

  /// A sign-in link that arrived on a phone that never asked for it (or whose
  /// app data was cleared since). Firebase needs the address to finish, so
  /// the account sheet asks for it.
  bool get linkAwaitingEmail => _linkAwaitingEmail != null;

  /// "Apple", "Google" or "Email" — how the user signed in.
  String? get providerLabel {
    final ids = _user?.providerData.map((p) => p.providerId).toSet() ?? {};
    if (ids.contains('apple.com')) return 'Apple';
    if (ids.contains('google.com')) return 'Google';
    if (_user != null) return 'Email';
    return null;
  }

  /// Starts listening for the signed-in user. Cheap to call repeatedly; the
  /// account button calls it on first build, not app launch, so Firebase
  /// stays off the camera's cold-start path.
  Future<bool> ensureStarted() => _started ??= _start();

  Future<bool> _start() async {
    _available = await Backend.ensure();
    if (!_available) {
      notifyListeners();
      return false;
    }
    final prefs = await SharedPreferences.getInstance();
    _pendingEmail = prefs.getString(_kPendingEmail);
    _user = FirebaseAuth.instance.currentUser;
    // userChanges, not authStateChanges: it also fires when the display name
    // or email changes, so the sheet stays in step without a restart.
    _sub = FirebaseAuth.instance.userChanges().listen((u) {
      _user = u;
      notifyListeners();
    });
    notifyListeners();
    return true;
  }

  Future<void> _requireBackend() async {
    if (!await ensureStarted()) {
      throw const AccountException(
        'Accounts aren\'t connected in this build yet.',
      );
    }
  }

  // ── Apple ──────────────────────────────────────────────────────────────────

  AppleAuthProvider get _apple => AppleAuthProvider()
    ..addScope('email')
    ..addScope('name');

  /// Returns false if the user closed Apple's sheet.
  Future<bool> signInWithApple() async {
    await _requireBackend();
    try {
      await FirebaseAuth.instance.signInWithProvider(_apple);
      return true;
    } on FirebaseAuthException catch (e) {
      if (_cancelled(e)) return false;
      throw AccountException(_explain(e));
    }
  }

  // ── Google ─────────────────────────────────────────────────────────────────

  /// Returns false if the user closed Google's sheet.
  Future<bool> signInWithGoogle() async {
    await _requireBackend();
    final google = GoogleSignIn.instance;
    try {
      if (!_googleReady) {
        // The client ID comes from GoogleService-Info.plist.
        await google.initialize();
        _googleReady = true;
      }
      final account = await google.authenticate(scopeHint: const ['email']);
      final String? idToken = account.authentication.idToken;
      if (idToken == null) {
        throw const AccountException('Google didn\'t confirm who you are.');
      }
      await FirebaseAuth.instance.signInWithCredential(
        GoogleAuthProvider.credential(idToken: idToken),
      );
      return true;
    } on GoogleSignInException catch (e) {
      if (e.code == GoogleSignInExceptionCode.canceled) return false;
      debugLog('[Account] Google: $e');
      throw const AccountException('Google sign-in didn\'t finish. Try again.');
    } on FirebaseAuthException catch (e) {
      throw AccountException(_explain(e));
    }
  }

  // ── Email link ─────────────────────────────────────────────────────────────

  /// Emails a one-time sign-in link. It opens back in the app through the
  /// project's Firebase Hosting domain (an iOS Associated Domain — see
  /// firebase/README.md).
  Future<void> sendEmailLink(String address) async {
    await _requireBackend();
    final String email = address.trim();
    final options = Firebase.app().options;
    final String domain = '${options.projectId}.firebaseapp.com';
    try {
      await FirebaseAuth.instance.sendSignInLinkToEmail(
        email: email,
        actionCodeSettings: ActionCodeSettings(
          url: 'https://$domain/signed-in',
          handleCodeInApp: true,
          iOSBundleId: options.iosBundleId,
          linkDomain: domain,
        ),
      );
    } on FirebaseAuthException catch (e) {
      throw AccountException(_explain(e));
    }
    _pendingEmail = email;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kPendingEmail, email);
    notifyListeners();
  }

  /// Forget the pending address, e.g. to try a different one.
  Future<void> cancelEmailLink() async {
    _pendingEmail = null;
    _linkAwaitingEmail = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kPendingEmail);
    notifyListeners();
  }

  /// Hands an incoming universal link to Firebase. Returns true if it was a
  /// sign-in link and the user is now signed in; false if it wasn't one, or
  /// it needs [completeEmailLink] with the address first.
  Future<bool> handleLink(Uri uri) async {
    if (!await ensureStarted()) return false;
    final String link = uri.toString();
    if (!FirebaseAuth.instance.isSignInWithEmailLink(link)) return false;
    final String? email = _pendingEmail;
    if (email == null) {
      _linkAwaitingEmail = link;
      notifyListeners();
      return false;
    }
    await _finishLink(email, link);
    return true;
  }

  /// Finishes a link that arrived without a pending address (see
  /// [linkAwaitingEmail]).
  Future<void> completeEmailLink(String address) async {
    final String? link = _linkAwaitingEmail;
    if (link == null) return;
    await _finishLink(address.trim(), link);
  }

  Future<void> _finishLink(String email, String link) async {
    try {
      await FirebaseAuth.instance.signInWithEmailLink(
        email: email,
        emailLink: link,
      );
    } on FirebaseAuthException catch (e) {
      throw AccountException(_explain(e));
    }
    _linkAwaitingEmail = null;
    await cancelEmailLink();
  }

  // ── Leaving ────────────────────────────────────────────────────────────────

  Future<void> signOut() async {
    if (!_available) return;
    await FirebaseAuth.instance.signOut();
    if (_googleReady) {
      try {
        await GoogleSignIn.instance.signOut();
      } catch (_) {}
    }
  }

  /// Deletes the account and everything linked to it, on the server.
  ///
  /// Sign in with Apple accounts must also have their Apple token revoked
  /// (App Store guideline 5.1.1(v), since June 2022). That needs a fresh
  /// authorisation code, so Apple's sheet appears once more to confirm.
  /// Returns false if the user cancels that sheet: nothing is deleted.
  Future<bool> deleteAccount() async {
    await _requireBackend();
    final User? user = _user;
    if (user == null) return false;
    try {
      if (providerLabel == 'Apple') {
        final cred = await user.reauthenticateWithProvider(_apple);
        final String? code = cred.additionalUserInfo?.authorizationCode;
        if (code != null) {
          await FirebaseAuth.instance.revokeTokenWithAuthorizationCode(code);
        }
      }
      await Backend.call('deleteAccount').call<Object?>();
    } on FirebaseAuthException catch (e) {
      if (_cancelled(e)) return false;
      throw AccountException(_explain(e));
    } on FirebaseFunctionsException catch (_) {
      throw const AccountException(
        'Couldn\'t reach Phily to delete your account. Check your connection '
        'and try again.',
      );
    }
    await signOut();
    return true;
  }

  // ── Errors ─────────────────────────────────────────────────────────────────

  /// Closing Apple's sheet surfaces as an error whose shape has varied across
  /// SDK versions ("canceled", "web-context-canceled", or ASAuthorization's
  /// code 1001), so match loosely.
  static bool _cancelled(FirebaseAuthException e) =>
      e.code.contains('cancel') || '${e.message}'.contains('1001');

  static String _explain(FirebaseAuthException e) => switch (e.code) {
    'network-request-failed' =>
      'You\'re offline. Check your connection and try again.',
    'invalid-email' => 'That email doesn\'t look right.',
    'invalid-action-code' || 'expired-action-code' =>
      'That link has expired or was already used. Send a new one.',
    'account-exists-with-different-credential' =>
      'This email already has a Phily account through another sign-in. Use '
          'that one.',
    'user-disabled' => 'This account has been disabled.',
    'too-many-requests' => 'Too many tries. Wait a minute, then try again.',
    _ => 'Sign-in didn\'t finish. Try again.',
  };

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }
}
