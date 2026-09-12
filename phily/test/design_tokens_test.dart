// The app defines three corner-radius tokens (kRadiusSm/Md/Lg) and CLAUDE.md
// makes theme.dart "the single definition of the app's gold/glass language".
// A hardcoded 20 that happens to equal kRadiusLg is invisible until someone
// retunes the token and one pill silently keeps the old shape.
//
// This test reads the source rather than the widget tree on purpose: the
// defect is a literal in the code, not something a rendered frame reveals.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:phily/theme.dart';

/// Every Dart source file under lib/.
List<File> _libSources() => Directory('lib')
    .listSync(recursive: true)
    .whereType<File>()
    .where((f) => f.path.endsWith('.dart'))
    .toList();

void main() {
  test('no radius literal duplicates a token', () {
    // Values that ARE the tokens. A literal equal to one of these is a
    // hardcoded copy; any other number is a deliberate one-off.
    final tokens = <double, String>{
      kRadiusSm: 'kRadiusSm',
      kRadiusMd: 'kRadiusMd',
      kRadiusLg: 'kRadiusLg',
    };
    // `Radius.circular(N)` / `BorderRadius.circular(N)` / `radius: N`.
    final pattern = RegExp(
      r'(?:BorderRadius\.circular|Radius\.circular|radius:)\s*\(?\s*'
      r'(\d+(?:\.\d+)?)\s*\)?',
    );

    final offenders = <String>[];
    for (final file in _libSources()) {
      final lines = file.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        for (final match in pattern.allMatches(lines[i])) {
          final value = double.parse(match.group(1)!);
          final token = tokens[value];
          if (token != null) {
            offenders.add('${file.path}:${i + 1} uses $value — that is $token');
          }
        }
      }
    }

    expect(
      offenders,
      isEmpty,
      reason:
          'hardcoded radii that duplicate a design token:\n'
          '${offenders.join("\n")}',
    );
  });
}
