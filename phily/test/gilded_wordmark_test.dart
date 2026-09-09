// The wordmark is one object. The branded loader and the first-launch screen
// used to carry their own ShaderMask recipes (different gradients); now both
// draw GildedWordmark, so a change to the gilding lands in both places and
// nowhere else. The ShaderMask count per screen is the guard against a recipe
// creeping back in.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:phily/screens/branded_loader.dart';
import 'package:phily/screens/welcome.dart';
import 'package:phily/theme.dart';

void main() {
  setUpAll(() {
    GoogleFonts.config.allowRuntimeFetching = false;
  });

  testWidgets('GildedWordmark is a gilded ShaderMask over "Phily"', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Center(
          child: GildedWordmark(
            size: 52,
            weight: FontWeight.w400,
            letterSpacing: 0.5,
          ),
        ),
      ),
    );
    expect(find.byType(ShaderMask), findsOneWidget);
    final text = tester.widget<Text>(find.text('Phily'));
    expect(text.style?.fontSize, 52);
    expect(text.style?.fontWeight, FontWeight.w400);
    expect(text.style?.letterSpacing, 0.5);
  });

  testWidgets(
    'the welcome screen draws exactly one wordmark, no other recipe',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(home: WelcomeScreen(onContinue: () {})),
      );
      await tester.pumpAndSettle();
      expect(find.byType(GildedWordmark), findsOneWidget);
      expect(find.byType(ShaderMask), findsOneWidget);
    },
  );

  testWidgets(
    'the branded loader draws exactly one wordmark, no other recipe',
    (tester) async {
      await tester.pumpWidget(const MaterialApp(home: BrandedLoader()));
      // The loader's mark spins forever, so settle a few frames, not to rest.
      await tester.pump(const Duration(milliseconds: 800));
      expect(find.byType(GildedWordmark), findsOneWidget);
      expect(find.byType(ShaderMask), findsOneWidget);
    },
  );
}
