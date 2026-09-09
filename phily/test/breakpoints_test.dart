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
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:phily/camera_page.dart';
import 'package:phily/screens/gallery_viewer.dart';
import 'package:phily/services/shot_guide_log.dart';
import 'package:phily/screens/welcome.dart';
import 'package:phily/theme.dart';

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

// 1.3 ≈ the largest non-accessibility size (xxxL); 2.0 and 3.1 ≈ the AX2 and
// AX5 accessibility sizes. Layouts scroll or grow at these — nothing may clip.
const _textScales = [1.0, 1.3, 2.0, 3.1];

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
          // It is the shared control, not a one-off — so it carries the tick,
          // the bubble, the button trait and Reduce Motion for free.
          expect(
            find.ancestor(of: label, matching: find.byType(PopTap)),
            findsOneWidget,
            reason: 'the first button in the app should be a PopTap',
          );

          await tester.ensureVisible(label);
          final button = tester.getRect(
            find.ancestor(of: label, matching: find.byType(Container)).first,
          );
          expect(button.height, greaterThanOrEqualTo(44));
          expect(button.bottom, lessThanOrEqualTo(d.size.height));
          expect(button.top, greaterThanOrEqualTo(0));
          // The label must sit inside its button at every text size — a
          // fixed-height box lets large type spill past the gold. Two checks:
          // the paragraph's laid-out text fits its own box, and that box sits
          // inside the button.
          final para = tester.renderObject<RenderParagraph>(label);
          expect(
            para.textSize.height,
            lessThanOrEqualTo(para.size.height + 0.5),
            reason:
                'label text ${para.textSize} overflows its box ${para.size}',
          );
          final labelRect = tester.getRect(label);
          expect(
            button.inflate(0.5).contains(labelRect.topLeft) &&
                button.inflate(0.5).contains(labelRect.bottomRight),
            isTrue,
            reason: 'label $labelRect spills out of button $button',
          );
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

  group('empty gallery', () {
    // The first thing a new user sees. Fixed-size mark + two unbounded lines
    // of copy: exactly the shape that overflows a short phone at large text.
    for (final d in _devices) {
      for (final scale in _textScales) {
        for (final phily in [false, true]) {
          final which = phily ? 'BY PHILY' : 'all photos';
          testWidgets('fits ${d.name} at $scale× text ($which)', (
            tester,
          ) async {
            await _pumpOn(
              tester,
              d,
              scale,
              Scaffold(
                backgroundColor: Colors.black,
                body: debugEmptyGallery(phily: phily),
              ),
            );
            expect(tester.takeException(), isNull, reason: 'overflow');

            // At ordinary sizes nothing scrolls and the mark is full size —
            // the scroll is the escape hatch for large text, not the layout.
            if (scale <= 1.3) {
              expect(
                tester
                    .state<ScrollableState>(find.byType(Scrollable))
                    .position
                    .maxScrollExtent,
                0,
                reason: 'should fit without scrolling at $scale×',
              );
              expect(tester.getSize(find.byType(Icon)).width, 52);
            }

            // Both lines of copy are on screen, not clipped off an edge.
            final headline = find.text(
              phily ? 'Nothing by Phily yet' : 'No photos yet',
            );
            expect(headline, findsOneWidget);
            for (final f in [headline, find.byType(Icon)]) {
              final r = tester.getRect(f);
              expect(r.top, greaterThanOrEqualTo(0), reason: 'clipped top');
              expect(
                r.bottom,
                lessThanOrEqualTo(d.size.height),
                reason: 'clipped bottom',
              );
              expect(r.left, greaterThanOrEqualTo(0), reason: 'clipped left');
              expect(
                r.right,
                lessThanOrEqualTo(d.size.width),
                reason: 'clipped right',
              );
            }
          });
        }
      }
    }
  });

  group('guide caption (board 1g)', () {
    // The recall line under a photo: "Subject on the top-left crossing.
    // Locked at 0.4° off level." Long copy in a fixed-width slot beside the
    // photo — the shape that clips when the text grows.
    final cases = <String, ShotGuide>{
      'crossing + locked': const ShotGuide(
        mode: 'ruleOfThirds',
        label: 'Rule of Thirds',
        locked: true,
        point: 0,
        rollDeg: -0.42,
      ),
      'horizon': const ShotGuide(
        mode: 'horizonGrid',
        label: 'Horizon Grid',
        locked: true,
        rollDeg: 0.1,
      ),
      'unlocked, no crossing': const ShotGuide(
        mode: 'goldenSpiral',
        label: 'Golden Spiral',
        locked: false,
      ),
    };
    for (final d in [_devices.first, _devices.last]) {
      for (final scale in _textScales) {
        for (final entry in cases.entries) {
          testWidgets('${entry.key} fits ${d.name} at $scale× text', (
            tester,
          ) async {
            await _pumpOn(
              tester,
              d,
              scale,
              Scaffold(
                backgroundColor: Colors.black,
                body: Align(
                  alignment: Alignment.bottomCenter,
                  // The viewer gives it the screen width minus 18pt margins.
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 18),
                    child: debugGuideCaption(
                      guide: entry.value,
                      when: DateTime(2026, 7, 13, 15, 4),
                    ),
                  ),
                ),
              ),
            );
            expect(tester.takeException(), isNull, reason: 'overflow');

            // The timestamp is the last line: it must stay on screen.
            final stamp = find.textContaining('·');
            expect(stamp, findsOneWidget);
            final r = tester.getRect(stamp);
            expect(r.left, greaterThanOrEqualTo(0));
            expect(r.right, lessThanOrEqualTo(d.size.width));
            expect(r.bottom, lessThanOrEqualTo(d.size.height));
          });
        }
      }
    }
  });

  testWidgets('the guide caption reads as one sentence, not fragments', (
    tester,
  ) async {
    // Board 1g's payoff: "why this shot worked". A screen reader should get
    // the recall line, the gold lock clause and the timestamp in one swipe.
    final handle = tester.ensureSemantics();
    await _pumpOn(
      tester,
      _devices[1],
      1.0,
      Scaffold(
        body: debugGuideCaption(
          guide: const ShotGuide(
            mode: 'ruleOfThirds',
            label: 'Rule of Thirds',
            locked: true,
            point: 0,
            rollDeg: -0.42,
          ),
          when: DateTime(2026, 7, 13, 15, 4),
        ),
      ),
    );
    final node = tester.getSemantics(find.byType(MergeSemantics));
    expect(node.label, contains('crossing'));
    expect(node.label, contains('0.4'));
    expect(node.label, contains('Jul'), reason: 'timestamp merged in');
    handle.dispose();
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
            // Dismiss is the shared PopTap control with a ≥44pt tap target,
            // and tapping it closes the sheet.
            final gotIt = find.text('GOT IT');
            expect(gotIt, findsOneWidget, reason: '${spec.mode.name}: dismiss');
            final dismiss = find.ancestor(
              of: gotIt,
              matching: find.byType(PopTap),
            );
            expect(
              dismiss,
              findsOneWidget,
              reason: '${spec.mode.name}: PopTap',
            );
            expect(
              tester.getSize(dismiss).height,
              greaterThanOrEqualTo(44),
              reason: '${spec.mode.name}: tap target',
            );
            // A chip, not a bar: narrower than the sheet's content width.
            expect(
              tester.getSize(dismiss).width,
              lessThan(sheet.width - 48),
              reason: '${spec.mode.name}: dismiss stretched to full width',
            );
            // And its label fits inside it at every text size.
            final chipPara = tester.renderObject<RenderParagraph>(gotIt);
            expect(
              chipPara.textSize.height,
              lessThanOrEqualTo(chipPara.size.height + 0.5),
              reason: '${spec.mode.name}: GOT IT text overflows its chip',
            );
            // Long copy on a short phone puts the chip below the fold — the
            // sheet scrolls by design, so reach it the way a thumb would.
            await tester.ensureVisible(gotIt);
            await tester.pumpAndSettle();
            await tester.tap(gotIt);
            await tester.pumpAndSettle();
            expect(gotIt, findsNothing, reason: '${spec.mode.name}: closes');
          }
        });
      }
    }
  });
}
