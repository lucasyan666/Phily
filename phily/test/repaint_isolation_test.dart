// Overlay chrome that repaints every frame must not share a layer with the
// thing it floats over. The gallery's fast-scroll thumb tracks the scroll
// offset at display rate, and the pull-to-dismiss dim follows the finger and
// its spring-back; both are siblings of the scrolling grid in one Stack, so
// without a RepaintBoundary each of their frames marks the grid dirty too.
//
// This is a behavioural test of that guarantee, not a check that the widget is
// present: it counts actual painting of a sibling while a notifier-driven
// overlay animates.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Counts how many times it is actually painted.
class _CountingPainter extends CustomPainter {
  _CountingPainter(this.tally);
  final List<int> tally;

  @override
  void paint(Canvas canvas, Size size) {
    tally.add(1);
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = const Color(0xFF111111),
    );
  }

  @override
  bool shouldRepaint(_CountingPainter old) => false;
}

Future<void> _pumpStack(
  WidgetTester tester, {
  required ValueNotifier<double> driver,
  required List<int> tally,
  required bool boundaried,
}) {
  final overlay = ValueListenableBuilder<double>(
    valueListenable: driver,
    builder: (_, v, _) => Align(
      alignment: Alignment(0, v),
      child: const SizedBox(width: 8, height: 40),
    ),
  );
  return tester.pumpWidget(
    Directionality(
      textDirection: TextDirection.ltr,
      child: Stack(
        children: [
          // Stands in for the grid: expensive, and never changes.
          Positioned.fill(child: CustomPaint(painter: _CountingPainter(tally))),
          Positioned.fill(
            child: boundaried ? RepaintBoundary(child: overlay) : overlay,
          ),
        ],
      ),
    ),
  );
}

void main() {
  testWidgets('a boundaried overlay does not repaint its sibling', (
    tester,
  ) async {
    final driver = ValueNotifier<double>(-1);
    addTearDown(driver.dispose);
    final tally = <int>[];

    await _pumpStack(tester, driver: driver, tally: tally, boundaried: true);
    final int afterFirstFrame = tally.length;

    // Drive the overlay the way a scrub or a pull does.
    for (var i = 1; i <= 12; i++) {
      driver.value = -1 + i / 6;
      await tester.pump();
    }

    expect(
      tally.length,
      afterFirstFrame,
      reason:
          'sibling repainted ${tally.length - afterFirstFrame}× '
          'while only the overlay moved',
    );
  });

  testWidgets('without the boundary the sibling does repaint (the bug)', (
    tester,
  ) async {
    // Guards the test itself: if this ever stops repainting, the test above
    // proves nothing and the boundaries could be silently removed.
    final driver = ValueNotifier<double>(-1);
    addTearDown(driver.dispose);
    final tally = <int>[];

    await _pumpStack(tester, driver: driver, tally: tally, boundaried: false);
    final int afterFirstFrame = tally.length;

    for (var i = 1; i <= 12; i++) {
      driver.value = -1 + i / 6;
      await tester.pump();
    }

    expect(tally.length, greaterThan(afterFirstFrame));
  });
}
