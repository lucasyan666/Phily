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

  group('hint pill (board 1b status rail)', () {
    // One rail, one slot, one message, docked above the gilded lip. The
    // message is the only thing on the camera screen made of words, so it has
    // to survive a long guide line at accessibility sizes on a narrow phone.
    const longest = 'Tilt left until the horizon meets the guide';
    for (final d in [_devices.first, _devices[1]]) {
      for (final scale in _textScales) {
        testWidgets('fits ${d.name} at $scale× text', (tester) async {
          await _pumpOn(
            tester,
            d,
            scale,
            const Scaffold(
              backgroundColor: Colors.black,
              body: Center(
                child: HintPill(icon: Icons.straighten, text: longest),
              ),
            ),
          );
          expect(tester.takeException(), isNull, reason: 'overflow');

          // The pill must stay inside the screen it is docked on.
          final r = tester.getRect(find.byType(HintPill));
          expect(r.left, greaterThanOrEqualTo(0), reason: 'off the left edge');
          expect(
            r.right,
            lessThanOrEqualTo(d.size.width),
            reason:
                'off the right edge — ${r.width}pt on a ${d.size.width}pt '
                'screen',
          );

          // And the text inside it must not be clipped.
          final para = tester.renderObject<RenderParagraph>(find.text(longest));
          expect(
            para.textSize.height,
            lessThanOrEqualTo(para.size.height + 0.5),
            reason: 'message clipped inside the pill',
          );

          // Board 1b wants a docked strip, not a tower: the pill uses the
          // width the screen actually offers rather than a fixed 260pt, so a
          // long message wraps to fewer lines and stays out of the frame.
          expect(
            r.width,
            greaterThan(260),
            reason: 'pill is not using the ${d.size.width}pt screen',
          );
          expect(r.width, lessThanOrEqualTo(d.size.width - 40));
        });
      }
    }
  });

  group('viewer chrome (board 1g)', () {
    // The guide pill sits in the top bar's centre slot: back button on the
    // left, a 48pt spacer on the right, so it gets width − 48 − 48 − margins.
    // "GOLDEN TRIANGLES · GUIDE ON" is the longest real label.
    for (final d in [_devices.first, _devices[2]]) {
      for (final scale in _textScales) {
        testWidgets('guide pill fits ${d.name} at $scale× text', (
          tester,
        ) async {
          final double slot = d.size.width - 96;
          await _pumpOn(
            tester,
            d,
            scale,
            Scaffold(
              backgroundColor: Colors.black,
              body: Align(
                alignment: Alignment.topCenter,
                child: SizedBox(
                  width: slot,
                  child: Center(
                    child: debugViewerChrome(
                      guideLabel: 'Golden Triangles',
                      guideOn: true,
                    ),
                  ),
                ),
              ),
            ),
          );
          expect(tester.takeException(), isNull, reason: 'overflow');

          // It must stay inside its slot, not just inside the screen.
          final r = tester.getRect(find.byType(HintPill));
          expect(
            r.width,
            lessThanOrEqualTo(slot + 0.5),
            reason: 'pill is ${r.width}pt in a ${slot}pt slot',
          );

          // And its label must not be clipped inside the pill.
          final para = tester.renderObject<RenderParagraph>(
            find.textContaining('GUIDE ON'),
          );
          expect(
            para.textSize.height,
            lessThanOrEqualTo(para.size.height + 0.5),
            reason: 'guide label clipped',
          );
        });

        testWidgets('date chip fits ${d.name} at $scale× text', (tester) async {
          await _pumpOn(
            tester,
            d,
            scale,
            Scaffold(
              backgroundColor: Colors.black,
              body: Center(
                child: debugViewerChrome(
                  guideLabel: '',
                  guideOn: false,
                  when: DateTime(2026, 7, 13, 15, 4),
                ),
              ),
            ),
          );
          expect(tester.takeException(), isNull, reason: 'overflow');
          final r = tester.getRect(find.byType(HintPill));
          expect(r.left, greaterThanOrEqualTo(0));
          expect(r.right, lessThanOrEqualTo(d.size.width));
        });

        testWidgets('day header fits ${d.name} at $scale× text', (
          tester,
        ) async {
          await _pumpOn(
            tester,
            d,
            scale,
            Scaffold(
              backgroundColor: Colors.black,
              body: Align(
                alignment: Alignment.topCenter,
                // The longest real header: dateLabel() emits "14 Jun 2024" for
                // other years, and it is uppercased and tracked.
                child: debugSectionHeader('14 Jun 2024'),
              ),
            ),
          );
          expect(tester.takeException(), isNull, reason: 'overflow');
          final para = tester.renderObject<RenderParagraph>(
            find.text('14 JUN 2024'),
          );
          expect(
            para.textSize.width,
            lessThanOrEqualTo(para.size.width + 0.5),
            reason: 'day header clipped horizontally at $scale×',
          );
          expect(
            para.textSize.height,
            lessThanOrEqualTo(para.size.height + 0.5),
            reason:
                'day header clipped vertically at $scale× — the bar is a '
                'fixed 30pt and the label grows with text size',
          );
          // At ordinary sizes the bar keeps its designed 30pt: the grid's
          // pinned headers are laid out against that height.
          if (scale <= 1.3) {
            expect(
              tester.getSize(find.byType(Container).first).height,
              30,
              reason: 'header height changed at $scale×',
            );
          }
        });
      }
    }
  });

  group('gallery filter row', () {
    // ALL / ◆ BY PHILY, docked at the foot of the grid. Two fixed-height
    // chips in an unconstrained Row — the shape that overflowed the paywall.
    for (final d in _devices) {
      for (final scale in _textScales) {
        testWidgets('fits ${d.name} at $scale× text', (tester) async {
          await _pumpOn(
            tester,
            d,
            scale,
            Scaffold(
              backgroundColor: Colors.black,
              body: Align(
                alignment: Alignment.bottomCenter,
                child: debugFilterRow(),
              ),
            ),
          );
          expect(tester.takeException(), isNull, reason: 'overflow');

          // Both labels fit inside their chips at every text size.
          for (final label in ['ALL', '◆ BY PHILY']) {
            final para = tester.renderObject<RenderParagraph>(find.text(label));
            expect(
              para.textSize.height,
              lessThanOrEqualTo(para.size.height + 0.5),
              reason: '$label clipped in its chip',
            );
          }
        });
      }
    }

    for (final scale in _textScales) {
      testWidgets('chips meet the 44pt tap target at $scale× text', (
        tester,
      ) async {
        // Apple's HIG minimum. The chips are 40pt by design (they match the
        // guide card's dismiss chip), so a 2pt pad each side lifts the target
        // without changing how the chip looks.
        await _pumpOn(
          tester,
          _devices.first,
          scale,
          Scaffold(
            body: Align(
              alignment: Alignment.bottomCenter,
              child: debugFilterRow(),
            ),
          ),
        );
        final chips = find.byType(PopTap);
        expect(chips, findsNWidgets(2));
        for (var i = 0; i < 2; i++) {
          expect(
            tester.getSize(chips.at(i)).height,
            greaterThanOrEqualTo(44),
            reason: 'filter chip $i is under the 44pt minimum',
          );
        }
      });
    }

    testWidgets('the chips sit on one line at ordinary text sizes', (
      tester,
    ) async {
      // A Wrap gives an unconstrained child the whole row, so without an
      // intrinsic width the two chips stretched full-width and stacked at
      // EVERY size — a regression introduced while fixing the AX5 overflow.
      await _pumpOn(
        tester,
        _devices.first,
        1.0,
        Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: debugFilterRow(),
          ),
        ),
      );
      final tops = <double>{};
      final chips = find.byType(PopTap);
      for (var i = 0; i < chips.evaluate().length; i++) {
        tops.add(tester.getRect(chips.at(i)).top);
      }
      expect(tops.length, 1, reason: 'chips wrapped at the default text size');
      expect(
        tester.getSize(find.byType(Wrap)).height,
        lessThan(60),
        reason: 'filter row is two rows tall when it should be one',
      );
    });
  });

  group('viewer guide-recall pill', () {
    // The pill a user taps to show/hide the guide over a photo. Built on
    // HintPill, whose 38pt minimum is under the 44pt an interactive control
    // needs — most pills are passive labels, so the pad belongs at this call
    // site rather than in HintPill itself.
    for (final scale in _textScales) {
      testWidgets('meets the 44pt tap target at $scale× text', (tester) async {
        await _pumpOn(
          tester,
          _devices[1],
          scale,
          Scaffold(body: Center(child: debugGuidePill())),
        );
        expect(
          tester.getSize(find.byType(PopTap)).height,
          greaterThanOrEqualTo(44),
          reason: 'guide-recall pill is under the 44pt minimum',
        );
      });
    }

    testWidgets('the pill itself is unchanged at ordinary sizes', (
      tester,
    ) async {
      // Hit-area only: the visible pill must still be HintPill's 38pt.
      await _pumpOn(
        tester,
        _devices[1],
        1.0,
        Scaffold(body: Center(child: debugGuidePill())),
      );
      expect(tester.getSize(find.byType(HintPill)).height, 38);
    });
  });

  group('guide card height budget', () {
    // The framed diagram used a flat 200pt on every phone, which on a short
    // one was ~30% of the card — squeezing the copy and pushing the dismiss
    // chip further below the fold. It is now a share of the screen.
    for (final d in [_devices.first, _devices[2]]) {
      testWidgets('the diagram is a share of ${d.name}, not a flat 200pt', (
        tester,
      ) async {
        late BuildContext ctx;
        await _pumpOn(
          tester,
          d,
          1.0,
          Scaffold(
            body: Builder(
              builder: (c) {
                ctx = c;
                return const SizedBox.expand();
              },
            ),
          ),
        );
        showCompositionGuide(ctx, CompositionMode.fibonacciSpiral);
        await tester.pumpAndSettle();

        // The diagram's own SizedBox, found via the framed AspectRatio inside.
        final frame = tester.getRect(find.byType(AspectRatio).first);
        expect(
          frame.height,
          lessThanOrEqualTo(d.size.height * 0.25),
          reason: 'diagram takes more than a quarter of the screen',
        );
        expect(
          frame.height,
          greaterThanOrEqualTo(140 - 0.5),
          reason: 'diagram collapsed too small to read',
        );
      });
    }

    for (final d in [_devices.first, _devices.last]) {
      for (final scale in _textScales) {
        testWidgets('dismiss stays on screen: ${d.name} at $scale× text', (
          tester,
        ) async {
          // "GOT IT" used to be the last item INSIDE the card's scroll view,
          // so it sat below the fold — 216pt down on an SE at 1.0×, 4444pt at
          // AX5. It is the card's only *visible* way out (barrier-tap works
          // but is not discoverable), so it is now docked outside the scroll.
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
          showCompositionGuide(ctx, CompositionMode.fibonacciSpiral);
          await tester.pumpAndSettle();

          final chip = tester.getRect(find.text('GOT IT'));
          expect(
            chip.top,
            greaterThanOrEqualTo(0),
            reason: 'dismiss above the top edge',
          );
          expect(
            chip.bottom,
            lessThanOrEqualTo(d.size.height),
            reason:
                'dismiss ${chip.bottom}pt down a ${d.size.height}pt '
                'screen — below the fold, without scrolling',
          );
        });
      }
    }

    testWidgets('a tall phone shows nearly the whole card at once', (
      tester,
    ) async {
      late BuildContext ctx;
      await _pumpOn(
        tester,
        _devices[2], // Pro Max
        1.0,
        Scaffold(
          body: Builder(
            builder: (c) {
              ctx = c;
              return const SizedBox.expand();
            },
          ),
        ),
      );
      showCompositionGuide(ctx, CompositionMode.fibonacciSpiral);
      await tester.pumpAndSettle();
      // With real safe-area insets a Pro Max scrolls ~43pt out of a ~726pt
      // viewport — under 6%, i.e. effectively the whole card in view. (256pt
      // before the diagram became proportional; 12pt before the card gained
      // its Material ancestor, which restores the default text baseline and
      // costs a few points of height.) Asserted as a FRACTION of the
      // viewport, so it measures "does the card fit" rather than a number
      // that drifts with every type tweak.
      final pos = tester
          .state<ScrollableState>(find.byType(Scrollable).last)
          .position;
      expect(
        pos.maxScrollExtent / pos.viewportDimension,
        lessThan(0.10),
        reason:
            'the card should very nearly fit a Pro Max outright — '
            'scrolls ${pos.maxScrollExtent} of ${pos.viewportDimension}',
      );
    });
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
            // Centred card (not a docked sheet since the fade-in change): it
            // must stay inside the screen, stay a readable column rather than
            // stretching edge-to-edge, and leave the frame visible around it.
            final card = tester.getRect(find.byType(BackdropFilter).first);
            expect(
              card.left,
              greaterThanOrEqualTo(0),
              reason: '${spec.mode.name}: card off the left edge',
            );
            expect(
              card.right,
              lessThanOrEqualTo(d.size.width),
              reason: '${spec.mode.name}: card off the right edge',
            );
            expect(
              card.width,
              lessThanOrEqualTo(460.5),
              reason:
                  '${spec.mode.name}: card ${card.width}pt wide — a '
                  'reference card is a column of prose, not a full-bleed bar',
            );
            // Horizontally centred within half a point.
            expect(
              (card.center.dx - d.size.width / 2).abs(),
              lessThan(0.5),
              reason: '${spec.mode.name}: card not centred',
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
