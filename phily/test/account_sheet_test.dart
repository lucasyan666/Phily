// The account sheet in a test build: no Firebase, so it is always signed
// out. What matters here is that the signed-out sheet — the one every user
// sees — lays out at every text size, and that the email step works as a
// step (back, a disabled button until the address is plausible).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:phily/screens/account_sheet.dart';
import 'package:phily/theme.dart';

void main() {
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);

  Future<void> pumpSheet(
    WidgetTester tester, {
    double textScale = 1.0,
    Size screen = const Size(393, 852),
  }) async {
    tester.view.physicalSize = screen * 3;
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        builder: (c, child) => MediaQuery(
          data: MediaQuery.of(
            c,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: const Scaffold(
          body: Align(alignment: Alignment.bottomCenter, child: AccountSheet()),
        ),
      ),
    );
    // Fixed pumps: the gold button's shimmer never settles.
    for (int i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  testWidgets('signed out: says the camera never needs it, offers three '
      'ways in', (tester) async {
    await pumpSheet(tester);
    expect(find.text('Sign in, if you like.'), findsOneWidget);
    expect(find.textContaining('never needs an account'), findsOneWidget);
    expect(find.text('Continue with Apple'), findsOneWidget);
    expect(find.text('Continue with Google'), findsOneWidget);
    expect(find.text('Continue with email'), findsOneWidget);
    expect(find.text('Send feedback'), findsOneWidget);
    expect(find.text('Request a composition'), findsOneWidget);
  });

  testWidgets('the email step: back returns, Send link waits for an '
      'address', (tester) async {
    await pumpSheet(tester);
    await tester.tap(find.text('Continue with email'));
    for (int i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('We\'ll email you a link.'), findsOneWidget);

    final button = find.ancestor(
      of: find.text('Send link'),
      matching: find.byType(GildedButton),
    );
    expect(tester.widget<GildedButton>(button).onTap, isNull);
    await tester.enterText(find.byType(TextField), 'me@example.com');
    await tester.pump();
    expect(tester.widget<GildedButton>(button).onTap, isNotNull);

    await tester.tap(find.text('Back'));
    for (int i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('Sign in, if you like.'), findsOneWidget);
  });

  for (final scale in [1.0, 2.0, 3.1]) {
    testWidgets('fits an iPhone SE at ${scale}x text', (tester) async {
      final errors = <String>[];
      final previous = FlutterError.onError;
      FlutterError.onError = (d) => errors.add(d.exception.toString());
      await pumpSheet(tester, textScale: scale, screen: const Size(375, 667));
      FlutterError.onError = previous;
      expect(errors.where((e) => e.contains('overflowed')), isEmpty);
    });
  }
}
