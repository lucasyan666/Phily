// Gallery date/time header formatting — pure calendar logic with real edge
// cases (month and year boundaries, 12-hour conversion at midnight/noon).
import 'package:flutter_test/flutter_test.dart';
import 'package:phily/screens/gallery_viewer.dart';

void main() {
  final now = DateTime(2026, 7, 13, 15, 0);

  group('dateLabel', () {
    test('same calendar day is Today regardless of time', () {
      expect(dateLabel(DateTime(2026, 7, 13, 0, 1), now: now), 'Today');
      expect(dateLabel(DateTime(2026, 7, 13, 23, 59), now: now), 'Today');
    });

    test('previous calendar day is Yesterday, even across a month boundary',
        () {
      expect(dateLabel(DateTime(2026, 7, 12, 23, 59), now: now), 'Yesterday');
      expect(
        dateLabel(DateTime(2026, 6, 30), now: DateTime(2026, 7, 1)),
        'Yesterday',
      );
    });

    test('older date this year: day + month, no year suffix', () {
      expect(dateLabel(DateTime(2026, 6, 14), now: now), '14 Jun');
      expect(dateLabel(DateTime(2026, 1, 2), now: now), '2 Jan');
    });

    test('other years get the year appended', () {
      expect(dateLabel(DateTime(2024, 6, 14), now: now), '14 Jun 2024');
    });

    test('Yesterday wins over the year suffix at the year boundary', () {
      expect(
        dateLabel(DateTime(2025, 12, 31), now: DateTime(2026, 1, 1)),
        'Yesterday',
      );
    });
  });

  group('timeLabel', () {
    test('12-hour conversion with padded minutes', () {
      expect(timeLabel(DateTime(2026, 1, 1, 13, 3)), '1:03 PM');
      expect(timeLabel(DateTime(2026, 1, 1, 9, 5)), '9:05 AM');
      expect(timeLabel(DateTime(2026, 1, 1, 23, 59)), '11:59 PM');
    });

    test('midnight and noon read as 12, not 0', () {
      expect(timeLabel(DateTime(2026, 1, 1, 0, 0)), '12:00 AM');
      expect(timeLabel(DateTime(2026, 1, 1, 12, 0)), '12:00 PM');
    });
  });
}
