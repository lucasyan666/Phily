// showGildedCard is the app's one arrival gesture for *reference* surfaces:
// the composition guide, and the level-line preferences that the same button
// opens on long-press. Before this they were a centred fade and a bottom
// sheet — one control, two different modal gestures.
//
// The paywall and the debug menu deliberately stay bottom sheets: a purchase
// flow is a destination and a debug menu is a list of actions, both of which
// a docked sheet suits. That distinction is the design decision these tests
// protect, so they assert the shared *behaviour*, not that everything matches.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phily/theme.dart';

Future<void> _open(WidgetTester tester, {bool reduceMotion = false}) async {
  late BuildContext ctx;
  await tester.pumpWidget(
    MediaQuery(
      data: MediaQueryData(disableAnimations: reduceMotion),
      child: MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (c) {
              ctx = c;
              return const SizedBox.expand();
            },
          ),
        ),
      ),
    ),
  );
  showGildedCard<void>(
    context: ctx,
    builder: (_) => const Center(
      child: SizedBox(width: 200, height: 120, child: Text('card')),
    ),
  );
}

void main() {
  testWidgets('fades and settles in place, then is centred', (tester) async {
    await _open(tester);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));

    // Mid-transition it is partly transparent and slightly small — arriving
    // in place, not sliding up from an edge.
    final fadeFinder = find.ancestor(
      of: find.text('card'),
      matching: find.byType(FadeTransition),
    );
    final fade = tester.widget<FadeTransition>(fadeFinder.first);
    expect(fade.opacity.value, greaterThan(0.0));
    expect(fade.opacity.value, lessThan(1.0));
    final scale = tester.widget<ScaleTransition>(
      find
          .ancestor(
            of: find.text('card'),
            matching: find.byType(ScaleTransition),
          )
          .first,
    );
    expect(scale.scale.value, greaterThanOrEqualTo(0.96));
    expect(scale.scale.value, lessThan(1.0));

    await tester.pumpAndSettle();
    expect(tester.widget<FadeTransition>(fadeFinder.first).opacity.value, 1.0);
    final card = tester.getRect(find.text('card'));
    final screen = tester.getRect(find.byType(MaterialApp));
    expect((card.center.dx - screen.center.dx).abs(), lessThan(0.5));
    expect((card.center.dy - screen.center.dy).abs(), lessThan(0.5));
  });

  testWidgets('under Reduce Motion it simply appears', (tester) async {
    await _open(tester, reduceMotion: true);
    await tester.pump();
    // No transition at all: fully present on the first frame.
    expect(find.text('card'), findsOneWidget);
    final fade = tester.widget<FadeTransition>(
      find
          .ancestor(
            of: find.text('card'),
            matching: find.byType(FadeTransition),
          )
          .first,
    );
    expect(fade.opacity.value, 1.0);
    // No scale wrapper at all under Reduce Motion.
    expect(
      find.ancestor(
        of: find.text('card'),
        matching: find.byType(ScaleTransition),
      ),
      findsNothing,
    );
  });

  testWidgets('tapping the barrier dismisses it', (tester) async {
    await _open(tester);
    await tester.pumpAndSettle();
    expect(find.text('card'), findsOneWidget);
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    expect(find.text('card'), findsNothing);
  });
}
