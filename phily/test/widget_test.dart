// Deterministic tests that don't depend on the camera/sensor platform channels.
// The camera screen is plugin- and timer-driven (sensor streams, delayed
// thumbnail loads, repeating tickers), so it can't be mounted in a plain widget
// test without mocking every channel — out of scope here. Instead we lock the
// shared brand constant and smoke-test real rendering code.
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:phily/screens/branded_loader.dart';
import 'package:phily/theme.dart';

void main() {
  test('brand gold constant matches the design value', () {
    expect(kGold, const Color(0xFFE5C158));
  });

  test('FibonacciSpiralPainter paints without throwing', () {
    final recorder = PictureRecorder();
    final canvas = Canvas(recorder);
    const FibonacciSpiralPainter(
      color: kGold,
    ).paint(canvas, const Size(240, 240));
    recorder.endRecording().dispose();
  });
}
