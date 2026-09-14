// Reduce Motion (iOS Settings → Accessibility → Motion) reaches Flutter as
// MediaQuery.disableAnimations. PopTap is the one tap microinteraction every
// glass control, chip and the guide dismiss sit on, so it is the assertion:
// the selection tick and the callback survive, the 114% bubble does not.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:phily/screens/branded_loader.dart';
import 'package:phily/theme.dart';

Future<void> _pumpPopTap(
  WidgetTester tester, {
  required bool reduceMotion,
  required VoidCallback onTap,
}) {
  return tester.pumpWidget(
    MediaQuery(
      data: MediaQueryData(disableAnimations: reduceMotion),
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: Center(
          child: PopTap(
            onTap: onTap,
            child: const SizedBox(width: 44, height: 44),
          ),
        ),
      ),
    ),
  );
}

double _scale(WidgetTester tester) =>
    tester.widget<ScaleTransition>(find.byType(ScaleTransition)).scale.value;

double _spiralAngle(WidgetTester tester) {
  final paint = tester
      .widgetList<CustomPaint>(find.byType(CustomPaint))
      .map((w) => w.painter)
      .whereType<FibonacciSpiralPainter>()
      .single;
  return paint.rotationAngle;
}

void main() {
  setUpAll(() {
    GoogleFonts.config.allowRuntimeFetching = false;
  });

  group('branded loader', () {
    testWidgets('the φ-spiral turns by default', (tester) async {
      await tester.pumpWidget(const MaterialApp(home: BrandedLoader()));
      await tester.pump(const Duration(milliseconds: 500));
      final a = _spiralAngle(tester);
      await tester.pump(const Duration(milliseconds: 500));
      expect(_spiralAngle(tester), isNot(a));
    });

    testWidgets('under Reduce Motion the mark holds still', (tester) async {
      await tester.pumpWidget(
        const MediaQuery(
          data: MediaQueryData(disableAnimations: true),
          child: MaterialApp(home: BrandedLoader()),
        ),
      );
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 500));
        expect(
          _spiralAngle(tester),
          0,
          reason: 'turned at ~${(i + 1) * 500}ms',
        );
      }
      // The entrance is instant too: fully opaque on the first settled frame.
      final opacity = tester.widget<Opacity>(find.byType(Opacity).first);
      expect(opacity.opacity, 1.0);
    });
  });

  group('PopTap', () {
    testWidgets('bubbles past 105% mid-tap and settles back by default', (
      tester,
    ) async {
      var taps = 0;
      await _pumpPopTap(tester, reduceMotion: false, onTap: () => taps++);
      await tester.tap(find.byType(PopTap));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 90));
      expect(_scale(tester), greaterThan(1.05));
      await tester.pumpAndSettle();
      expect(_scale(tester), 1.0);
      expect(taps, 1);
    });

    testWidgets('under Reduce Motion the tap fires but nothing moves', (
      tester,
    ) async {
      var taps = 0;
      await _pumpPopTap(tester, reduceMotion: true, onTap: () => taps++);
      await tester.tap(find.byType(PopTap));
      await tester.pump();
      for (var ms = 0; ms <= 300; ms += 30) {
        await tester.pump(const Duration(milliseconds: 30));
        expect(_scale(tester), 1.0, reason: 'moved at ~${ms}ms');
      }
      expect(taps, 1);
    });
  });

  testWidgets(
    'motionOf collapses implicit durations only under Reduce Motion',
    (tester) async {
      for (final reduce in [false, true]) {
        late Duration got;
        await tester.pumpWidget(
          MediaQuery(
            data: MediaQueryData(disableAnimations: reduce),
            child: Builder(
              builder: (context) {
                got = motionOf(context, kDurFast);
                return const SizedBox();
              },
            ),
          ),
        );
        expect(
          got,
          reduce ? Duration.zero : kDurFast,
          reason: 'reduce=$reduce',
        );
      }
    },
  );
}
