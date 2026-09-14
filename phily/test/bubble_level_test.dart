// The bubble level is the ONLY instrument for a flat, birds-eye shot — the
// horizon line has nothing to grip when the phone is face-down, so above
// ~54° of pitch the state machine hands over to the bubble.
//
// That makes its proportions functional, not decorative: you have to be able
// to see the bead sitting inside its target, over a live scene, at a glance.
// The target used to be 4.6pt against a 3.4pt bead (1.35×) at 0.30 alpha —
// barely larger than the thing it contained. These tests keep it legible.
import 'package:flutter_test/flutter_test.dart';
import 'package:phily/camera_page.dart';

void main() {
  group('bubble level target', () {
    test('is comfortably larger than the bubble it must contain', () {
      final g = debugBubbleGeometry();
      expect(
        g.targetR / g.bubbleR,
        greaterThanOrEqualTo(2.0),
        reason:
            'a target the bead nearly fills reads as "covered", not '
            '"centred" — it was 1.35× and hard to judge',
      );
    });

    test('leaves a visible gap around the bubble at rest', () {
      final g = debugBubbleGeometry();
      // The bead blooms 30% when it lands, so check the gap at full bloom.
      final double litBubble = g.bubbleR * 1.30;
      expect(
        g.targetR - litBubble,
        greaterThan(2.0),
        reason: 'no daylight between bead and ring even when landed',
      );
    });

    test('is drawn to be found, not hinted at', () {
      final g = debugBubbleGeometry();
      // Over a live camera scene, a hairline below ~0.4 alpha disappears
      // against anything bright.
      expect(g.targetAlpha, greaterThanOrEqualTo(0.45));
      expect(
        g.targetStroke,
        greaterThanOrEqualTo(0.8),
        reason: 'sub-pixel strokes vanish on a busy scene',
      );
    });
  });
}
