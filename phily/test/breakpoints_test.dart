// Breakpoint coverage for the pure-widget screens — the first-launch welcome
// and the composition guide sheet — at the phones we ship on: iPhone SE
// (375×667 @2×), 15 Pro (393×852 @3×), Pro Max (430×932 @3×) and the 15 Pro
// held landscape, each at 1.0× and 1.3× text scale with realistic safe-area
// insets. A RenderFlex overflow is a FlutterError, so "nothing overflows" is an
// assertion via tester.takeException(), not a screenshot judgement.
//
// Widths are conservative: the test font renders every glyph 1em wide, so
// copy wraps more here than with Fraunces/Outfit. Heights are close to real.
//
// The camera page stays out — it is plugin- and timer-driven (widget_test.dart).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:phily/camera_page.dart';
import 'package:phily/screens/welcome.dart';

class _Device {
  final String name;
  final Size size; // logical points
  final double dpr;
  final EdgeInsets safeArea; // logical points
  const _Device(this.name, this.size, this.dpr, this.safeArea);
}

const _devices = [
  _Device('iPhone SE', Size(375, 667), 2, EdgeInsets.only(top: 20)),
  _Device(
    'iPhone 15 Pro',
    Size(393, 852),
    3,
    EdgeInsets.only(top: 59, bottom: 34),
  ),
  _Device(
    'iPhone Pro Max',
    Size(430, 932),
    3,
    EdgeInsets.only(top: 59, bottom: 34),
  ),
  _Device(
    'iPhone 15 Pro landscape',
    Size(852, 393),
    3,
    EdgeInsets.only(left: 59, right: 59, bottom: 21),
  ),
];

const _textScales = [1.0, 1.3];

Future<void> _pumpOn(
  WidgetTester tester,
  _Device d,
  double textScale,
  Widget home,
) async {
  tester.view.physicalSize = d.size * d.dpr;
  tester.view.devicePixelRatio = d.dpr;
  // FakeViewPadding is in physical pixels; MediaQuery divides by dpr.
  tester.view.padding = FakeViewPadding(
    left: d.safeArea.left * d.dpr,
    top: d.safeArea.top * d.dpr,
    right: d.safeArea.right * d.dpr,
    bottom: d.safeArea.bottom * d.dpr,
  );
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: home,
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() {
    // No network in tests; text falls back to the test font.
    GoogleFonts.config.allowRuntimeFetching = false;
  });

  group('welcome screen', () {
    for (final d in _devices) {
      for (final scale in _textScales) {
        testWidgets('fits ${d.name} at $scale× text', (tester) async {
          var tapped = 0;
          await _pumpOn(
            tester,
            d,
            scale,
            WelcomeScreen(onContinue: () => tapped++),
          );
          expect(tester.takeException(), isNull, reason: 'overflow');

          // Board 1f is one screen: in portrait at the default text size the
          // copy is placed by the Spacers and nothing scrolls. Scrolling is the
          // escape hatch for large text and landscape, not the layout.
          final scroll = tester
              .state<ScrollableState>(find.byType(Scrollable))
              .position
              .maxScrollExtent;
          if (scale == 1.0 && d.size.height > d.size.width) {
            expect(scroll, 0, reason: 'portrait should fit without scrolling');
          }

          // The one tap target: ≥44pt, reachable, fully on screen, wired up.
          final label = find.text('Open the camera');
          expect(label, findsOneWidget);
          await tester.ensureVisible(label);
          final button = tester.getRect(
            find.ancestor(of: label, matching: find.byType(Container)).first,
          );
          expect(button.height, greaterThanOrEqualTo(44));
          expect(button.bottom, lessThanOrEqualTo(d.size.height));
          expect(button.top, greaterThanOrEqualTo(0));
          await tester.tap(label);
          expect(tapped, 1);

          // Nothing clipped off the bottom: the footnote is the last child.
          final footnote = find.text('7 days of everything, free. No card.');
          expect(footnote, findsOneWidget);
          await tester.ensureVisible(footnote);
          expect(
            tester.getRect(footnote).bottom,
            lessThanOrEqualTo(d.size.height - d.safeArea.bottom),
          );
        });
      }
    }
  });

  group('composition guide sheet', () {
    // Worst cases only: the narrowest phone and the shortest orientation.
    final tight = [_devices.first, _devices.last];
    for (final d in tight) {
      for (final scale in _textScales) {
        testWidgets('every mode opens on ${d.name} at $scale× text', (
          tester,
        ) async {
          for (final spec in kCompositionSpecs) {
            if (spec.mode == CompositionMode.none) continue;
            late BuildContext ctx;
            await _pumpOn(
              tester,
              d,
              scale,
              Scaffold(
                body: Builder(
                  builder: (c) {
                    ctx = c;
                    return const SizedBox.expand();
                  },
                ),
              ),
            );
            showCompositionGuide(ctx, spec.mode);
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull, reason: spec.mode.name);
            expect(
              find.text(spec.label),
              findsOneWidget,
              reason: '${spec.mode.name}: title',
            );
            // The sheet never exceeds its 86% cap and the dismiss chip exists.
            final sheet = tester.getRect(find.byType(SingleChildScrollView));
            expect(
              sheet.height,
              lessThanOrEqualTo(d.size.height * 0.86 + 0.5),
              reason: '${spec.mode.name}: sheet height',
            );
            expect(
              find.text('GOT IT'),
              findsOneWidget,
              reason: '${spec.mode.name}: dismiss',
            );
            Navigator.of(ctx).pop();
            await tester.pumpAndSettle();
          }
        });
      }
    }
  });
}
