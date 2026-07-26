// Composition registry invariants. The camera page and the guide sheet look
// specs up with `kCompositionByMode[mode]!`, so a mode missing from the
// registry — or missing its guide copy — crashes at runtime the first time
// that mode is selected. These tests turn "added an enum value, forgot the
// spec" into a test failure instead.
import 'package:flutter_test/flutter_test.dart';
import 'package:phily/camera_page.dart';

void main() {
  test('every CompositionMode has a registry entry', () {
    for (final mode in CompositionMode.values) {
      expect(
        kCompositionByMode[mode],
        isNotNull,
        reason: 'no CompositionSpec registered for $mode — '
            'kCompositionByMode[mode]! will throw',
      );
    }
  });

  test('one spec per mode, no duplicates', () {
    expect(kCompositionSpecs.length, CompositionMode.values.length);
    expect(
      kCompositionSpecs.map((s) => s.mode).toSet().length,
      kCompositionSpecs.length,
    );
  });

  test('every real mode ships full guide copy (tip, what, how)', () {
    for (final spec in kCompositionSpecs) {
      if (spec.mode == CompositionMode.none) continue;
      expect(spec.label.trim(), isNotEmpty, reason: '${spec.mode}: empty label');
      expect(
        spec.tip?.trim(),
        isNotEmpty,
        reason: '${spec.mode}: missing "best for" tip',
      );
      expect(
        spec.what?.trim(),
        isNotEmpty,
        reason: '${spec.mode}: missing guide "what it is" copy',
      );
      expect(
        spec.how?.trim(),
        isNotEmpty,
        reason: '${spec.mode}: missing guide "how to use it" copy',
      );
    }
  });

  test('mode.label resolves through the registry', () {
    expect(CompositionMode.none.label, 'None');
    expect(CompositionMode.ruleOfThirds.label, 'Rule of Thirds');
    expect(CompositionMode.horizonGrid.label, 'Horizon Grid');
  });

  test('fixed power points are valid in-band fractions', () {
    for (final spec in kCompositionSpecs) {
      for (final p in spec.powerPoints ?? const <List<double>>[]) {
        expect(p.length, 2, reason: '${spec.mode}: power point must be [x, y]');
        for (final v in p) {
          expect(v, greaterThan(0.0), reason: '${spec.mode}: point off-frame');
          expect(v, lessThan(1.0), reason: '${spec.mode}: point off-frame');
        }
      }
    }
  });
}
