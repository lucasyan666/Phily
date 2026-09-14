// The guide card's diagram — an example scene with the mode's guide drawn over
// it — IS the teaching content. The prose describes a picture, so a screen
// reader that gets the prose and nothing of the picture has the worse half.
//
// The card also became a dialog (from a bottom sheet) partway through, which
// changes how assistive tech scopes and dismisses it. These tests pin both.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:phily/camera_page.dart';

Future<BuildContext> _pump(WidgetTester tester) async {
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
  return ctx;
}

void main() {
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);

  testWidgets('every mode describes its diagram to a screen reader', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    for (final spec in kCompositionSpecs) {
      if (spec.mode == CompositionMode.none) continue;
      final ctx = await _pump(tester);
      showCompositionGuide(ctx, spec.mode);
      await tester.pumpAndSettle();

      final node = tester.getSemantics(
        find.bySemanticsLabel(RegExp('Diagram:.*${RegExp.escape(spec.label)}')),
      );
      expect(
        node.label,
        contains(spec.label),
        reason: '${spec.mode.name}: diagram not described',
      );
      expect(
        node,
        matchesSemantics(isImage: true, label: node.label),
        reason: '${spec.mode.name}: diagram should announce as a figure',
      );

      Navigator.of(ctx).pop();
      await tester.pumpAndSettle();
    }
    handle.dispose();
  });

  testWidgets('the guide is a labelled, dismissible modal route', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    final ctx = await _pump(tester);
    showCompositionGuide(ctx, CompositionMode.fibonacciSpiral);
    await tester.pumpAndSettle();

    // Barrier carries a label, so VoiceOver can announce the dismiss target
    // rather than an anonymous region.
    final route = ModalRoute.of(tester.element(find.text('Fibonacci Spiral')))!;
    expect(route.barrierLabel, isNotNull);
    expect(route.barrierDismissible, isTrue);
    handle.dispose();
  });
}
