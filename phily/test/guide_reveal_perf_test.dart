// The guide's spiral reveal animates for ~1.1s at display rate, directly over
// a decoded JPEG and a gradient scrim. Without a RepaintBoundary the animated
// painter is a bare sibling in the Stack, so every one of its frames marks the
// photo's layer dirty too — the same defect pass #17 fixed in the gallery.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Counts real paints of the "photo" beneath the animated overlay.
class _CountingPhoto extends CustomPainter {
  _CountingPhoto(this.tally);
  final List<int> tally;
  @override
  void paint(Canvas canvas, Size size) {
    tally.add(1);
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = const Color(0xFF223344),
    );
  }

  @override
  bool shouldRepaint(_CountingPhoto old) => false;
}

/// Stands in for the spiral: repaints on every tick.
class _Overlay extends CustomPainter {
  _Overlay(this.t) : super(repaint: const AlwaysStoppedAnimation(0));
  final double t;
  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawCircle(
      size.center(Offset.zero),
      10 + 40 * t,
      Paint()
        ..color = const Color(0xFFFFFFFF)
        ..style = PaintingStyle.stroke,
    );
  }

  @override
  bool shouldRepaint(_Overlay old) => old.t != t;
}

Future<int> runReveal(WidgetTester tester, {required bool boundaried}) async {
  final tally = <int>[];
  final ctrl = AnimationController(
    vsync: tester,
    duration: const Duration(milliseconds: 300),
  );
  addTearDown(() {
    ctrl.stop();
    ctrl.dispose();
  });

  final overlay = AnimatedBuilder(
    animation: ctrl,
    builder: (_, _) => CustomPaint(painter: _Overlay(ctrl.value)),
  );

  await tester.pumpWidget(
    Directionality(
      textDirection: TextDirection.ltr,
      child: Stack(
        fit: StackFit.expand,
        children: [
          CustomPaint(painter: _CountingPhoto(tally)),
          boundaried ? RepaintBoundary(child: overlay) : overlay,
        ],
      ),
    ),
  );

  final int baseline = tally.length;
  ctrl.forward();
  for (var i = 0; i < 15; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
  ctrl.stop();
  return tally.length - baseline;
}

void main() {
  testWidgets('a boundaried reveal never repaints the photo beneath it', (
    tester,
  ) async {
    expect(await runReveal(tester, boundaried: true), 0);
  });

  testWidgets('without the boundary the photo repaints every frame (the bug)', (
    tester,
  ) async {
    // Control: proves the test above is not vacuous.
    expect(await runReveal(tester, boundaried: false), greaterThan(5));
  });
}
