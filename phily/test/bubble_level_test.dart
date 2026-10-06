// The bubble level is the ONLY instrument for a flat, birds-eye shot — the
// horizon line has nothing to grip when the phone is face-down, so above
// ~54° of pitch the state machine hands over to the bubble.
//
// Its design is two rings of the same size: one fixed at centre, one that
// drifts with the tilt. Level is when they become one. That makes the
// proportions functional, not decorative, and these tests hold them.
import 'package:flutter_test/flutter_test.dart';
import 'package:phily/camera_page.dart';

void main() {
  group('bubble level geometry', () {
    test('the bubble and the centre ring are the same size', () {
      final g = debugBubbleGeometry();
      expect(
        g.bubbleR,
        g.referenceR,
        reason:
            'level is when the two coincide exactly — rings of different '
            'sizes would never read as one',
      );
    });

    test('a clearly tilted phone shows two separate rings', () {
      final g = debugBubbleGeometry();
      expect(
        g.travel,
        greaterThan(g.bubbleR * 2),
        reason: 'at full range the bubble must clear the centre ring entirely',
      );
    });

    test('the centre ring is drawn to be found, not hinted at', () {
      final g = debugBubbleGeometry();
      // Over a live camera scene, a hairline below ~0.4 alpha disappears
      // against anything bright.
      expect(g.referenceAlpha, greaterThanOrEqualTo(0.45));
      expect(
        g.referenceStroke,
        greaterThanOrEqualTo(0.8),
        reason: 'sub-pixel strokes vanish on a busy scene',
      );
    });
  });

  group('bubble position', () {
    final travel = debugBubbleGeometry().travel;

    test('follows the tilt, up to its travel', () {
      expect(debugBubbleOffset(1, 0, 0), Offset(travel, 0));
      expect(debugBubbleOffset(0, -0.5, 0), Offset(0, -travel / 2));
      // The machine reports up to ±1.6; past the edge it stops, not flies off.
      expect(debugBubbleOffset(1.6, 1.6, 0), Offset(travel, travel));
    });

    test('glides home as it turns level, then sits dead centre', () {
      final half = debugBubbleOffset(1, 0, 0.5);
      expect(half.dx, closeTo(travel / 2, 0.001));
      expect(
        debugBubbleOffset(1, 1, 1),
        Offset.zero,
        reason: 'once level the two rings must coincide exactly',
      );
    });
  });
}
