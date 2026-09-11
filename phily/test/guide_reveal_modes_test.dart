// Every guide mode's diagram now draws on as the card settles: the Fibonacci
// Spiral traces itself from the eye outward (one continuous line, so it can),
// and the other fifteen fade up together — straight-line grids have no
// natural start point, and inventing a stroke order would imply a reading
// direction the composition does not have.
//
// CLAUDE.md: "When editing overlay painters, keep canvas.save/restore
// balanced — an imbalance silently corrupts everything drawn afterward and
// neither the analyzer nor the tests will catch it." The reveal adds a
// conditional saveLayer, so that balance is exactly what these tests check.
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phily/camera_page.dart';

/// Paints [mode] at [reveal] and returns the canvas' net save depth.
/// A non-zero result means an unbalanced save/saveLayer.
int netSaveDepth(CompositionMode mode, double reveal) {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  final before = canvas.getSaveCount();
  debugPaintComposition(canvas, const Size(390, 520), mode, reveal);
  final after = canvas.getSaveCount();
  recorder.endRecording().dispose();
  return after - before;
}

void main() {
  group('draw-on reveal', () {
    test('every mode stays save/restore balanced at every reveal value', () {
      for (final mode in CompositionMode.values) {
        for (final t in [0.0, 0.01, 0.3, 0.5, 0.75, 0.999, 1.0]) {
          expect(
            netSaveDepth(mode, t),
            0,
            reason:
                '$mode at reveal=$t left the canvas unbalanced — this '
                'silently corrupts everything drawn afterwards',
          );
        }
      }
    });

    test('painting mid-reveal never throws, for any mode', () {
      for (final mode in CompositionMode.values) {
        for (final t in [0.0, 0.25, 0.6, 1.0]) {
          expect(() => netSaveDepth(mode, t), returnsNormally, reason: '$mode');
        }
      }
    });
  });
}
