// The level dial shows a horizon line, or — with the phone near flat — a
// bubble level. It used to MORPH between them, bowing the bar into a ring
// over ~0.16s; every frame of that was a squashed, eye-shaped ellipse, which
// Lucas saw on every switch. Now it's one or the other, swapped instantly.
//
// The dial also takes an early `return` (fully hidden) from inside a
// saveLayer. CLAUDE.md: an unbalanced save/restore "silently corrupts
// everything drawn afterward and neither the analyzer nor the tests will
// catch it" — so that balance is asserted here across every state.
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phily/camera_page.dart';

int netSaveDepth({
  required double overhead,
  required double visible,
  double roll = 0,
  double vert = 0,
  double tone = 0,
  double bubbleX = 0,
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
    tone: tone,
    bubbleX: bubbleX,
  );
  final after = canvas.getSaveCount();
  recorder.endRecording().dispose();
  return after - before;
}

void main() {
  group('canvas balance', () {
    test('every instrument, visibility and tone stays balanced', () {
      for (final vis in [0.0, 0.01, 0.3, 0.9, 1.0]) {
        for (final ov in [0.0, 0.49, 0.5, 1.0]) {
          for (final tone in [0.0, 0.5, 1.0]) {
            expect(
              netSaveDepth(overhead: ov, visible: vis, tone: tone),
              0,
              reason:
                  'overhead=$ov visible=$vis tone=$tone left the canvas '
                  'unbalanced — this silently corrupts everything drawn '
                  'afterwards',
            );
          }
        }
      }
    });

    test('painting any state never throws', () {
      for (final ov in [0.0, 1.0]) {
        for (final tone in [0.0, 1.0]) {
          expect(
            () => netSaveDepth(
              overhead: ov,
              visible: 1.0,
              roll: 0.2,
              vert: 0.4,
              tone: tone,
              bubbleX: 1.4,
            ),
            returnsNormally,
            reason: 'overhead=$ov tone=$tone',
          );
        }
      }
    });
  });
}
