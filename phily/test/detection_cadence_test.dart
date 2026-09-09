// The adaptive detection cadence is the thing that makes an older iPhone
// usable: it measures how long each ML Kit / Vision pass takes and backs the
// frame gate off instead of queueing work the device can't finish. That
// behaviour only appears on hardware CI doesn't have, so the policy is pure
// Dart and tested here directly.
//
// CLAUDE.md: "Don't replace it with a fixed interval." These tests are what
// makes that instruction enforceable.
import 'package:flutter_test/flutter_test.dart';
import 'package:phily/detection_cadence.dart';

/// Run [passes] detections that each cost [costMs], returning the settled gate.
int settle(DetectionCadence c, {required int costMs, int passes = 400}) {
  for (var i = 0; i < passes; i++) {
    c.note(costMs);
  }
  return c.intervalMs;
}

void main() {
  group('a capable device', () {
    test('starts at the floor, so it behaves like the old fixed interval', () {
      expect(DetectionCadence().intervalMs, DetectionCadence.kFloorMs);
    });

    test('stays at the floor when passes are cheap', () {
      // A current Pro: a pass well inside the floor's duty cycle.
      expect(settle(DetectionCadence(), costMs: 12), DetectionCadence.kFloorMs);
    });

    test('never runs detection faster than the floor', () {
      expect(
        settle(DetectionCadence(), costMs: 1),
        greaterThanOrEqualTo(DetectionCadence.kFloorMs),
      );
    });
  });

  group('a slower device backs off', () {
    test('a mid-range pass settles above the floor', () {
      // ~55ms/pass: at the 60ms floor that is over the duty cycle, so the
      // gate must open up rather than queue work.
      final settled = settle(DetectionCadence(), costMs: 55);
      expect(settled, greaterThan(DetectionCadence.kFloorMs));
      expect(settled, lessThan(DetectionCadence.kCeilMs));
    });

    test('the gate tracks the duty cycle: ~2× the measured cost', () {
      for (final cost in [40, 55, 70, 90]) {
        final settled = settle(DetectionCadence(), costMs: cost);
        final want = (cost / DetectionCadence.kDutyCycle).round().clamp(
          DetectionCadence.kFloorMs,
          DetectionCadence.kCeilMs,
        );
        expect(
          settled,
          closeTo(want, 2),
          reason: '${cost}ms passes should settle near ${want}ms',
        );
      }
    });

    test('a very slow device is capped, never worse than the ceiling', () {
      expect(settle(DetectionCadence(), costMs: 500), DetectionCadence.kCeilMs);
    });
  });

  group('stability', () {
    test('one slow frame barely moves the cadence', () {
      final c = DetectionCadence();
      settle(c, costMs: 12);
      final before = c.intervalMs;
      c.note(400); // a GC pause or thermal blip
      expect(
        c.intervalMs - before,
        lessThanOrEqualTo(DetectionCadence.kMaxStepMs),
        reason: 'a single outlier must not jump the cadence',
      );
    });

    test('it recovers when the device speeds up again', () {
      final c = DetectionCadence();
      final slow = settle(c, costMs: 120);
      expect(slow, greaterThan(DetectionCadence.kFloorMs));
      // Thermals ease, or the scene simplifies.
      expect(settle(c, costMs: 10), DetectionCadence.kFloorMs);
    });

    test('the cadence eases, never jumping between passes', () {
      final c = DetectionCadence();
      settle(c, costMs: 10);
      var previous = c.intervalMs;
      for (var i = 0; i < 200; i++) {
        c.note(300); // sudden sustained load
        expect(
          (c.intervalMs - previous).abs(),
          lessThanOrEqualTo(DetectionCadence.kMaxStepMs),
          reason: 'jumped from $previous to ${c.intervalMs}',
        );
        previous = c.intervalMs;
      }
    });

    test('a zero or negative reading is ignored, not treated as free', () {
      final c = DetectionCadence();
      settle(c, costMs: 120);
      final before = c.intervalMs;
      c.note(0);
      c.note(-5);
      expect(c.intervalMs, before);
    });
  });
}
