// The feedback form's promise is about consent: no email leaves the phone
// unless the user switched on "You can reply to me about this". These tests
// pin that promise to what is actually sent, not to what the UI shows.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:phily/screens/feedback_sheet.dart';
import 'package:phily/services/feedback.dart';
import 'package:phily/theme.dart';

void main() {
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);

  late List<Map<String, Object?>> sent;
  setUp(() {
    sent = [];
    FeedbackService.debugSender = (p) async => sent.add(p);
    // No platform in a test: without this the version lookup never returns.
    PackageInfo.setMockInitialValues(
      appName: 'Phily',
      packageName: 'com.lucasyan.phily',
      version: '1.0.0',
      buildNumber: '1',
      buildSignature: '',
    );
  });
  tearDown(() => FeedbackService.debugSender = null);

  /// Pumps the sheet on an iPhone-sized screen and lets its entrance finish.
  /// Fixed pumps, not pumpAndSettle: the gold button's shimmer never stops.
  Future<void> pumpSheet(
    WidgetTester tester, {
    FeedbackKind kind = FeedbackKind.idea,
    String? mode,
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
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: FeedbackSheet(initialKind: kind, mode: mode),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 1));
  }

  /// Taps Send the way a user would: scrolled into view first.
  Future<void> tapSend(WidgetTester tester) async {
    await tester.ensureVisible(find.text('Send'));
    await tester.pump();
    await tester.tap(find.text('Send'));
  }

  Future<void> settle(WidgetTester tester) async {
    for (int i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  testWidgets('without consent, no email field and no email sent', (
    tester,
  ) async {
    await pumpSheet(tester);
    expect(find.text('you@example.com'), findsNothing);

    await tester.enterText(find.byType(TextField).first, 'A diagonal guide');
    await tester.pump();
    await tapSend(tester);
    await settle(tester);

    expect(sent, hasLength(1));
    expect(sent.single['contact'], false);
    expect(sent.single.containsKey('email'), isFalse);
    expect(sent.single['kind'], 'idea');
    expect(find.text('Thank you.'), findsOneWidget);
  });

  testWidgets('consent reveals the email field and gates Send on it', (
    tester,
  ) async {
    await pumpSheet(tester);
    await tester.enterText(find.byType(TextField).first, 'Leading lines');
    await tester.tap(find.byType(GildedSwitch));
    await settle(tester);

    final email = find.byType(TextField).at(1);
    expect(email, findsOneWidget);

    // An unfinished address keeps Send dead.
    await tester.enterText(email, 'me@');
    await tester.pump();
    await tapSend(tester);
    await settle(tester);
    expect(sent, isEmpty);

    await tester.enterText(email, 'me@example.com');
    await tester.pump();
    await tapSend(tester);
    await settle(tester);

    expect(sent, hasLength(1));
    expect(sent.single['contact'], true);
    expect(sent.single['email'], 'me@example.com');
    expect(sent.single['consentVersion'], FeedbackService.consentVersion);
  });

  testWidgets('switching consent back off withdraws the email', (tester) async {
    await pumpSheet(tester);
    await tester.enterText(find.byType(TextField).first, 'Frame in frame');
    await tester.tap(find.byType(GildedSwitch));
    await settle(tester);
    await tester.enterText(find.byType(TextField).at(1), 'me@example.com');
    await tester.tap(find.byType(GildedSwitch));
    await settle(tester);

    await tapSend(tester);
    await settle(tester);
    expect(sent.single['contact'], false);
    expect(sent.single.containsKey('email'), isFalse);
  });

  testWidgets('a request from a guide carries its mode and kind', (
    tester,
  ) async {
    await pumpSheet(tester, kind: FeedbackKind.composition, mode: 'Phi Grid');
    expect(find.text('Which composition should we add?'), findsOneWidget);
    expect(find.text('FROM THE PHI GRID GUIDE'), findsOneWidget);

    await tester.enterText(find.byType(TextField).first, 'Dynamic symmetry');
    await tester.pump();
    await tapSend(tester);
    await settle(tester);

    expect(sent.single['kind'], 'composition');
    expect((sent.single['context'] as Map)['mode'], 'Phi Grid');
  });

  testWidgets('a failed send keeps the words and says why', (tester) async {
    FeedbackService.debugSender = (_) async =>
        throw const FeedbackError('Couldn\'t reach Phily.');
    await pumpSheet(tester);
    await tester.enterText(find.byType(TextField).first, 'Keep me');
    await tester.pump();
    await tapSend(tester);
    await settle(tester);

    expect(find.text('Couldn\'t reach Phily.'), findsOneWidget);
    expect(find.text('Keep me'), findsOneWidget);
    expect(find.text('Thank you.'), findsNothing);
  });

  for (final scale in [1.0, 2.0, 3.1]) {
    testWidgets('the form fits an iPhone SE at ${scale}x text', (tester) async {
      final errors = <String>[];
      final previous = FlutterError.onError;
      FlutterError.onError = (d) => errors.add(d.exception.toString());
      await pumpSheet(tester, textScale: scale, screen: const Size(375, 667));
      // Open the email field too: the tallest the form gets.
      await tester.ensureVisible(find.byType(GildedSwitch));
      await tester.pump();
      await tester.tap(find.byType(GildedSwitch));
      await settle(tester);
      FlutterError.onError = previous;
      expect(errors.where((e) => e.contains('overflowed')), isEmpty);
    });
  }

  testWidgets('Send is above the fold on an iPhone SE', (tester) async {
    await pumpSheet(tester, screen: const Size(375, 667));
    final send = tester.getRect(find.text('Send'));
    expect(send.bottom, lessThan(667));
  });
}
