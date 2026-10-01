import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Where the free trial's start date lives so that deleting the app can't
/// reset it.
///
/// SharedPreferences is deleted with the app, so on its own a reinstall meant
/// a new seven days. Keychain items survive an uninstall. Apple describes that
/// as an implementation detail rather than a promise, which is why
/// [PhilyPro] also asks DeviceCheck once per device (see claimTrial in
/// firebase/functions/src/trial.ts).
///
/// Every call swallows platform errors: an unreadable Keychain must never
/// lock a paying user out or stall launch. It falls back to the old
/// behaviour instead.
class TrialAnchor {
  const TrialAnchor();

  /// The one [PhilyPro] reads. Tests, which have no Keychain, swap in an
  /// in-memory subclass.
  static TrialAnchor instance = const TrialAnchor();

  static const String _kStart = 'phily_trial_start_ms';
  static const String _kVerdict = 'phily_trial_devicecheck';

  // `first_unlock`, not the default `unlocked`: a launch that happens in the
  // background after a reboot can still read it. Not `_this_device`, so an
  // encrypted backup restored to a new phone carries the trial with it.
  static const FlutterSecureStorage _keychain = FlutterSecureStorage(
    iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock),
  );

  Future<DateTime?> readStart() async {
    try {
      final String? ms = await _keychain.read(key: _kStart);
      final int? v = ms == null ? null : int.tryParse(ms);
      return v == null ? null : DateTime.fromMillisecondsSinceEpoch(v);
    } catch (_) {
      return null;
    }
  }

  Future<void> writeStart(DateTime start) async {
    try {
      await _keychain.write(
        key: _kStart,
        value: '${start.millisecondsSinceEpoch}',
      );
    } catch (_) {}
  }

  /// Whether DeviceCheck has already given its answer for this device.
  Future<bool> deviceChecked() async {
    try {
      return await _keychain.read(key: _kVerdict) != null;
    } catch (_) {
      // Unknown: say yes, so a broken Keychain doesn't mean a server round
      // trip on every launch.
      return true;
    }
  }

  Future<void> markDeviceChecked(String verdict) async {
    try {
      await _keychain.write(key: _kVerdict, value: verdict);
    } catch (_) {}
  }
}
