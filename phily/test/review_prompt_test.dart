// When Phily asks for an App Store rating. Apple caps the sheet at three
// showings a year, so a careless rule spends them on people who haven't seen
// the app work yet.
import 'package:flutter_test/flutter_test.dart';
import 'package:phily/services/review_prompt.dart';

void main() {
  final installed = DateTime(2026, 10, 1);
  final later = installed.add(const Duration(days: 10));

  bool ask({
    int landed = 8,
    DateTime? now,
    String version = '1.1.0',
    DateTime? lastAsked,
    String? askedVersion,
  }) => ReviewPrompt.shouldAsk(
    landedShots: landed,
    firstLaunch: installed,
    now: now ?? later,
    version: version,
    lastAsked: lastAsked,
    askedVersion: askedVersion,
  );

  test('asks a settled user who has seen shots land', () {
    expect(ask(), isTrue);
  });

  test('not before enough shots have landed', () {
    expect(ask(landed: ReviewPrompt.minLandedShots - 1), isFalse);
    expect(ask(landed: ReviewPrompt.minLandedShots), isTrue);
  });

  test('not in the first days', () {
    expect(ask(now: installed.add(const Duration(days: 1))), isFalse);
  });

  test('never twice in one version', () {
    expect(ask(askedVersion: '1.1.0'), isFalse);
    expect(ask(askedVersion: '1.0.0'), isTrue);
  });

  test('not again within the minimum gap, even after an update', () {
    final asked = later.subtract(const Duration(days: 30));
    expect(ask(lastAsked: asked, askedVersion: '1.0.0'), isFalse);
    final longAgo = later.subtract(ReviewPrompt.minGap);
    expect(ask(lastAsked: longAgo, askedVersion: '1.0.0'), isTrue);
  });
}
