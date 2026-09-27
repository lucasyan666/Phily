// The level dial morphs a straight horizon bar into a circular bubble level as
// the phone tips toward flat. Two defects Lucas hit in the running app:
//
//  1. At full morph the shape was a LENS — two quadratic Béziers bowed toward
//     each other, 3.2x wider than tall — which then snapped to a true circle
//     at ov >= 0.999. Tilting quickly to face the ground makes the frames
//     where it is still easing visible: a "squashed, eye-shaped ball".
//  2. The bubble appeared at a hard `ov > 0.02` cutoff, so it popped in
//     against the dial's otherwise smooth fade.
//
// The dial also takes early `return`s (fully hidden, bubble not yet faded in)
// from inside a saveLayer. CLAUDE.md: an unbalanced save/restore "silently
// corrupts everything drawn afterward and neither the analyzer nor the tests
// will catch it" — so that balance is asserted here across the whole morph.
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phily/camera_page.dart';

int netSaveDepth({
  required double overhead,
  required double visible,
  double roll = 0,
  double vert = 0,
}) {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  final before = canvas.getSaveCount();
  debugPaintLevelDial(
    canvas,
    const Size(390, 600),
    roll: roll,
    vert: vert,
    overhead: overhead,
    visible: visible,
  );
  final after = canvas.getSaveCount();
  recorder.endRecording().dispose();
  return after - before;
}

void main() {
  group('morph geometry', () {
    // Read from the PAINTER's own geometry (debugLevelRingExtent →
    // levelRingGeometry, the same call the paint path uses). Recomputing the
    // formula inside the test would pass even if the painter changed — the
    // vacuous-test trap from pass #35.

    test('the shape arrives as a circle, not a 3.2:1 lens', () {
      final e = debugLevelRingExtent(1.0);
      expect(
        e.width / e.height,
        closeTo(1.0, 0.02),
        reason:
            'at full morph the bubble level must be round, but the '
            'painter builds ${e.width.toStringAsFixed(0)}x'
            '${e.height.toStringAsFixed(0)}',
      );
    });

    test('it converges monotonically — no snap at the end', () {
      double previous = double.infinity;
      for (var ov = 0.2; ov <= 1.0001; ov += 0.05) {
        final e = debugLevelRingExtent(ov);
        final ratio = e.width / e.height;
        expect(
          ratio,
          lessThan(previous),
          reason: 'w:h should keep tightening toward 1.0 (ov=$ov gave $ratio)',
        );
        previous = ratio;
      }
      // The old code sat at 3.23:1 right up to the snap at 0.999.
      expect(
        debugLevelRingExtent(0.99).width / debugLevelRingExtent(0.99).height,
        lessThan(1.05),
      );
    });
  });

  group('canvas balance', () {
    test('every morph and visibility combination stays balanced', () {
      for (final vis in [0.0, 0.01, 0.3, 0.9, 1.0]) {
        for (final ov in [0.0, 0.05, 0.08, 0.2, 0.5, 0.9, 0.999, 1.0]) {
          expect(
            netSaveDepth(overhead: ov, visible: vis),
            0,
            reason:
                'overhead=$ov visible=$vis left the canvas unbalanced — '
                'this silently corrupts everything drawn afterwards',
          );
        }
      }
    });

    test('painting mid-morph never throws', () {
      for (final ov in [0.0, 0.08, 0.35, 0.7, 1.0]) {
        expect(
          () => netSaveDepth(overhead: ov, visible: 1.0, roll: 0.2, vert: 0.4),
          returnsNormally,
          reason: 'overhead=$ov',
        );
      }
    });
  });
}
