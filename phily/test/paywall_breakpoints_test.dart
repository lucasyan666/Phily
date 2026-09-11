// The paywall is where a user commits money, and it had no scroll view: its
// content was a fixed Column, so on any phone shorter than the content it
// simply CLIPPED — 233pt off the bottom of an iPhone SE at the DEFAULT text
// size, taking the purchase buttons with it. A user could not buy.
//
// Three rows were also unconstrained (tier name, price column, header
// wordmark, promo badge), overflowing horizontally at every size.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:phily/screens/paywall.dart';

const _devices = <String, Size>{
  'iPhone SE': Size(375, 667),
  'iPhone 15 Pro': Size(393, 852),
  'iPhone Pro Max': Size(430, 932),
};

// 1.3 ≈ largest non-accessibility size; 2.0 and 3.1 ≈ AX2 and AX5.
const _scales = [1.0, 1.3, 2.0, 3.1];

void main() {
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);

  for (final entry in _devices.entries) {
    for (final scale in _scales) {
      testWidgets('paywall fits ${entry.key} at ${scale}x text', (
        tester,
      ) async {
        final errors = <String>[];
        final previous = FlutterError.onError;
        FlutterError.onError = (d) => errors.add(d.exception.toString());
        tester.view.physicalSize = entry.value * 3;
        tester.view.devicePixelRatio = 3;
        addTearDown(() {
          tester.view.reset();
          FlutterError.onError = previous;
        });

        late BuildContext ctx;
        await tester.pumpWidget(
          MaterialApp(
            builder: (c, child) => MediaQuery(
              data: MediaQuery.of(
                c,
              ).copyWith(textScaler: TextScaler.linear(scale)),
              child: child!,
            ),
            home: Scaffold(
              body: Builder(
                builder: (c) {
                  ctx = c;
                  return const SizedBox.expand();
                },
              ),
            ),
          ),
        );
        showPhilyProPaywall(ctx);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));

        expect(
          errors,
          isEmpty,
          reason: '${entry.key} @${scale}x: ${errors.toSet().join(" | ")}',
        );
      });
    }
  }

  testWidgets('the purchase buttons are always reachable', (tester) async {
    // The point of the scroll view: on a short phone the CTA is below the
    // fold, and a user who cannot reach it cannot subscribe.
    tester.view.physicalSize = const Size(375 * 3, 667 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    late BuildContext ctx;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (c) {
              ctx = c;
              return const SizedBox.expand();
            },
          ),
        ),
      ),
    );
    showPhilyProPaywall(ctx);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.byType(Scrollable), findsWidgets);
    final restore = find.text('Restore purchases');
    expect(restore, findsOneWidget);
    await tester.ensureVisible(restore);
  });

  testWidgets('the paywall names its barrier for assistive tech', (
    tester,
  ) async {
    late BuildContext ctx;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (c) {
              ctx = c;
              return const SizedBox.expand();
            },
          ),
        ),
      ),
    );
    showPhilyProPaywall(ctx);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    // Reach the sheet's own route via a widget only it builds.
    final route = ModalRoute.of(tester.element(find.text('Restore purchases')));
    expect(route?.barrierLabel, 'Dismiss Phily Pro');
  });
}
