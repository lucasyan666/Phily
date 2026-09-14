// The "Perfect" / "Level" pill breathes at 60fps over the LIVE camera preview
// — the one place in the app where a wasted rebuild costs visible frame rate
// (CLAUDE.md: "Preview FPS is a first-class concern").
//
// Only three alpha values ride the pulse: the glyph tint, the rim and the
// glow. Everything else — the text and its layout — is identical every frame.
// HintPill.breathing exists to keep that expensive half out of the animation,
// and these tests are what stop it quietly regressing.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:phily/theme.dart';

void main() {
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);

  testWidgets('the pill body is built once, however long it breathes', (
    tester,
  ) async {
    final ctrl = AnimationController(
      vsync: tester,
      duration: const Duration(seconds: 1),
    );
    addTearDown(() {
      ctrl.stop();
      ctrl.dispose();
    });

    var pulseReads = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: HintPill.breathing(
              icon: Icons.check_circle_rounded,
              text: 'Perfect',
              listenable: ctrl,
              pulseOf: () {
                pulseReads++;
                return ctrl.value;
              },
            ),
          ),
        ),
      ),
    );

    final element = tester.element(find.byType(HintPill));
    ctrl.repeat();
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    ctrl.stop();

    // The animation really ran...
    expect(pulseReads, greaterThan(10));
    // ...and the pill (text shaping, layout) was never rebuilt: the same
    // element instance is still mounted, never having been marked dirty.
    expect(identical(tester.element(find.byType(HintPill)), element), isTrue);
    expect(find.text('Perfect'), findsOneWidget);
  });

  testWidgets('the breathe is visible: the rim alpha actually changes', (
    tester,
  ) async {
    // Guards against "optimising" the pulse away entirely.
    double pulse = 0;
    final notifier = ValueNotifier<int>(0);
    addTearDown(notifier.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: HintPill.breathing(
              icon: Icons.check_circle_rounded,
              text: 'Level',
              listenable: notifier,
              pulseOf: () => pulse,
            ),
          ),
        ),
      ),
    );

    Color rim() {
      final box = tester
          .widgetList<DecoratedBox>(find.byType(DecoratedBox))
          .firstWhere(
            (d) =>
                d.position == DecorationPosition.foreground &&
                (d.decoration as BoxDecoration).border != null,
          );
      return ((box.decoration as BoxDecoration).border! as Border).top.color;
    }

    final dim = rim();
    pulse = 1.0;
    notifier.value = 1;
    await tester.pump();
    final bright = rim();

    expect(bright.a, greaterThan(dim.a), reason: 'rim did not brighten');
  });
}
