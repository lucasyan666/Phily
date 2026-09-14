// The composition guide overlay is the most expensive layer on the camera
// screen, isolated in its own RepaintBoundary so gravity ticks never touch it.
// That isolation is only as good as shouldRepaint: the page builds a fresh
// glow-segment list every time, and comparing it by identity meant every
// setState (a pinch, a belt scroll, a chrome toggle) re-rasterised the whole
// overlay. This locks "unchanged state → no repaint" for every mode.
import 'package:flutter_test/flutter_test.dart';
import 'package:phily/camera_page.dart';

void main() {
  test('a rebuild with unchanged guide state never repaints the overlay', () {
    for (final mode in CompositionMode.values) {
      expect(
        debugCompositionPainterRepaints(mode, mode),
        isFalse,
        reason: '$mode repaints on a no-op rebuild',
      );
    }
  });

  test('a mode change still repaints', () {
    expect(
      debugCompositionPainterRepaints(
        CompositionMode.ruleOfThirds,
        CompositionMode.goldenSection,
      ),
      isTrue,
    );
  });
}
