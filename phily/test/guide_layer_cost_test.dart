// The draw-on fade uses saveLayer, which allocates an offscreen buffer and
// composites it back — the most expensive thing a painter can do per frame.
//
// The composition overlay is painted over EVERY camera frame, and CLAUDE.md
// makes preview FPS a first-class concern, so the live viewfinder must never
// take that path. It always paints at reveal 1.0; these tests pin that down so
// a future edit cannot quietly put an offscreen layer over the preview.
import 'package:flutter_test/flutter_test.dart';
import 'package:phily/camera_page.dart';

void main() {
  test('the live viewfinder never allocates a fade layer, for any mode', () {
    for (final mode in CompositionMode.values) {
      expect(
        guideFadesIn(mode, 1.0),
        isFalse,
        reason: '$mode would allocate an offscreen layer on the live preview',
      );
    }
  });

  test('the guide sheet does fade, so the test above is not vacuous', () {
    // Every mode except the spiral, which traces itself instead.
    for (final mode in CompositionMode.values) {
      final expected = mode != CompositionMode.fibonacciSpiral;
      expect(guideFadesIn(mode, 0.5), expected, reason: '$mode mid-reveal');
    }
  });

  test('the spiral never fades — it traces from its eye instead', () {
    for (final t in [0.0, 0.25, 0.5, 0.9, 1.0]) {
      expect(guideFadesIn(CompositionMode.fibonacciSpiral, t), isFalse);
    }
  });

  test('the layer is released the instant the draw-on completes', () {
    // 0.999 is the settle threshold: at or past it, no layer.
    expect(guideFadesIn(CompositionMode.ruleOfThirds, 0.9989), isTrue);
    expect(guideFadesIn(CompositionMode.ruleOfThirds, 0.999), isFalse);
  });
}
