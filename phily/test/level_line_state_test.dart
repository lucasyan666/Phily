import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:phily/level_line_state.dart';

/// Drive the machine at a fixed tick rate, holding a given tilt.
/// Returns the machine so state can be asserted.
/// Returns true if [justLeveled] fired on ANY tick of this sweep — the flag is
/// only true for the single tick of the transition, so it has to be caught
/// during the loop, not after it.
bool run(
  LevelLineMachine m, {
  required double fromDeg,
  required double toDeg,
  required int durationMs,
  int tickMs = 20,
  required int startMs,
}) {
  final steps = (durationMs / tickMs).round().clamp(1, 100000);
  bool sawLevelPing = false;
  for (int i = 1; i <= steps; i++) {
    final t = i / steps;
    m.update(
      tiltDeg: fromDeg + (toDeg - fromDeg) * t,
      nowMs: startMs + i * tickMs,
    );
    if (m.justLeveled) sawLevelPing = true;
  }
  return sawLevelPing;
}

void main() {
  group('adaptive level line', () {
    test('starts hidden', () {
      final m = LevelLineMachine();
      expect(m.state, LevelLineState.idle);
      expect(m.opacityTarget, 0.0);
    });

    test('a still, crooked phone is left alone', () {
      final m = LevelLineMachine();
      // Held dead still at 10° for 2s — never moving, so never summoned.
      run(m, fromDeg: 10, toDeg: 10, durationMs: 2000, startMs: 1000);
      expect(m.state, LevelLineState.idle);
      expect(m.opacityTarget, 0.0);
    });

    test('appears while actively levelling within correction range', () {
      final m = LevelLineMachine();
      // Sweep 12° → 6° over 400ms ≈ 15°/s: clearly moving, inside range.
      run(m, fromDeg: 12, toDeg: 6, durationMs: 400, startMs: 1000);
      expect(m.state, LevelLineState.active);
      expect(m.opacityTarget, 1.0);
    });

    test('never appears beyond correction range, even while moving', () {
      final m = LevelLineMachine();
      // A fast pan way off level (45° → 35°).
      run(m, fromDeg: 45, toDeg: 35, durationMs: 400, startMs: 1000);
      expect(m.state, LevelLineState.idle);
      expect(m.opacityTarget, 0.0);
    });

    test('confirms level, fires one haptic, then hides after the hold', () {
      final m = LevelLineMachine();
      run(m, fromDeg: 12, toDeg: 6, durationMs: 400, startMs: 1000);
      expect(m.state, LevelLineState.active);

      // Bring it to level — the haptic fires once, during this sweep.
      final bool pinged =
          run(m, fromDeg: 6, toDeg: 0.5, durationMs: 200, startMs: 1400);
      expect(pinged, isTrue, reason: 'haptic fires on the level transition');
      expect(m.state, LevelLineState.leveled);
      expect(m.snapToCentre, isTrue);
      expect(m.levelTone, 1.0);

      // Hold level: after levelHoldMs it goes away, and never re-fires.
      final bool pingedAgain =
          run(m, fromDeg: 0.5, toDeg: 0.5, durationMs: 600, startMs: 1600);
      expect(pingedAgain, isFalse, reason: 'exactly one ping per correction');
      expect(m.state, LevelLineState.idle);
      expect(m.opacityTarget, 0.0);
    });

    test('hides when the user settles on a deliberate off-level angle', () {
      final m = LevelLineMachine();
      run(m, fromDeg: 12, toDeg: 8, durationMs: 400, startMs: 1000);
      expect(m.state, LevelLineState.active);

      // Now hold 8° perfectly still — past SETTLE_DURATION it gives up.
      run(m, fromDeg: 8, toDeg: 8, durationMs: 1200, startMs: 1400);
      expect(m.state, LevelLineState.idle,
          reason: 'deliberate tilt should not be nagged');
    });

    test('re-appears when adjustment resumes after settling', () {
      final m = LevelLineMachine();
      run(m, fromDeg: 12, toDeg: 8, durationMs: 400, startMs: 1000);
      run(m, fromDeg: 8, toDeg: 8, durationMs: 1200, startMs: 1400);
      expect(m.state, LevelLineState.idle);

      // Pick the phone back up and start adjusting again.
      run(m, fromDeg: 8, toDeg: 3, durationMs: 400, startMs: 2600);
      expect(m.state, LevelLineState.active);
      expect(m.opacityTarget, 1.0);
    });

    test('debounce stops flicker at the range boundary', () {
      final m = LevelLineMachine();
      run(m, fromDeg: 12, toDeg: 6, durationMs: 400, startMs: 1000);
      expect(m.state, LevelLineState.active);

      // A single 20ms blip just outside range must not drop it out.
      m.update(tiltDeg: 21, nowMs: 1420);
      expect(m.state, LevelLineState.active,
          reason: 'one tick past the edge is not a state change');
    });

    test('"always show" bypasses the machine but keeps the level verdict', () {
      final m = LevelLineMachine(alwaysShow: true);
      // Dead still and crooked — normally hidden; here it stays up.
      run(m, fromDeg: 10, toDeg: 10, durationMs: 2000, startMs: 1000);
      expect(m.opacityTarget, 1.0);

      // Still turns green on level.
      run(m, fromDeg: 10, toDeg: 0.2, durationMs: 300, startMs: 3000);
      expect(m.levelTone, 1.0);
      expect(m.opacityTarget, 1.0, reason: 'never hides while pinned on');
    });

    test('an orientation flip must not fire a spurious level ping', () {
      // Reproduces the reported bug: relative roll jumps ~90 degrees in one
      // tick when the hold changes, sweeping through 0 on the way. That must
      // not read as reaching level.
      final m = LevelLineMachine();
      run(m, fromDeg: 12, toDeg: 8, durationMs: 400, startMs: 1000);
      expect(m.state, LevelLineState.active);

      // One tick, huge jump straight through level to the other side.
      m.update(tiltDeg: -82, nowMs: 1420);
      expect(m.justLeveled, isFalse,
          reason: 'a frame change is not a correction');
      expect(m.state, isNot(LevelLineState.leveled));
    });

    test('a jump through level does not confirm level', () {
      final m = LevelLineMachine();
      run(m, fromDeg: 15, toDeg: 10, durationMs: 400, startMs: 1000);
      // Teleport across zero in a single tick.
      m.update(tiltDeg: -40, nowMs: 1420);
      expect(m.justLeveled, isFalse);
    });

    test('the very first reading never counts as motion', () {
      final m = LevelLineMachine();
      // A fresh machine handed an arbitrary angle must stay idle.
      m.update(tiltDeg: 14, nowMs: 5000);
      expect(m.state, LevelLineState.idle);
      expect(m.angularVelocityDegPerSec, 0);
    });

    test('constants are tunable', () {
      final m = LevelLineMachine(
        config: const LevelLineConfig(correctionRangeDeg: 5),
      );
      // 12° is outside a 5° correction range → never summoned.
      run(m, fromDeg: 12, toDeg: 8, durationMs: 400, startMs: 1000);
      expect(m.state, LevelLineState.idle);
    });
  });

  _overheadTests();
}

void _overheadTests() {
  group('overhead / bubble mode', () {
    // Gravity for a phone pitched `pitch` degrees from vertical, tipped
    // `offX`/`offY` degrees off flat once overhead.
    ({double gx, double gy, double gz}) grav(
      double pitchDeg, {
      double offXDeg = 0,
      double offYDeg = 0,
    }) {
      const g = 9.81;
      final p = pitchDeg * 3.141592653589793 / 180;
      // Near-flat: z dominates, in-plane components are the tip off level.
      final gz = g * math.sin(p);
      final gx = g * math.sin(offXDeg * 3.141592653589793 / 180);
      final gy = g * math.cos(p) + g * math.sin(offYDeg * 3.141592653589793 / 180);
      return (gx: gx, gy: gy, gz: gz);
    }

    test('stays in line mode when upright', () {
      final m = LevelLineMachine();
      final v = grav(10);
      m.update(tiltDeg: 5, nowMs: 1000, pitchDeg: 10, gx: v.gx, gy: v.gy, gz: v.gz);
      expect(m.overhead, isFalse);
    });

    test('switches to bubble past the enter threshold', () {
      final m = LevelLineMachine();
      final v = grav(80);
      for (int i = 1; i <= 20; i++) {
        m.update(tiltDeg: 0, nowMs: 1000 + i * 20, pitchDeg: 80,
            gx: v.gx, gy: v.gy, gz: v.gz);
      }
      expect(m.overhead, isTrue);
      expect(m.overheadBlend, greaterThan(0.5), reason: 'morph is progressing');
    });

    test('hysteresis stops flapping at the boundary', () {
      final m = LevelLineMachine();
      final hi = grav(80);
      for (int i = 1; i <= 20; i++) {
        m.update(tiltDeg: 0, nowMs: 1000 + i * 20, pitchDeg: 80,
            gx: hi.gx, gy: hi.gy, gz: hi.gz);
      }
      expect(m.overhead, isTrue);
      // Drop to 50deg — below enter (54) but above exit (46): must NOT switch.
      final mid = grav(50);
      m.update(tiltDeg: 0, nowMs: 1500, pitchDeg: 50,
          gx: mid.gx, gy: mid.gy, gz: mid.gz);
      expect(m.overhead, isTrue, reason: 'inside the hysteresis band');
      // Below exit — now it returns.
      final lo = grav(40);
      m.update(tiltDeg: 0, nowMs: 1520, pitchDeg: 40,
          gx: lo.gx, gy: lo.gy, gz: lo.gz);
      expect(m.overhead, isFalse);
    });

    test('the morph is continuous, never a jump', () {
      final m = LevelLineMachine();
      final v = grav(80);
      double prev = m.overheadBlend;
      double maxStep = 0;
      for (int i = 1; i <= 40; i++) {
        m.update(tiltDeg: 0, nowMs: 1000 + i * 20, pitchDeg: 80,
            gx: v.gx, gy: v.gy, gz: v.gz, dtSec: 0.02);
        maxStep = math.max(maxStep, (m.overheadBlend - prev).abs());
        prev = m.overheadBlend;
      }
      expect(maxStep, lessThan(0.2),
          reason: 'eased morph should never step visibly');
    });

    test('no dead zone: bubble engages before the line gives up', () {
      // The line hides past correctionRange/pitchScale of pitch; the bubble
      // must be in play by then, or there's a band showing nothing at all.
      const cfg = LevelLineConfig();
      final lineCutoff = cfg.correctionRangeDeg / cfg.pitchScale;
      expect(cfg.overheadEnterDeg, lessThanOrEqualTo(lineCutoff),
          reason: 'bubble must engage at or before the line cutoff');
    });

    test('bubble centres when flat and confirms level', () {
      final m = LevelLineMachine();
      final v = grav(90); // dead flat
      for (int i = 1; i <= 30; i++) {
        m.update(tiltDeg: 0, nowMs: 1000 + i * 20, pitchDeg: 90,
            gx: v.gx, gy: v.gy, gz: v.gz);
      }
      expect(m.overhead, isTrue);
      expect(m.bubbleOffDeg, lessThan(1.5));
      expect(m.bubbleX.abs(), lessThan(0.2));
    });
  });
}
