// Gallery grid thumbnail sizing — the request size must track the cell's real
// pixel size across the phones we ship on, and stay bounded on wide layouts.
// A drift here is invisible to the analyzer but shows up as soft thumbnails
// (under-request) or wasted decode per cell (over-request).
import 'package:flutter_test/flutter_test.dart';
import 'package:phily/screens/gallery_viewer.dart';

void main() {
  group('gridThumbPx', () {
    // 3 columns, 14pt margins, 5pt gutters: cell = (width − 38) / 3.
    test(
      'iPhone SE (375pt @2×) decodes fewer pixels than the old fixed 300',
      () {
        final px = gridThumbPx(375, 2);
        expect(px, 225);
        expect(px * px, lessThan(300 * 300));
      },
    );

    test('iPhone 15 Pro (393pt @3×) is no longer upscaled', () {
      // 300px in a 355px cell was drawn at 1.18× — soft.
      expect(gridThumbPx(393, 3), 355);
    });

    test('iPhone Pro Max (430pt @3×) matches its larger cell', () {
      expect(gridThumbPx(430, 3), 392);
    });

    test('landscape / tablet widths are capped so the cache stays bounded', () {
      expect(gridThumbPx(852, 3), 420);
      expect(gridThumbPx(1024, 2), 420);
    });

    test('degenerate narrow widths still get a usable image', () {
      expect(gridThumbPx(200, 1), 160);
    });

    test(
      'request is never smaller than the cell (no upscale in the range)',
      () {
        for (final w in [375.0, 390.0, 393.0, 414.0, 428.0, 430.0]) {
          for (final dpr in [2.0, 3.0]) {
            final cellPx = (w - 38) / 3 * dpr;
            final px = gridThumbPx(w, dpr);
            if (cellPx <= 420) {
              expect(
                px,
                greaterThanOrEqualTo(cellPx.floor()),
                reason: 'w=$w dpr=$dpr',
              );
            }
          }
        }
      },
    );
  });
}
