import 'package:flutter_test/flutter_test.dart';
import 'package:phily/services/shot_guide_log.dart';

void main() {
  group('ShotGuide', () {
    test('round-trips through JSON', () {
      const g = ShotGuide(
        mode: 'ruleOfThirds',
        label: 'Rule of Thirds',
        locked: true,
        point: 1,
        rollDeg: -0.4,
      );
      final back = ShotGuide.fromJson(g.toJson())!;
      expect(back.mode, 'ruleOfThirds');
      expect(back.label, 'Rule of Thirds');
      expect(back.locked, isTrue);
      expect(back.point, 1);
      expect(back.rollDeg, closeTo(-0.4, 1e-9));
    });

    test('names the four grid crossings in power-point order', () {
      String? name(int p) => ShotGuide(
        mode: 'ruleOfThirds',
        label: 'Rule of Thirds',
        locked: true,
        point: p,
      ).crossingName;
      // kThirdsPoints order: TL, TR, BL, BR.
      expect(name(0), 'top-left');
      expect(name(1), 'top-right');
      expect(name(2), 'bottom-left');
      expect(name(3), 'bottom-right');
      expect(name(-1), isNull, reason: 'no crossing when nothing locked');
    });

    test('rejects malformed records instead of throwing', () {
      expect(ShotGuide.fromJson('nope'), isNull);
      expect(ShotGuide.fromJson({'locked': true}), isNull, reason: 'no mode');
      expect(ShotGuide.fromJson({'mode': 'phi'})!.locked, isFalse);
    });

    test('None is not a guide', () {
      const g = ShotGuide(mode: 'none', label: 'None', locked: false);
      expect(g.hasGuide, isFalse);
    });
  });
}
