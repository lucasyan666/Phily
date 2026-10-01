// Every docked sheet must close with a swipe down, even when its content is
// taller than the screen. It shipped once where a swipe only scrolled the
// content: the account sheet overflows a standard iPhone by ~110pt, so it
// could only be closed by tapping above it. And a tap outside a text field
// must put the keyboard away, which Flutter doesn't do on mobile by default.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:phily/screens/account_sheet.dart';
import 'package:phily/screens/feedback_sheet.dart';
import 'package:phily/screens/paywall.dart';

void main() {
  setUpAll(() {
    GoogleFonts.config.allowRuntimeFetching = false;
    PackageInfo.setMockInitialValues(
      appName: 'Phily',
      packageName: 'com.lucasyan.phily',
      version: '1.0.0',
      buildNumber: '1',
      buildSignature: '',
    );
  });

  /// Fixed pumps, not pumpAndSettle: the gold button's shimmer never stops.
  Future<void> wait(WidgetTester tester, [int ticks = 12]) async {
    for (int i = 0; i < ticks; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> open(
    WidgetTester tester,
    Size screen,
    void Function(BuildContext) show,
  ) async {
    tester.view.physicalSize = screen * 3;
    tester.view.devicePixelRatio = 3;
    tester.view.padding = const FakeViewPadding(top: 47 * 3, bottom: 34 * 3);
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
    show(ctx);
    await wait(tester);
  }

  const phones = {'iPhone 15': Size(390, 844), 'iPhone SE': Size(375, 667)};

  for (final phone in phones.entries) {
    testWidgets('account sheet: swipe down on the content closes it '
        '(${phone.key})', (tester) async {
      await open(tester, phone.value, (c) => openAccount(c));
      expect(find.byType(AccountSheet), findsOneWidget);
      await tester.flingFrom(
        tester.getCenter(find.text('Sign in, if you like.')),
        const Offset(0, 400),
        1500,
      );
      await wait(tester);
      expect(find.byType(AccountSheet), findsNothing);
    });

    testWidgets('account sheet: dragging the handle closes it '
        '(${phone.key})', (tester) async {
      await open(tester, phone.value, (c) => openAccount(c));
      final Offset top = tester.getTopLeft(find.byType(AccountSheet));
      await tester.flingFrom(
        Offset(phone.value.width / 2, top.dy + 14),
        const Offset(0, 400),
        1500,
      );
      await wait(tester);
      expect(find.byType(AccountSheet), findsNothing);
    });
  }

  testWidgets('a short scroll-back does not close it', (tester) async {
    // Pulling down a little to scroll back to the top must stay a scroll.
    await open(tester, phones['iPhone SE']!, (c) => openAccount(c));
    await tester.drag(
      find.text('Request a composition'),
      const Offset(0, -150),
    );
    await wait(tester, 4);
    await tester.drag(find.text('Request a composition'), const Offset(0, 120));
    await wait(tester);
    expect(find.byType(AccountSheet), findsOneWidget);
  });

  testWidgets('feedback sheet: swipe down closes it', (tester) async {
    await open(tester, phones['iPhone SE']!, (c) => showFeedbackSheet(c));
    await tester.flingFrom(
      tester.getCenter(find.text('Write to the makers'.toUpperCase())),
      const Offset(0, 400),
      1500,
    );
    await wait(tester);
    expect(find.byType(FeedbackSheet), findsNothing);
  });

  testWidgets('paywall: swipe down closes it', (tester) async {
    await open(tester, phones['iPhone SE']!, (c) => showPhilyProPaywall(c));
    expect(find.text('Phily Pro'), findsWidgets);
    await tester.flingFrom(
      tester.getCenter(find.text('Phily Pro').first),
      const Offset(0, 400),
      1500,
    );
    await wait(tester);
    expect(find.text('Restore purchases'), findsNothing);
  });

  testWidgets('tapping outside a text field puts the keyboard away', (
    tester,
  ) async {
    await open(tester, phones['iPhone 15']!, (c) => showFeedbackSheet(c));
    final field = find.byType(EditableText).first;
    await tester.tap(field);
    await tester.pump();
    expect(tester.widget<EditableText>(field).focusNode.hasFocus, isTrue);

    await tester.tapAt(
      tester.getCenter(find.text('Idea')) - const Offset(0, 90),
    );
    await tester.pump();
    expect(tester.widget<EditableText>(field).focusNode.hasFocus, isFalse);
  });
}
