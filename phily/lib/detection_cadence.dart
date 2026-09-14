// Adaptive detection cadence — how often the camera is allowed to run an ML
// Kit / Vision pass, derived from how long those passes actually take on THIS
// device.
//
// Pure Dart, no Flutter, so the policy can be tested without a camera: the
// whole point is behaviour on hardware we can't run in CI (an iPhone SE or an
// 11 detects far slower than a current Pro), and a fixed interval would either
// stutter there or waste headroom here.
//
// See also `LevelLineConfig` — same idea: tuning constants in one pure object
// rather than threaded through call sites.

/// Frame-gate policy for detection passes.
///
/// Feed it the measured cost of each pass with [note]; read [intervalMs] for
/// the current gate. A device that comfortably keeps up converges on
/// [floorMs]; a slower one settles at whatever it can actually sustain
/// instead of queueing work it can't finish.
class DetectionCadence {
  /// ~16 fps ceiling on detection. The historical fixed value, so a capable
  /// device behaves exactly as it did before the cadence became adaptive.
  static const int kFloorMs = 60;

  /// Never worse than ~5 fps tracking, however slow the device is.
  static const int kCeilMs = 200;

  /// Weight on each new measurement. Low, so one slow frame (a GC pause, a
  /// thermal blip) doesn't yank the cadence around.
  static const double kSmoothing = 0.15;

  /// Most the interval may move per pass, in ms — the cadence eases toward its
  /// target rather than jumping mid-session.
  static const int kMaxStepMs = 4;

  /// Fraction of the interval detection is allowed to occupy. 0.5 leaves half
  /// the frame budget for everything else (preview, overlays, UI).
  static const double kDutyCycle = 0.5;

  final int floorMs;
  final int ceilMs;

  DetectionCadence({this.floorMs = kFloorMs, this.ceilMs = kCeilMs})
    : _intervalMs = floorMs;

  int _intervalMs;
  double _costMs = 0;

  /// Current frame gate: skip a detection pass until this many ms have passed.
  int get intervalMs => _intervalMs;

  /// Smoothed estimate of what one pass costs on this device, in ms.
  double get costMs => _costMs;

  /// Feed in the measured cost of one detection pass. Non-positive readings
  /// are ignored — a zero means the clock didn't resolve, not a free pass.
  void note(int ms) {
    if (ms <= 0) return;
    _costMs += (ms - _costMs) * kSmoothing;
    final int want = (_costMs / kDutyCycle).round().clamp(floorMs, ceilMs);
    if (want != _intervalMs) {
      _intervalMs += (want - _intervalMs).clamp(-kMaxStepMs, kMaxStepMs);
    }
  }
}
