// The zoom readout convention. On the ultra-wide the zoom range tops out at
// 0.99999 (reaching 1.0 would swap back to the main lens mid-scrub), and the
// label must never round that up to a misleading "1.0x" — anything below the
// switchover displays at most 0.9x.
import 'package:flutter_test/flutter_test.dart';
import 'package:phily/camera_page.dart';

void main() {
  test('the ultra-wide ceiling never displays as 1.0x', () {
    expect(zoomLabel(0.99999), '0.9×');
    expect(zoomLabel(0.95), '0.9×');
    expect(zoomLabel(0.9), '0.9×');
  });

  test('true ultra-wide values show one decimal', () {
    expect(zoomLabel(0.5), '0.5×');
    expect(zoomLabel(0.7), '0.7×');
  });

  test('main-lens values are passed through untouched', () {
    expect(zoomLabel(1.0), '1.0×');
    expect(zoomLabel(2.34), '2.3×');
    expect(zoomLabel(25.0), '25.0×');
  });
}
