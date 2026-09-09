// The composition belt animates every frame while it scrolls, and the pill's
// label is identical on all of them. AnimatedBuilder's `child` exists to hoist
// exactly that: the label is built once and passed through, so a scroll frame
// re-runs only the gilding, not text shaping for every visible pill.
//
// This is a structural test of that pattern (the camera page itself is plugin-
// and timer-driven and can't be pumped): it counts how many times the child
// subtree is built while the driving animation runs.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Counts its own builds, standing in for the pill's Text.
class _CountingLabel extends StatelessWidget {
  static int builds = 0;
  const _CountingLabel();

  @override
  Widget build(BuildContext context) {
    builds++;
    return const SizedBox(width: 40, height: 12);
  }
}

void main() {
  testWidgets('a hoisted child is built once, not once per frame', (
    tester,
  ) async {
    _CountingLabel.builds = 0;
    final ctrl = AnimationController(
      vsync: tester,
      duration: const Duration(milliseconds: 300),
    );
    addTearDown(() {
      ctrl.stop();
      ctrl.dispose();
    });

    var builderRuns = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: AnimatedBuilder(
          animation: ctrl,
          child: const _CountingLabel(),
          builder: (context, child) {
            builderRuns++;
            // The per-frame part: opacity stands in for the gilding.
            return Opacity(opacity: 0.2 + 0.8 * ctrl.value, child: child);
          },
        ),
      ),
    );

    ctrl.forward();
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 30));
    }

    // The animation really did drive many frames...
    expect(builderRuns, greaterThan(5));
    ctrl.stop();
    // ...and the label was shaped once regardless.
    expect(
      _CountingLabel.builds,
      1,
      reason: 'label rebuilt $builderRuns× — the child hoist is not working',
    );
  });
}
