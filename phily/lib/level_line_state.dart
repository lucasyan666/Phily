import 'dart:math' as math;

// ─────────────────────────────────────────────────────────────────────────────
// Adaptive level-line state machine
//
// The gravity line is a *correction aid*, not an instrument panel. It should
// appear while you're actively working the phone toward level, and get out of
// the way both when you've got it and when you've clearly chosen not to.
//
// Pure logic, no Flutter: every input is passed in and every output is read
// back, so the behaviour can be exercised directly in tests and the tuning
// constants below can be adjusted without touching the drawing code.
// ─────────────────────────────────────────────────────────────────────────────

/// What the painter needs each tick: the live angles, the level verdict, plus
/// the state machine's outputs (visibility target, amber→green tone, and
/// whether to snap to centre for the level confirmation).
typedef LevelReading = ({
  double roll,
  double vert,
  bool level,
  double visible,
  double tone,
  bool snap,
  /// 0 = horizon line, 1 = bubble level; eased, so the painter morphs.
  double overhead,
  /// Bubble offset, -1..1 per axis (1 = ring edge).
  double bubbleX,
  double bubbleY,
});

/// Tuning constants. All angles in DEGREES, all times in MILLISECONDS — the
/// units you'd actually reason about when tuning after user testing.
class LevelLineConfig {
  /// Only tilts within this much of level are treated as "trying to level".
  /// Beyond it the shot is assumed to be deliberately angled (a pan, a Dutch
  /// angle) and the line never appears at all.
  final double correctionRangeDeg;

  /// Inside this, the shot counts as level.
  final double levelToleranceDeg;

  /// Angular speed above which the phone counts as actively moving.
  final double stationaryThresholdDegPerSec;

  /// How long the phone must sit still (off-level) before we accept that the
  /// angle is deliberate and hide the line.
  final int settleDurationMs;

  /// How long the confirmed-level line stays up before fading out.
  final int levelHoldMs;

  /// A state change must hold for this long before it's acted on. Stops the
  /// line flickering when a value hovers right on a threshold.
  final int debounceMs;

  /// Opacity fade, in and out.
  final int fadeInMs;
  final int fadeOutMs;

  /// Pitch is compressed by this before being compared against the roll-based
  /// thresholds, so one tolerance can serve both axes. It also sets how close
  /// to flat you can get before the line gives up: it hides past
  /// `correctionRangeDeg / pitchScale` of pitch, i.e.
  /// `90 - correctionRangeDeg / pitchScale` degrees of leniency around flat.
  /// At 0.364 that's ~55°, leaving ~35° of slack for deliberately steep shots.
  final double pitchScale;

  /// Past this much pitch from vertical the phone is being aimed at the ground
  /// or the sky, and the horizon line stops being the right instrument — the
  /// bubble level takes over. See [LevelLineMachine.overheadBlend].
  final double overheadEnterDeg;

  /// Drop back below this to return to the horizon line. The gap between the
  /// two is hysteresis: without it the instrument would swap back and forth
  /// while you hover at the boundary.
  final double overheadExitDeg;

  /// How far off flat the bubble may sit and still read as level.
  final double bubbleToleranceDeg;

  /// Physical tilt that pushes the bubble to the edge of its ring.
  final double bubbleRangeDeg;

  const LevelLineConfig({
    this.correctionRangeDeg = 20.0,
    this.levelToleranceDeg = 1.5,
    this.stationaryThresholdDegPerSec = 2.0,
    this.settleDurationMs = 800,
    this.levelHoldMs = 400,
    this.debounceMs = 100,
    this.fadeInMs = 150,
    this.fadeOutMs = 200,
    this.pitchScale = 0.364,
    // Enter just before the line's own cutoff (~55°) so the bubble picks up
    // exactly where the line lets go — no band where neither is showing.
    this.overheadEnterDeg = 54.0,
    this.overheadExitDeg = 46.0,
    this.bubbleToleranceDeg = 1.5,
    this.bubbleRangeDeg = 12.0,
  });
}

/// What the line is doing right now.
enum LevelLineState {
  /// Hidden. Nothing to correct, or the user has settled on an angle.
  idle,

  /// Visible and amber: the phone is near level and being actively adjusted.
  active,

  /// Level just achieved — snapped to centre, green, briefly held before it
  /// fades away.
  leveled,
}

/// Drives the level line's visibility from tilt + angular velocity.
///
/// Feed it [update] on every sensor tick; read [opacityTarget], [state] and
/// [justLeveled] back. It owns no timers — everything is derived from the
/// wall-clock timestamps passed in, so it stays correct regardless of how
/// often (or how unevenly) the sensor stream fires.
class LevelLineMachine {
  LevelLineConfig config;

  /// When true the machine is bypassed entirely and the line is always shown —
  /// backs the "Always show level line" setting.
  bool alwaysShow;

  LevelLineMachine({
    this.config = const LevelLineConfig(),
    this.alwaysShow = false,
  });

  LevelLineState _state = LevelLineState.idle;
  LevelLineState get state => _state;

  /// True for exactly one update: the tick level was newly confirmed. The
  /// caller fires its haptic off this.
  bool _justLeveled = false;
  bool get justLeveled => _justLeveled;

  /// Where the line's opacity should be heading (0 or 1). The painter eases
  /// toward this; see [fadeTauSeconds].
  double get opacityTarget =>
      alwaysShow || _state != LevelLineState.idle ? 1.0 : 0.0;

  /// True while the line should be drawn snapped to dead centre (the level
  /// confirmation), rather than tracking the live angle.
  bool get snapToCentre => _state == LevelLineState.leveled;

  /// 1 when the line should read as "level" (green), 0 as "correcting" (amber).
  double get levelTone => _state == LevelLineState.leveled ? 1.0 : 0.0;

  // Timestamps (ms). 0 = not started.
  int _lastAngleMs = 0;
  double _lastAngleDeg = 0;
  int _stationarySinceMs = 0;
  int _leveledAtMs = 0;
  // Debounce: a pending state we're waiting to confirm.
  LevelLineState? _pending;
  int _pendingSinceMs = 0;
  // Smoothed angular velocity — raw deltas off a noisy accelerometer spike
  // wildly, and an unsmoothed value would flip the stationary test constantly.
  double _angVelDegPerSec = 0;
  double get angularVelocityDegPerSec => _angVelDegPerSec;

  // ── Overhead / bubble mode ──
  // `_overhead` is the latched decision (with hysteresis); `overheadBlend` is
  // the eased 0..1 the painter morphs on, so the line becomes the bubble as one
  // continuous instrument rather than a swap between two.
  bool _overhead = false;
  double _overheadBlend = 0.0;
  bool get overhead => _overhead;
  double get overheadBlend => _overheadBlend;

  // Bubble offset, normalised to [-1, 1] per axis (1 = ring edge), plus its
  // own eased level verdict.
  double _bubbleX = 0, _bubbleY = 0;
  double get bubbleX => _bubbleX;
  double get bubbleY => _bubbleY;

  /// How far the phone's plane is off horizontal, in degrees. Only meaningful
  /// in overhead mode.
  double _bubbleOffDeg = 0;
  double get bubbleOffDeg => _bubbleOffDeg;

  /// Seconds-constant for the painter's exponential fade, picked per direction
  /// so fade-in and fade-out can differ. Reaching the 0.02 cutoff takes about
  /// 4x tau, so tau = ms / 4000.
  double fadeTauSeconds(bool fadingIn) =>
      (fadingIn ? config.fadeInMs : config.fadeOutMs) / 4000.0;

  /// Reset to hidden — used when the machine is re-seeded (mode change, resume).
  void reset() {
    _state = LevelLineState.idle;
    _pending = null;
    _stationarySinceMs = 0;
    _leveledAtMs = 0;
    _lastAngleMs = 0;
    _angVelDegPerSec = 0;
    _justLeveled = false;
    // Deliberately NOT clearing _overhead/_overheadBlend: a re-seed (hold
    // change) shouldn't make the instrument pop between forms mid-morph.
  }

  /// Advance the machine.
  ///
  /// [tiltDeg]  — signed tilt off level, in degrees (0 = level).
  /// [nowMs]    — wall-clock milliseconds.
  /// [pitchDeg] — physical pitch from vertical (90 = phone flat). Drives the
  ///              switch to bubble mode.
  /// [gx],[gy]  — in-plane gravity components, for the bubble's offset. Pass
  ///              the same smoothed vector the rest of the pipeline uses.
  /// [dtSec]    — elapsed seconds since the last update, for frame-rate
  ///              independent easing of the morph.
  void update({
    required double tiltDeg,
    required int nowMs,
    double pitchDeg = 0,
    double gx = 0,
    double gy = 0,
    double gz = 0,
    double dtSec = 1 / 50,
  }) {
    _justLeveled = false;
    _updateOverhead(pitchDeg: pitchDeg, gx: gx, gy: gy, gz: gz, dtSec: dtSec);

    // ── 1. Angular velocity, from the change in angle over real elapsed time ──
    if (_lastAngleMs != 0) {
      final double dtSec = (nowMs - _lastAngleMs) / 1000.0;
      if (dtSec > 0.0005) {
        final double deltaDeg = (tiltDeg - _lastAngleDeg).abs();
        // A jump this large in one tick is not a hand movement — it's the
        // measurement frame changing under us (an orientation flip, a re-seed,
        // a dropped stream). Treating it as motion would spike the velocity and
        // summon the line; worse, if the jump sweeps through level it reads as
        // a genuine correction. Re-seed from the new angle and skip this tick.
        if (deltaDeg > _kDiscontinuityDeg && !_overhead) {
          _lastAngleMs = nowMs;
          _lastAngleDeg = tiltDeg;
          _angVelDegPerSec = 0;
          _stationarySinceMs = 0;
          return;
        }
        final double raw = deltaDeg / dtSec;
        // Low-pass: sensor noise alone can read as several deg/sec.
        const double a = 0.25;
        _angVelDegPerSec += (raw - _angVelDegPerSec) * a;
        _lastAngleMs = nowMs;
        _lastAngleDeg = tiltDeg;
      }
    } else {
      _lastAngleMs = nowMs;
      _lastAngleDeg = tiltDeg;
      // First reading of a fresh machine: nothing to compare against, so don't
      // let an arbitrary starting angle look like motion.
      return;
    }

    if (alwaysShow) {
      // Bypass: the line is pinned on, but keep the level verdict live so it
      // still turns green and still confirms.
      final bool lvl = _overhead
          ? _bubbleOffDeg <= config.bubbleToleranceDeg
          : tiltDeg.abs() <= config.levelToleranceDeg;
      if (lvl && _state != LevelLineState.leveled) {
        _justLeveled = true;
        _state = LevelLineState.leveled;
      } else if (!lvl && _state == LevelLineState.leveled) {
        _state = LevelLineState.active;
      } else if (_state == LevelLineState.idle) {
        _state = LevelLineState.active;
      }
      return;
    }

    // In overhead mode "level" means the phone's plane is flat, measured by the
    // bubble — roll is meaningless there. Correction range is generous: pointed
    // this steeply you're clearly committed to an overhead shot.
    final double absTilt = _overhead ? _bubbleOffDeg : tiltDeg.abs();
    final bool inRange = _overhead
        ? _bubbleOffDeg <= config.bubbleRangeDeg * 1.6
        : absTilt <= config.correctionRangeDeg;
    final bool isLevel = _overhead
        ? _bubbleOffDeg <= config.bubbleToleranceDeg
        : absTilt <= config.levelToleranceDeg;
    final bool moving =
        _angVelDegPerSec > config.stationaryThresholdDegPerSec;

    // ── 2. Track how long we've been stationary ──
    if (moving) {
      _stationarySinceMs = 0;
    } else if (_stationarySinceMs == 0) {
      _stationarySinceMs = nowMs;
    }

    // ── 3. Work out where we WANT to be ──
    LevelLineState want = _state;

    switch (_state) {
      case LevelLineState.leveled:
        // Hold the confirmation briefly, then go quiet. Moving off level
        // during the hold puts us straight back to correcting.
        if (!isLevel && moving && inRange) {
          want = LevelLineState.active;
        } else if (_leveledAtMs != 0 &&
            nowMs - _leveledAtMs >= config.levelHoldMs) {
          want = LevelLineState.idle;
        }

      case LevelLineState.active:
        if (isLevel) {
          want = LevelLineState.leveled;
        } else if (!inRange) {
          // Swung out to a deliberate angle — stop nagging.
          want = LevelLineState.idle;
        } else if (!moving &&
            _stationarySinceMs != 0 &&
            nowMs - _stationarySinceMs >= config.settleDurationMs) {
          // Held still, off level: the tilt is intentional.
          want = LevelLineState.idle;
        }

      case LevelLineState.idle:
        // Only wake for active adjustment within correction range. A phone
        // sitting still — however crooked — is left alone.
        if (inRange && moving && !isLevel) {
          want = LevelLineState.active;
        }
    }

    // ── 4. Debounce every transition ──
    // Leaving `leveled` on its own hold timer is already time-gated, and the
    // level confirmation itself should feel instant, so those bypass the wait.
    if (want == _state) {
      _pending = null;
      _applyImmediate(want, nowMs);
      return;
    }

    final bool skipDebounce =
        want == LevelLineState.leveled ||
        (_state == LevelLineState.leveled && want == LevelLineState.idle);

    if (skipDebounce) {
      _pending = null;
      _transition(want, nowMs);
      return;
    }

    if (_pending != want) {
      _pending = want;
      _pendingSinceMs = nowMs;
      return;
    }
    if (nowMs - _pendingSinceMs >= config.debounceMs) {
      _pending = null;
      _transition(want, nowMs);
    }
  }

  /// Latch overhead mode (with hysteresis) and derive the bubble's position.
  ///
  /// Near flat, gravity lies almost entirely on z, and the in-plane components
  /// (gx, gy) ARE the tilt — small, well-conditioned, and directly usable as
  /// the bubble's offset. That's precisely the region where the horizon line's
  /// roll becomes unstable, which is why the instruments swap here.
  void _updateOverhead({
    required double pitchDeg,
    required double gx,
    required double gy,
    required double gz,
    required double dtSec,
  }) {
    final double p = pitchDeg.abs();
    if (_overhead) {
      if (p < config.overheadExitDeg) _overhead = false;
    } else {
      if (p > config.overheadEnterDeg) _overhead = true;
    }

    // Ease the morph on wall-clock time so it's smooth at any sensor rate.
    final double target = _overhead ? 1.0 : 0.0;
    const double tau = 0.16;
    _overheadBlend += (target - _overheadBlend) * (1 - math.exp(-dtSec / tau));
    if ((target - _overheadBlend).abs() < 0.001) _overheadBlend = target;

    // Bubble offset: in-plane gravity, normalised so bubbleRangeDeg reaches the
    // ring's edge. g is ~9.81 at rest; using the magnitude keeps it correct
    // under mild acceleration.
    final double g = math.sqrt(gx * gx + gy * gy + gz * gz);
    if (g > 0.001) {
      final double limit = math.sin(config.bubbleRangeDeg * math.pi / 180) * g;
      if (limit > 0.0001) {
        // Screen-down flips the x sense, so the bubble always moves the way you
        // tip the phone rather than mirroring when you turn it over.
        final double sign = gz < 0 ? -1.0 : 1.0;
        _bubbleX = (gx / limit * sign).clamp(-1.6, 1.6);
        _bubbleY = (gy / limit).clamp(-1.6, 1.6);
      }
    }
    // True angle off horizontal, for the level verdict + any readout.
    final double inPlane = math.sqrt(gx * gx + gy * gy);
    _bubbleOffDeg = g > 0.001
        ? math.atan2(inPlane, gz.abs()) * 180 / math.pi
        : 0;
  }

  void _applyImmediate(LevelLineState s, int nowMs) {
    if (s == LevelLineState.leveled && _leveledAtMs == 0) {
      _leveledAtMs = nowMs;
    }
  }

  void _transition(LevelLineState next, int nowMs) {
    if (next == _state) return;
    if (next == LevelLineState.leveled) {
      _justLeveled = true;
      _leveledAtMs = nowMs;
    } else {
      _leveledAtMs = 0;
    }
    if (next == LevelLineState.active) {
      _stationarySinceMs = 0;
    }
    _state = next;
  }

  /// A single-tick angle change beyond this is treated as a discontinuity
  /// (frame change / dropped samples), not as movement.
  static const double _kDiscontinuityDeg = 25.0;

  /// Convenience for callers holding radians (the app's sensor pipeline does).
  static double radToDeg(double rad) => rad * 180.0 / math.pi;
}
