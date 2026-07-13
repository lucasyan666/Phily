part of 'camera_page.dart';

/// Cross composition — the vertical arm is a fixed track between these fractions
/// of the frame height; the horizontal crossbar slides within it (see [_crossY]).
const double kCrossTopFrac = 0.28;
const double kCrossBottomFrac = 0.68;
const double kCrossDefaultY = 0.38;

// ─────────────────────────────────────────────────────────────────────────────
// Focus bracket painter — corner-bracket focus indicator
// ─────────────────────────────────────────────────────────────────────────────

class _FocusBracketPainter extends CustomPainter {
  final Color gold;
  const _FocusBracketPainter({required this.gold});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = gold
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.square
      ..isAntiAlias = true;

    const double arm = 14.0;
    final double w = size.width;
    final double h = size.height;

    // Top-left corner
    canvas.drawLine(Offset(0, arm), const Offset(0, 0), paint);
    canvas.drawLine(const Offset(0, 0), Offset(arm, 0), paint);
    // Top-right corner
    canvas.drawLine(Offset(w - arm, 0), Offset(w, 0), paint);
    canvas.drawLine(Offset(w, 0), Offset(w, arm), paint);
    // Bottom-right corner
    canvas.drawLine(Offset(w, h - arm), Offset(w, h), paint);
    canvas.drawLine(Offset(w, h), Offset(w - arm, h), paint);
    // Bottom-left corner
    canvas.drawLine(Offset(arm, h), Offset(0, h), paint);
    canvas.drawLine(Offset(0, h), Offset(0, h - arm), paint);

    // Center focus dot
    canvas.drawCircle(
      Offset(w / 2, h / 2),
      1.5,
      paint
        ..style = PaintingStyle.fill
        ..color = gold.withValues(alpha: 0.70),
    );
  }

  @override
  bool shouldRepaint(_FocusBracketPainter old) => old.gold != gold;
}

// ────────────────────────────────────────────────────────────────────────────
// Zoom meter painter — hairline tick wheel
// ────────────────────────────────────────────────────────────────────────────

// ────────────────────────────────────────────────────────────────────────────
// Native seamless zoom bridge
// Communicates with AVCaptureDevice.videoZoomFactor directly via MethodChannel,
// bypassing Flutter’s own CameraController zoom path. This is what makes
// lens switching truly seamless — the device’s active session is never torn
// down; iOS handles physical lens selection internally.
// ────────────────────────────────────────────────────────────────────────────

class _CameraZoomChannel {
  static const MethodChannel _ch = MethodChannel('com.phily.camera/zoom');
  static final instance = _CameraZoomChannel._();
  _CameraZoomChannel._();

  /// Immediate zoom — for continuous drag input.
  /// Writes AVCaptureDevice.videoZoomFactor directly; reflects on next frame.
  Future<void> setZoom(double factor) =>
      _ch.invokeMethod('setZoom', {'factor': factor});

  /// Hardware-animated zoom ramp — for discrete level taps.
  /// Uses AVCaptureDevice.ramp(toVideoZoomFactor:withRate:) which is
  /// frame-accurate and cancels any previous ramp atomically.
  Future<void> rampZoom(double factor, {double rate = 5.0}) =>
      _ch.invokeMethod('rampZoom', {'factor': factor, 'rate': rate});

  /// Returns {min, max, current, switchoverFactors} from the native device.
  /// switchoverFactors contains the exact zoom levels where iOS transitions
  /// between physical lenses (e.g. [2.0, 6.0] on iPhone 14 Pro).
  Future<Map<String, dynamic>?> getZoomInfo() async {
    final raw = await _ch.invokeMethod<Map>('getZoomInfo');
    if (raw == null) return null;
    return raw.map((k, v) => MapEntry(k.toString(), v));
  }
}

class _ZoomMeterPainter extends CustomPainter {
  final double zoom; // current logical zoom level
  final double minZoom; // lower bound of the active range (0.5 or 1.0)
  final double maxZoom; // upper bound of the active range
  final double pxPerUnit; // logical pixels per 1×
  final List<double> switchoverFactors; // hardware lens-switch boundaries
  final double active; // 0 resting → 1 finger on the belt (swells the wheel)

  const _ZoomMeterPainter({
    required this.zoom,
    required this.maxZoom,
    required this.pxPerUnit,
    this.minZoom = 0.5,
    this.switchoverFactors = const [],
    this.active = 0,
  });

  static const Color _white = Color(0xFFFFFFFF);
  static const Color _gold = kGold;

  // Major tick labels shown on the wheel.
  static const List<double> _major = [0.5, 1, 2, 5, 10, 15, 20, 25];

  @override
  void paint(Canvas canvas, Size size) {
    final double cx = size.width / 2;
    final double cy = size.height;

    // How many zoom units are visible on each side of centre.
    final double visibleUnits = (size.width / 2) / pxPerUnit;

    final double lo = (zoom - visibleUnits - 1).floorToDouble().clamp(
      minZoom,
      maxZoom,
    );
    final double hi = (zoom + visibleUnits + 1).ceilToDouble().clamp(
      minZoom,
      maxZoom,
    );

    // Draw minor ticks every 0.1×, major ticks at the _major values.
    final Paint tickPaint = Paint()
      ..color = _white.withValues(alpha: 0.28)
      ..strokeWidth = 0.8
      ..strokeCap = StrokeCap.butt;

    final Paint majorPaint = Paint()
      ..color = _white.withValues(alpha: 0.55)
      ..strokeWidth = 1.0
      ..strokeCap = StrokeCap.butt;

    // Centre indicator line (gold) — thickens and brightens while engaged.
    final Paint centrePaint = Paint()
      ..color = _gold
      ..strokeWidth = 1.5 + 0.7 * active
      ..strokeCap = StrokeCap.butt;

    // Engage swell: everything grows a touch under the finger, the same
    // press-language as the video scrubber's tube.
    final double swell = 1 + 0.22 * active;

    final TextPainter tp = TextPainter(
      textDirection: TextDirection.ltr,
      textAlign: TextAlign.center,
    );

    // Tick pitch. The ultra-wide dial (range under 1×) is spread out to
    // ~320px/unit, so it gets fine 0.02× ticks with every 0.1× labelled; the
    // 1–25× belt keeps classic 0.1× ticks labelled at the _major stops.
    // Integer stepping avoids float drift at either pitch.
    final bool ultraDial = maxZoom < 1.0;
    final double step = ultraDial ? 0.02 : 0.1;
    int i = (lo / step).round();
    while (i * step <= hi + step / 2) {
      final double v = i * step;
      // Never draw past the range end: in ultra-wide the range tops out just
      // under 1.0×, and a "1" tick there would advertise an unreachable stop
      // (the loop's half-step slack would otherwise include it).
      if (v > maxZoom + 1e-6) break;
      final double x = cx + (v - zoom) * pxPerUnit;
      if (x < 0 || x > size.width) {
        i++;
        continue;
      }

      // A tick is a hardware lens-switchover boundary if it matches one of the
      // virtualDeviceSwitchOverVideoZoomFactors reported by iOS. These get a
      // gold accent tick (like the native Camera app's 0.5×/1×/2× indicators).
      // The tolerance shrinks on the fine-pitch dial so only the single
      // nearest tick takes the accent.
      final bool isSwitchover = switchoverFactors.any(
        (s) => (v - s).abs() < (ultraDial ? 0.015 : 0.08),
      );
      final bool isMajor =
          isSwitchover ||
          (ultraDial
              ? i % 5 ==
                    0 // every 0.1× on the spread-out ultra dial
              : _major.any((m) => (v - m).abs() < 0.02));
      final double tickH =
          (isSwitchover ? 20.0 : (isMajor ? 16.0 : 8.0)) * swell;
      final Paint p = isSwitchover
          ? (Paint()
              ..color = _gold.withValues(alpha: 0.75)
              ..strokeWidth = 1.2
              ..strokeCap = StrokeCap.butt)
          : (isMajor ? majorPaint : tickPaint);

      canvas.drawLine(Offset(x, cy - tickH), Offset(x, cy), p);

      if (isMajor) {
        final String label = v < 1
            ? v.toStringAsFixed(1)
            : v.toInt().toString();
        tp.text = TextSpan(
          text: label,
          style: TextStyle(
            color: isSwitchover
                ? _gold.withValues(alpha: 0.80)
                : _white.withValues(alpha: 0.55),
            fontSize: 8,
            fontWeight: isSwitchover ? FontWeight.w400 : FontWeight.w300,
            letterSpacing: 0.5,
          ),
        );
        tp.layout();
        tp.paint(canvas, Offset(x - tp.width / 2, cy - tickH - tp.height - 2));
      }

      i++;
    }

    // Centre indicator
    canvas.drawLine(Offset(cx, cy - 22 * swell), Offset(cx, cy), centrePaint);
  }

  @override
  bool shouldRepaint(_ZoomMeterPainter old) =>
      old.zoom != zoom ||
      old.pxPerUnit != pxPerUnit ||
      old.active != active ||
      old.minZoom != minZoom ||
      old.maxZoom != maxZoom ||
      old.switchoverFactors != switchoverFactors;
}

// ─────────────────────────────────────────────────────────────────────────────
// Semicircle clipper — clips a rectangle to the left half of a circle whose
// centre sits at the right edge. Creates the "popping out from the right" shape.
// ─────────────────────────────────────────────────────────────────────────────

class _SemicircleFromRightClipper extends CustomClipper<Path> {
  @override
  Path getClip(Size size) {
    final path = Path();
    // Arc centre is at the right edge, vertically centred.
    // Sweeping 180° counterclockwise from top traces the left semicircle.
    path.addArc(
      Rect.fromCenter(
        center: Offset(size.width, size.height / 2),
        width: size.height, // diameter = height → radius = height/2
        height: size.height,
      ),
      -math.pi / 2, // start at top  (12 o'clock)
      -math.pi, // sweep 180° CCW → through 9 o'clock to 6 o'clock
    );
    path.close(); // straight line back along the right edge
    return path;
  }

  @override
  bool shouldReclip(_SemicircleFromRightClipper _) => false;
}

// ─────────────────────────────────────────────────────────────────────────────
// Vertical zoom meter painter — like _ZoomMeterPainter but rotated 90°.
// Ticks are horizontal lines emanating from the right edge.
// Drag up = zoom in, drag down = zoom out.
// ─────────────────────────────────────────────────────────────────────────────

class _VerticalZoomMeterPainter extends CustomPainter {
  final double zoom;
  final double maxZoom;
  final double pxPerUnit;
  final List<double> switchoverFactors;

  const _VerticalZoomMeterPainter({
    required this.zoom,
    required this.maxZoom,
    required this.pxPerUnit,
    this.switchoverFactors = const [],
  });

  static const Color _white = Color(0xFFFFFFFF);
  static const Color _gold = kGold;
  static const List<double> _major = [0.5, 1, 2, 5, 10, 15, 20, 25];

  @override
  void paint(Canvas canvas, Size size) {
    final double cy = size.height / 2;
    final double rx = size.width; // right edge — tick origin

    final double visibleUnits = (size.height / 2) / pxPerUnit;
    final double lo = (zoom - visibleUnits - 1).floorToDouble().clamp(
      0.5,
      maxZoom,
    );
    final double hi = (zoom + visibleUnits + 1).ceilToDouble().clamp(
      0.5,
      maxZoom,
    );

    final Paint tickPaint = Paint()
      ..color = _white.withValues(alpha: 0.28)
      ..strokeWidth = 0.8;
    final Paint majorPaint = Paint()
      ..color = _white.withValues(alpha: 0.55)
      ..strokeWidth = 1.0;
    final Paint centrePaint = Paint()
      ..color = _gold
      ..strokeWidth = 1.5;

    final TextPainter tp = TextPainter(
      textDirection: TextDirection.ltr,
      textAlign: TextAlign.right,
    );

    double v = (lo * 10).round() / 10;
    while (v <= hi + 0.05) {
      final double y = cy + (v - zoom) * pxPerUnit;
      if (y < 0 || y > size.height) {
        v = double.parse(((v * 10).round() / 10 + 0.1).toStringAsFixed(1));
        continue;
      }

      final bool isSwitchover = switchoverFactors.any(
        (s) => (v - s).abs() < 0.08,
      );
      final bool isMajor =
          _major.any((m) => (v - m).abs() < 0.02) || isSwitchover;
      final double tickLen = isSwitchover ? 22.0 : (isMajor ? 16.0 : 7.0);

      final Paint p = isSwitchover
          ? (Paint()
              ..color = _gold.withValues(alpha: 0.75)
              ..strokeWidth = 1.2)
          : (isMajor ? majorPaint : tickPaint);

      // Horizontal tick from right edge going left
      canvas.drawLine(Offset(rx - tickLen, y), Offset(rx, y), p);

      if (isMajor) {
        final String label = v < 1
            ? v.toStringAsFixed(1)
            : v.toInt().toString();
        tp.text = TextSpan(
          text: label,
          style: TextStyle(
            color: isSwitchover
                ? _gold.withValues(alpha: 0.85)
                : _white.withValues(alpha: 0.55),
            fontSize: 8,
            fontWeight: isSwitchover ? FontWeight.w400 : FontWeight.w300,
            letterSpacing: 0.4,
          ),
        );
        tp.layout();
        // Label sits just to the left of the tick, vertically centred on it
        tp.paint(
          canvas,
          Offset(rx - tickLen - tp.width - 3, y - tp.height / 2),
        );
      }

      v = double.parse(((v * 10).round() / 10 + 0.1).toStringAsFixed(1));
    }

    // Centre indicator — gold horizontal line at current zoom position
    canvas.drawLine(Offset(rx - 26, cy), Offset(rx, cy), centrePaint);

    // Current zoom label centred on the indicator
    final String zLabel =
        '${zoom < 1 ? zoom.toStringAsFixed(1) : zoom.toStringAsFixed(1)}×';
    tp.text = TextSpan(
      text: zLabel,
      style: const TextStyle(
        color: _gold,
        fontSize: 11,
        fontWeight: FontWeight.w300,
        letterSpacing: 1.0,
      ),
    );
    tp.layout();
    tp.paint(
      canvas,
      Offset(rx - tickLen(zoom) - tp.width - 6, cy - tp.height / 2),
    );
  }

  double tickLen(double v) {
    final isSwitchover = switchoverFactors.any((s) => (v - s).abs() < 0.08);
    final isMajor = _major.any((m) => (v - m).abs() < 0.02) || isSwitchover;
    return isSwitchover ? 22.0 : (isMajor ? 16.0 : 7.0);
  }

  @override
  bool shouldRepaint(_VerticalZoomMeterPainter old) =>
      old.zoom != zoom || old.switchoverFactors != switchoverFactors;
}

// ─────────────────────────────────────────────────────────────────────────────
// Composition mode enum
// ─────────────────────────────────────────────────────────────────────────────

enum CompositionMode {
  none,
  horizonGrid,
  ruleOfThirds,
  goldenSection,
  goldenTriangles,
  fibonacciSpiral,
  cross,
  focalMass,
  vArrangement,
  diagonal,
  radial,
  lArrangement,
  compoundCurve,
  pyramid,
  circular,
  symmetry,
  aspectRatio;

  /// Display name — sourced from the composition registry (see compositions.dart).
  String get label => kCompositionByMode[this]!.label;
}

// ─────────────────────────────────────────────────────────────────────────────
// Single painter that dispatches to the correct drawing routine
// ─────────────────────────────────────────────────────────────────────────────

// ─────────────────────────────────────────────────────────────────────────────
// Glow segment — a normalised grid-line coordinate with per-frame intensity
// ─────────────────────────────────────────────────────────────────────────────

// Coordinates are normalised to [0,1]. Intensity fades in/out each analysis frame.
class _GlowSeg {
  double x1, y1, x2, y2;
  double intensity;
  _GlowSeg(this.x1, this.y1, this.x2, this.y2, this.intensity);
}

/// An animated face indicator. Holds the current (eased) box and the latest
/// detection target, plus opacity/appearance so it can fade and ease smoothly
/// at display framerate, decoupled from the slower detection rate.
class _FaceBox {
  // Current animated values (normalised screen space, centre + size).
  double cx, cy, w, h;
  // Latest detection target.
  double tcx, tcy, tw, th;
  double opacity; // 0..1, fades in on appear / out on loss
  double appear; // 0..1, drives a subtle scale-in
  bool matched; // matched in the most recent detection cycle
  int lastSeenMs; // last time it was matched — grace window before fading
  int
  intersection; // index 0..3 of the rule-of-thirds power point it's on, -1 none
  bool perfect; // true when that point sits near the box centre
  double alignGlow; // 0..1 animated alignment-glow strength
  // Alignment key point as an offset from the box centre — the eye midpoint for
  // faces (the portrait rule aligns the eyes, not the box), 0 otherwise.
  double keyOffX = 0, keyOffY = 0;
  // Eye-level state: the vertical spread between the eyes, whether both eyes were
  // seen this frame, and whether both currently sit on the top grid line.
  double eyeSpanY = 0;
  bool hasEyes = false;
  bool eyeLevel = false;
  _FaceBox(this.cx, this.cy, this.w, this.h, this.lastSeenMs)
    : tcx = cx,
      tcy = cy,
      tw = w,
      th = h,
      opacity = 0,
      appear = 0,
      matched = true,
      intersection = -1,
      perfect = false,
      alignGlow = 0;
}

/// Lightweight on-screen FPS meter (testing). Counts vsync ticks via a Ticker
/// and reports the actual rendered frame rate, updating ~twice a second.
class _FpsOverlay extends StatefulWidget {
  const _FpsOverlay();
  @override
  State<_FpsOverlay> createState() => _FpsOverlayState();
}

class _FpsOverlayState extends State<_FpsOverlay>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  int _frames = 0;
  int _lastMs = DateTime.now().millisecondsSinceEpoch;
  double _fps = 0;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker((_) {
      _frames++;
      final now = DateTime.now().millisecondsSinceEpoch;
      final dt = now - _lastMs;
      if (dt >= 500) {
        setState(() => _fps = _frames * 1000 / dt);
        _frames = 0;
        _lastMs = now;
      }
    })..start();
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final Color color = _fps >= 55
        ? const Color(0xFF4CD964) // green
        : _fps >= 30
        ? kGold // gold
        : const Color(0xFFFF3B30); // red
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        '${_fps.toStringAsFixed(0)} FPS',
        style: TextStyle(
          color: color,
          fontSize: 12,
          fontWeight: FontWeight.w500,
          fontFeatures: const [FontFeature.tabularFigures()],
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}

/// Pixel position (in [size] space) of the Fibonacci-spiral "eye" — the point
/// the arcs converge to — for [turns] 90° clockwise rotations and [fill] frame
/// fraction. Mirrors `_drawGoldenSpiral`'s geometry exactly so the alignment
/// target and the dot the user sees always coincide. Shared by the painter and
/// the alignment logic.
Offset _goldenSpiralEyePx(Size size, int turns, double fill) {
  const double phi = 1.6180339887;
  final int t = turns & 3;
  final bool swap = t.isOdd;
  final double fw = swap ? size.height : size.width;
  final double fh = swap ? size.width : size.height;
  final double maxW = fw * fill, maxH = fh * fill;
  double w = maxW, h = w / phi;
  if (h > maxH) {
    h = maxH;
    w = h * phi;
  }
  Rect rect = Rect.fromLTWH((fw - w) / 2, (fh - h) / 2, w, h);
  int dir = 0;
  // Cut squares until the remaining rect collapses onto the eye (sub-pixel).
  for (int i = 0; i < 20; i++) {
    final double sq = math.min(rect.width, rect.height);
    switch (dir) {
      case 0:
        rect = Rect.fromLTRB(rect.left, rect.top, rect.right - sq, rect.bottom);
        break;
      case 1:
        rect = Rect.fromLTRB(rect.left, rect.top, rect.right, rect.bottom - sq);
        break;
      case 2:
        rect = Rect.fromLTRB(rect.left + sq, rect.top, rect.right, rect.bottom);
        break;
      default:
        rect = Rect.fromLTRB(rect.left, rect.top + sq, rect.right, rect.bottom);
    }
    dir = (dir + 1) % 4;
  }
  final Offset local = rect.center;
  // Same transform the painter applies: about the band centre, rotate t·90°,
  // with the (fw × fh) frame centred there.
  final double a = t * (math.pi / 2);
  final double dx = local.dx - fw / 2, dy = local.dy - fh / 2;
  final double rx = dx * math.cos(a) - dy * math.sin(a);
  final double ry = dx * math.sin(a) + dy * math.cos(a);
  return Offset(size.width / 2 + rx, size.height / 2 + ry);
}

/// One focal-mass bubble, carrying its own drift + animation + glow so every dot
/// floats independently. Position is cluster-local px (size-independent).
class _FocalDot {
  final double dx, dy; // base position (relative to the cluster centre)
  final double r; // radius
  final double a; // base opacity
  final double phase; // animation phase offset (radians)
  final double driftX,
      driftY; // drift amplitude per axis (px) — the drift pattern
  final double speed; // drift + pulse speed multiplier
  final double glow; // glow strength (0 = none)
  const _FocalDot(
    this.dx,
    this.dy,
    this.r,
    this.a,
    this.phase,
    this.driftX,
    this.driftY,
    this.speed,
    this.glow,
  );
}

/// Focal-mass layout, computed once (the Box–Muller scatter is the expensive
/// part — caching it is what keeps the animation cheap). Mirrors the original
/// 220-dot scatter + 110-dot core exactly (seeds 7 / 31).
final List<_FocalDot> _focalDots = _buildFocalDots();
List<_FocalDot> _buildFocalDots() {
  final dots = <_FocalDot>[];
  final phaseRng = math.Random(99); // separate RNG → layout sequence unchanged
  void addCluster(
    int count,
    double sx,
    double sy,
    int seed,
    double falloff,
    double rBase,
    double rGain,
    double aBase,
    double aGain,
  ) {
    final rng = math.Random(seed);
    for (int i = 0; i < count; i++) {
      final double u1 = rng.nextDouble().clamp(1e-9, 1.0);
      final double u2 = rng.nextDouble();
      final double n1 =
          math.sqrt(-2.0 * math.log(u1)) * math.cos(2 * math.pi * u2);
      final double n2 =
          math.sqrt(-2.0 * math.log(u1)) * math.sin(2 * math.pi * u2);
      final double dx = n1 * sx, dy = n2 * sy;
      final double distNorm = math
          .sqrt(math.pow(dx / sx, 2) + math.pow(dy / sy, 2))
          .clamp(0.0, 1.0);
      final double influence = math.exp(-distNorm * distNorm * falloff);
      final double r = rBase + rGain * influence;
      final double a = aBase + aGain * influence;
      // Per-bubble drift pattern + animation, from a separate RNG so the layout
      // (seeds 7/31) is untouched. Glow scales with the dot's own brightness.
      dots.add(
        _FocalDot(
          dx,
          dy,
          r,
          a,
          phaseRng.nextDouble() * 2 * math.pi, // phase
          3.0 + phaseRng.nextDouble() * 5.0, // driftX 3–8 px
          3.0 + phaseRng.nextDouble() * 5.0, // driftY 3–8 px
          0.4 + phaseRng.nextDouble() * 0.5, // speed 0.4–0.9
          a * 0.25, // glow ∝ brightness
        ),
      );
    }
  }

  addCluster(220, 120.0, 32.0, 7, 5.5, 0.8, 1.4, 0.12, 0.58); // scatter
  addCluster(110, 28.0, 9.0, 31, 5.0, 0.6, 2.0, 0.32, 0.48); // dense core
  return dots;
}

/// Standalone painter for the "hold it level" attitude dial. Kept in its own
/// CustomPaint + RepaintBoundary so the ~50 Hz gravity updates repaint only this
/// small dial — never the whole (expensive) composition overlay.
///
/// Reads FROSTY WHITE while the shot is off-level and crossfades to molten
/// GOLD as it locks — the same two-state language as the rest of the chrome
/// (paper/white at rest, gold for "aligned"). The face is drawn in the USER's
/// frame and pinned to their bottom-left corner, so it works identically in
/// portrait and both landscape holds.
class _LevelDialPainter extends CustomPainter {
  final ValueNotifier<({double roll, double vert, bool level})?> attitude;
  final double bottomInset;
  final double topInset;
  final int deviceTurns;
  // Eased 0..1 "aligned" — the frost→gold crossfade rides the ~50 Hz attitude
  // repaints, so no extra ticker is needed. Seeded from the live verdict so a
  // page rebuild doesn't replay the bloom.
  double _litE;
  _LevelDialPainter(
    this.attitude,
    this.bottomInset, {
    this.topInset = 0,
    this.deviceTurns = 0,
  }) : _litE = (attitude.value?.level ?? false) ? 1.0 : 0.0,
       super(repaint: attitude);

  /// Frosty glass — a cool white against the app's warm golds, so "not yet
  /// level" reads as ice waiting to be lit.
  static const Color _frost = Color(0xFFE8F1F8);

  @override
  void paint(Canvas canvas, Size size) {
    final a = attitude.value;
    if (a == null) return;
    const double r = 32, margin = 20;
    // Pin the dial to the USER's bottom-left corner for the current hold —
    // portrait-space coordinates of that corner per quarter-turn.
    final int t = deviceTurns & 3;
    final double loY = (size.height - bottomInset) - margin - r;
    final double hiY = topInset + margin + r;
    final double lX = margin + r, rX = size.width - margin - r;
    final Offset c = switch (t) {
      1 => Offset(rX, loY), // CW landscape → portrait bottom-right
      2 => Offset(rX, hiY), // upside down → portrait top-right
      3 => Offset(lX, hiY), // CCW landscape → portrait top-left
      _ => Offset(lX, loY), // portrait
    };
    final double cx = c.dx, cy = c.dy;
    final double roll = a.roll, vert = a.vert;

    // Ease the aligned state so the dial crossfades frost→gold instead of
    // snapping (~100ms at the 50 Hz attitude stream).
    final double target = a.level ? 1.0 : 0.0;
    _litE += (target - _litE) * 0.18;
    if ((target - _litE).abs() < 0.01) _litE = target;
    final double lit = _litE;
    final Color tone = Color.lerp(_frost, kGold, lit)!;

    // Exaggerate roll so small tilts read clearly (≈1.8×: 3° → ~5.4°).
    final double rollEx = (roll * 1.8).clamp(-1.3, 1.3);
    // Vertical deflection → horizon offset inside the dial (clamped to the face).
    final double pitchPx = (vert * r * 1.2).clamp(-r * 1.4, r * 1.4);

    // Everything below draws in the user's frame: rotate the whole face about
    // its centre by the hold, so "up" on the dial is the user's up and the
    // hold-relative roll/pitch read correctly in any orientation.
    canvas.save();
    canvas.translate(cx, cy);
    canvas.rotate(-t * math.pi / 2);
    canvas.translate(-cx, -cy);

    // Soft outer glow — frosty breath while free, blooming gold when square.
    canvas.drawCircle(
      c,
      r + 1.5,
      Paint()
        ..color = tone.withValues(alpha: 0.16 + 0.34 * lit)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5 + 1.5 * lit
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, 5 + 3 * lit),
    );
    // Dark instrument face.
    canvas.drawCircle(
      c,
      r,
      Paint()..color = Colors.black.withValues(alpha: 0.40),
    );

    // ── Interior: the moving horizon (clipped to the dial) ──
    canvas.save();
    canvas.clipPath(Path()..addOval(Rect.fromCircle(center: c, radius: r - 1)));
    canvas.save();
    canvas.translate(cx, cy);
    canvas.rotate(rollEx);
    canvas.translate(0, pitchPx);

    const double L = r * 2.6;
    canvas.drawLine(
      const Offset(-L, 0),
      const Offset(L, 0),
      Paint()
        ..color = tone.withValues(alpha: 0.35 + 0.45 * lit)
        ..strokeWidth = 3.5
        ..strokeCap = StrokeCap.round
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3),
    );
    canvas.drawLine(
      const Offset(-L, 0),
      const Offset(L, 0),
      Paint()
        ..color = tone.withValues(alpha: 0.92)
        ..strokeWidth = 1.6
        ..strokeCap = StrokeCap.round
        ..isAntiAlias = true,
    );
    // Pitch-ladder ticks (jet feel).
    final tick = Paint()
      ..color = tone.withValues(alpha: 0.45)
      ..strokeWidth = 1.2
      ..strokeCap = StrokeCap.round;
    for (final ty in const [-13.0, 13.0]) {
      canvas.drawLine(Offset(-7, ty), Offset(7, ty), tick);
    }
    canvas.restore();
    canvas.restore();

    // ── Fixed centre "aircraft" symbol (the phone) ──
    final ref = Paint()
      ..color = tone.withValues(alpha: 0.95)
      ..strokeWidth = 2.0
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(Offset(cx - 12, cy), Offset(cx - 4, cy), ref);
    canvas.drawLine(Offset(cx + 4, cy), Offset(cx + 12, cy), ref);
    canvas.drawCircle(c, 1.8, Paint()..color = tone);

    // ── Bezel ring + fixed top roll index ──
    canvas.drawCircle(
      c,
      r,
      Paint()
        ..color = tone.withValues(alpha: 0.55 + 0.35 * lit)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4,
    );
    final idx = Path()
      ..moveTo(cx - 4, cy - r + 0.5)
      ..lineTo(cx + 4, cy - r + 0.5)
      ..lineTo(cx, cy - r + 6)
      ..close();
    canvas.drawPath(idx, Paint()..color = tone.withValues(alpha: 0.9));

    canvas.restore(); // user-frame rotation
  }

  @override
  bool shouldRepaint(_LevelDialPainter old) =>
      old.bottomInset != bottomInset ||
      old.topInset != topInset ||
      old.deviceTurns != deviceTurns;
}

class _CompositionPainter extends CustomPainter {
  final CompositionMode mode;

  /// Lines from the active grid that are currently edge-aligned.
  final List<_GlowSeg> glowSegs;

  /// Animated face indicators (drawn as corner brackets).
  final List<_FaceBox> faceBoxes;

  /// Per-power-point glow strength (0..1) for Rule-of-Thirds alignment.
  final List<double> powerGlow;

  /// Heights (px) of the top/bottom UI panels. The composition grid is drawn
  /// only within the camera-visible band `[topInset, height − bottomInset]`,
  /// so guide lines stop at the panel edges instead of sliding under them.
  final double topInset;
  final double bottomInset;

  /// Fibonacci-spiral orientation in 90° clockwise turns (0..3).
  final int spiralTurns;

  /// Fibonacci spiral: mirror horizontally (eye to the opposite side).
  final bool spiralFlipped;

  /// Focal Mass orientation in 90° clockwise turns (0..3).
  final int focalTurns;

  /// Diagonal orientation in 90° clockwise turns (0..3) — cycles which corner
  /// the fan springs from.
  final int diagonalTurns;

  /// L-Arrangement orientation in 90° clockwise turns (0..3) — cycles the corner.
  final int lTurns;

  /// L-Arrangement: mirror horizontally (swap which side the L opens to).
  final bool lFlipped;

  /// Cross composition: live rendered state — crossbar y (fraction of the frame
  /// height, clamped to the arm track), rotation (radians) about the arm centre,
  /// and selection-glow strength (0..1) while the handle is held. Read at paint
  /// time (like [horizon]) so the 60fps easing ticker triggers repaints via
  /// [repaint] without rebuilding the page. Null (warm-up) → resting cross.
  final ValueNotifier<({double y, double angle, double glow})>? cross;

  /// Drives the guide-flip transition (spiral + triangles): 0 = settled; sweeps
  /// 0..1 on a flip, dipping the guide's opacity to a trough at 0.5 that hides
  /// the swap behind a quick fade.
  final Animation<double>? gridFlip;

  /// Golden Triangles: mirror the set across the vertical axis (TL→BR ↔ TR→BL).
  final bool trianglesFlipped;

  /// V-Arrangement: flip the V upside-down (V ↔ ∧) about its vertical centre.
  final bool vFlipped;

  /// Detected eye landmarks (preview-normalised) — shown in None mode while
  /// validating eye tracking.
  final List<Offset> eyePoints;

  /// Selected crop ratio (W/H) for the Aspect Ratio mode.
  final double aspect;

  /// How the phone is currently held (0 = portrait, 1/3 = landscape, 2 = upside
  /// down). Only the Horizon Grid uses it — its guide + true-horizon rotate with
  /// the hold so the mode works sideways; every other overlay ignores it.
  final int deviceTurns;

  /// Detected horizon (preview space): roll angle + an anchor point on the line
  /// (full-screen normalised) + fade opacity + alignment-with-guide [0..1], or
  /// null. Drawn in Horizon Grid mode.
  final ValueNotifier<
    ({
      double angle,
      double ax,
      double ay,
      double op,
      double aligned,
      double dy,
    })?
  >?
  horizon;

  _CompositionPainter(
    this.mode, {
    List<_GlowSeg>? glowSegs,
    List<_FaceBox>? faceBoxes,
    List<double>? powerGlow,
    this.topInset = 0,
    this.bottomInset = 0,
    this.spiralTurns = 0,
    this.spiralFlipped = false,
    this.focalTurns = 0,
    this.diagonalTurns = 0,
    this.lTurns = 0,
    this.lFlipped = false,
    this.cross,
    this.gridFlip,
    this.trianglesFlipped = false,
    this.vFlipped = false,
    this.aspect = 1.0,
    this.horizon,
    this.deviceTurns = 0,
    List<Offset>? eyePoints,
    super.repaint,
  }) : glowSegs = glowSegs ?? const [],
       faceBoxes = faceBoxes ?? const [],
       powerGlow = powerGlow ?? const [0, 0, 0, 0],
       eyePoints = eyePoints ?? const [];

  static const Color _gold = Color(0xFFFFFFFF);
  static const double _sw = 0.8;

  /// Fraction of the frame the golden-spiral rectangle fills (1.0 = edge-to-
  /// edge like the reference; lower for more breathing room).
  static const double _goldenSpiralFill = 1.0;

  /// Height fraction of a height-limited Aspect Ratio crop (the floating-window
  /// look for 1:1 / 5:4 in landscape) — small enough that the top/bottom
  /// letterbox strips clearly read, close enough to 1 that the crop stays big.
  static const double _kAspectWindowFrac = 0.88;

  /// Where the Horizon Grid's guide line sits, as a fraction of the camera band
  /// from the top. Nudged just above the golden-section "low horizon" (1/φ ≈
  /// 0.618) so the best-spot line reads right against the level dial. Still
  /// sky-forward (~59% sky above), not centred/static. Lower this to raise the
  /// line further; the dial tracks it automatically (detection reads this value).
  static const double _horizonGuideRatio = 0.59;

  /// Normal white hairline paint used by all draw methods.
  Paint _gp({StrokeCap cap = StrokeCap.butt}) => Paint()
    ..color = _gold.withValues(alpha: 0.45)
    ..strokeWidth = _sw
    ..style = PaintingStyle.stroke
    ..strokeCap = cap
    ..strokeJoin = StrokeJoin.round
    ..isAntiAlias = true;

  Paint get _p => _gp(cap: StrokeCap.round);

  /// Guide flip-transition factor: 1 = settled (full), dipping to 0 at the swap
  /// midpoint so the change hides behind a quick fade.
  double get _gridDip {
    final f = gridFlip?.value ?? 0.0;
    return f == 0 ? 1.0 : 0.5 + 0.5 * math.cos(f * 2 * math.pi);
  }

  /// Draws one rounded L-shaped corner bracket. [sx]/[sy] are ±1 indicating the
  /// direction the arms extend from the corner [c]; [arm] is arm length, [r] the
  /// rounding radius at the corner.
  void _corner(
    Canvas canvas,
    Offset c,
    int sx,
    int sy,
    double arm,
    double r,
    Paint p,
  ) {
    final path = Path()
      ..moveTo(c.dx + sx * arm, c.dy)
      ..lineTo(c.dx + sx * r, c.dy)
      ..quadraticBezierTo(c.dx, c.dy, c.dx, c.dy + sy * r)
      ..lineTo(c.dx, c.dy + sy * arm);
    canvas.drawPath(path, p);
  }

  @override
  void paint(Canvas canvas, Size size) {
    // Composition grids are confined to the camera-visible band *between* the
    // top/bottom UI panels: translate to the band top, clip to its height, and
    // hand every draw method a band-sized canvas. Guide lines (and the Rule-of-
    // Thirds power points) therefore stop at the panel edges instead of sliding
    // underneath them. Face brackets (drawn afterwards) stay full-screen so they
    // keep tracking subjects anywhere on the preview, even over the panels.
    final double bandH = size.height - topInset - bottomInset;
    final bool banded = bandH > 1;
    final Size grid = banded ? Size(size.width, bandH) : size;

    canvas.save();
    if (banded) {
      canvas.translate(0, topInset);
      canvas.clipRect(Rect.fromLTWH(0, 0, grid.width, grid.height));
    }
    switch (mode) {
      case CompositionMode.none:
        break;
      case CompositionMode.horizonGrid:
        // Guide line + detected horizon are drawn after restore() (full-screen,
        // like the face boxes), so nothing to draw inside the banded clip.
        break;
      case CompositionMode.ruleOfThirds:
        _drawRuleOfThirds(canvas, grid);
        break;
      case CompositionMode.goldenSection:
        _drawGoldenSection(canvas, grid);
        break;
      case CompositionMode.goldenTriangles:
        // One set of golden triangles; the flip button mirrors it across the
        // vertical axis (TL→BR diagonal ↔ TR→BL diagonal).
        if (trianglesFlipped) {
          canvas.save();
          canvas.translate(grid.width, 0);
          canvas.scale(-1, 1);
          _drawGoldenTriangles(canvas, grid);
          canvas.restore();
        } else {
          _drawGoldenTriangles(canvas, grid);
        }
        break;
      case CompositionMode.fibonacciSpiral:
        _drawGoldenSpiral(canvas, grid);
        break;
      case CompositionMode.cross:
        _drawCross(canvas, grid);
        break;
      case CompositionMode.focalMass:
        _drawOriented(canvas, grid, _drawFocalMass);
        break;
      case CompositionMode.vArrangement:
        _drawOriented(canvas, grid, _drawVArrangement);
        break;
      case CompositionMode.diagonal:
        _drawDiagonal(canvas, grid);
        break;
      case CompositionMode.radial:
        _drawRadial(canvas, grid);
        break;
      case CompositionMode.lArrangement:
        _drawOriented(canvas, grid, _drawLArrangement);
        break;
      case CompositionMode.compoundCurve:
        _drawOriented(canvas, grid, _drawCompoundCurve);
        break;
      case CompositionMode.pyramid:
        _drawOriented(canvas, grid, _drawPyramid);
        break;
      case CompositionMode.circular:
        _drawCircular(canvas, grid);
        break;
      case CompositionMode.symmetry:
        _drawSymmetry(canvas, grid);
        break;
      case CompositionMode.aspectRatio:
        // The crop keeps its ratio's natural shape (16:9 wide, 4:5 tall) and
        // _drawOriented rotates it with the device: 16:9 is a wide letterbox in
        // portrait and a tall frame in landscape (dark bands rotate left/right).
        _drawOriented(canvas, grid, _drawAspectRatio);
        break;
    }

    // ── Target points (glow when a subject lands on them) ──────────────────────
    // Rule of Thirds uses the 1/3 intersections; Phi Grid uses the golden-
    // section intersections at 1/φ² ≈ 0.382 and 1/φ ≈ 0.618; Fibonacci Spiral
    // uses a single point — the spiral's eye.
    final List<List<double>>? pts = switch (mode) {
      CompositionMode.ruleOfThirds => const [
        [1 / 3, 1 / 3],
        [2 / 3, 1 / 3],
        [1 / 3, 2 / 3],
        [2 / 3, 2 / 3],
      ],
      CompositionMode.goldenSection => const [
        [0.3819660113, 0.3819660113],
        [0.6180339887, 0.3819660113],
        [0.3819660113, 0.6180339887],
        [0.6180339887, 0.6180339887],
      ],
      CompositionMode.fibonacciSpiral => () {
        final eye = _goldenSpiralEyePx(grid, spiralTurns, _goldenSpiralFill);
        return [
          [eye.dx / grid.width, eye.dy / grid.height],
        ];
      }(),
      _ => null,
    };
    if (pts != null) {
      const gold = kGold;
      // The spiral's single eye dips with the flip so its corner-to-corner jump
      // is hidden; grids never flip, so their dots are unaffected.
      final double markerDip = mode == CompositionMode.fibonacciSpiral
          ? _gridDip
          : 1.0;
      for (var i = 0; i < pts.length; i++) {
        final c = Offset(pts[i][0] * grid.width, pts[i][1] * grid.height);
        final g = (i < powerGlow.length ? powerGlow[i] : 0.0).clamp(0.0, 1.0);
        // Faint dot always; blooms into a soft glowing ring when aligned.
        canvas.drawCircle(
          c,
          2.0,
          Paint()
            ..color = gold.withValues(alpha: (0.25 + 0.55 * g) * markerDip),
        );
        if (g > 0.01) {
          canvas.drawCircle(
            c,
            6.0 + 10.0 * g,
            Paint()
              ..color = gold.withValues(alpha: 0.45 * g * markerDip)
              ..maskFilter = MaskFilter.blur(BlurStyle.normal, 4.0 + 6.0 * g),
          );
          canvas.drawCircle(
            c,
            5.0 + 4.0 * g,
            Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = 1.5
              ..color = gold.withValues(alpha: 0.8 * g * markerDip),
          );
        }
      }
    }
    canvas.restore();

    // ── Horizon Grid: a golden guide line marking the ideal horizon placement,
    // plus the live detected horizon that glows gold as it lands on the guide. ──
    if (mode == CompositionMode.horizonGrid) {
      const gold = kGold;
      final int turns = deviceTurns & 3;
      final double bandSpan = size.height - topInset - bottomInset;
      final Offset centre = Offset(size.width / 2, size.height / 2);

      // Screen-space unit vectors for the user's frame at this hold, derived from
      // the (verified) _userTopAlign mapping: turns 1 → the user's "up" is the
      // screen's LEFT edge, turns 3 → the RIGHT edge. So the whole grid pivots to
      // stay upright for the viewer, no matter how the phone is turned.
      final Offset userDown = switch (turns) {
        1 => const Offset(1, 0),
        2 => const Offset(0, -1),
        3 => const Offset(-1, 0),
        _ => const Offset(0, 1),
      };
      // The level line's along-direction (user's "right") = user-up rotated 90°.
      final Offset userRight = Offset(-userDown.dy, userDown.dx);
      final double baseAngle = math.atan2(userRight.dy, userRight.dx);
      final double labelRot = -turns * (math.pi / 2); // keep tags readable
      // Screen extent along the level line (width in portrait, height sideways).
      final double alongExtent =
          userRight.dx.abs() * size.width + userRight.dy.abs() * size.height;

      // Golden guide: signed distance from centre (along userDown), matching the
      // portrait placement exactly so detection (which reads the same ratio) and
      // the drawn line always agree.
      final double guideOff =
          topInset + bandSpan * _horizonGuideRatio - centre.dy;
      final Offset guideC = centre + userDown * guideOff;
      final Offset gspan = userRight * (size.longestSide);
      final Offset gA = guideC - gspan, gB = guideC + gspan;

      final hz = horizon?.value;
      final double aligned = hz?.aligned ?? 0;

      // Clip the whole grid to the camera-visible band so rotated/tilted lines
      // never bleed under the top/bottom chrome panels.
      final Rect bandRect = Rect.fromLTWH(0, topInset, size.width, bandSpan);
      canvas.save();
      canvas.clipRect(bandRect);

      // Guide line: dashed gold, always visible; blooms when aligned.
      if (aligned > 0.02) {
        canvas.drawLine(
          gA,
          gB,
          Paint()
            ..color = gold.withValues(alpha: 0.55 * aligned)
            ..strokeWidth = 4.0
            ..strokeCap = StrokeCap.round
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5.0),
        );
      }
      _drawDashedLine(
        canvas,
        gA,
        gB,
        Paint()
          ..color = gold.withValues(
            alpha: (0.42 + 0.5 * aligned).clamp(0.0, 1.0),
          )
          ..strokeWidth = 1.2
          ..strokeCap = StrokeCap.butt,
        dash: 9,
        gap: 7,
      );
      // Guide tag, toward one end so it never collides with the TRUE HORIZON tag.
      _drawHzLabel(
        canvas,
        'BEST SPOT',
        guideC + userRight * (alongExtent * 0.26) + userDown * -13,
        (0.72 + 0.28 * aligned).clamp(0.0, 1.0),
        rot: labelRot,
        keepWithin: bandRect.deflate(6),
      );

      // Detected horizon line (fades with op).
      if (hz != null && hz.op > 0.01) {
        final double op = hz.op;
        // Position: offset from centre along userDown by the pitch amount; the
        // stored angle is RELATIVE to the hold, so add the hold's base angle back
        // to get the true on-screen angle.
        final Offset c = centre + userDown * ((hz.ay - 0.5) * size.height);
        final double L = size.longestSide * 1.2;
        final double ang = baseAngle + hz.angle;
        final Offset dir = Offset(math.cos(ang), math.sin(ang));
        final p1 = c - dir * L;
        final p2 = c + dir * L;
        // Level cue: gold intensifies as the line approaches the hold's level.
        final level = (1 - (hz.angle.abs() / 0.20)).clamp(0.0, 1.0);
        canvas.drawLine(
          p1,
          p2,
          Paint()
            ..color = gold.withValues(alpha: (0.25 + 0.35 * level) * op)
            ..strokeWidth = 3.5
            ..strokeCap = StrokeCap.round
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4.0),
        );
        canvas.drawLine(
          p1,
          p2,
          Paint()
            ..color = gold.withValues(alpha: 0.85 * op)
            ..strokeWidth = 1.6
            ..strokeCap = StrokeCap.round
            ..isAntiAlias = true,
        );
        // Plain-English tag riding just above the line, toward the far end.
        _drawHzLabel(
          canvas,
          'TRUE HORIZON',
          c - dir * (alongExtent * 0.26) + userDown * -13,
          op,
          rot: labelRot,
          keepWithin: bandRect.deflate(6),
        );
      }
      canvas.restore();

      // Directional nudge: an animated arrow showing which way to move the phone
      // so the true horizon lands on the best-spot guide.
      if (hz != null) {
        _drawHzArrow(
          canvas,
          hz.dy,
          hz.op,
          userDown,
          Offset(size.width / 2, topInset + bandSpan / 2),
        );
      }
    }

    _paintFaceBoxes(canvas, size);
    _paintEyes(canvas, size); // gold rings on detected eyes (when populated)

    // (The "hold it level" dial lives in its own _LevelDialPainter layer so its
    // ~50 Hz gravity repaints don't redraw this whole overlay.)

    // Selective glow pass — redraw only the lines that have edge support,
    // using a gold blur paint so they illuminate without affecting other lines.
    if (glowSegs.isNotEmpty) {
      final glowPaint = Paint()
        ..strokeWidth = _sw + 2.5
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..isAntiAlias = true
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4.5);
      for (final seg in glowSegs) {
        if (seg.intensity <= 0) continue;
        glowPaint.color = const Color(
          0xFFE5C158,
        ).withValues(alpha: (0.65 * seg.intensity).clamp(0.0, 1.0));
        canvas.drawLine(
          Offset(seg.x1 * size.width, seg.y1 * size.height),
          Offset(seg.x2 * size.width, seg.y2 * size.height),
          glowPaint,
        );
      }
    }
  }

  /// A jewelled reticle on each detected eye: a fine gold ring set with four
  /// diagonal ticks (a jewel setting, deliberately not a crosshair), a
  /// champagne glint slowly circling the rim — light catching a turning bezel
  /// — and a breathing catchlight at the centre. Still cheap: no blurs or
  /// shaders, a handful of strokes per eye, because this runs on every repaint
  /// while a face is tracked. The breath/glint ride the continuous repaints.
  void _paintEyes(Canvas canvas, Size size) {
    if (eyePoints.isEmpty) return;
    final double t = DateTime.now().millisecondsSinceEpoch / 1000.0;
    // Slow, gentle breath (~0.4 Hz); the glint laps the rim every ~9s.
    final double breathe = 0.5 + 0.5 * math.sin(t * 2.4);
    final double glintPhase = t * 0.7;
    const double r = 4.2;

    final ring = Paint()
      ..color = kGold.withValues(alpha: 0.40 + 0.20 * breathe)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.1
      ..isAntiAlias = true;
    final glint = Paint()
      ..color = kGoldLit.withValues(alpha: 0.72 + 0.22 * breathe)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.3
      ..strokeCap = StrokeCap.round
      ..isAntiAlias = true;
    final tick = Paint()
      ..color = kGold.withValues(alpha: 0.55 + 0.25 * breathe)
      ..strokeWidth = 1.0
      ..strokeCap = StrokeCap.round
      ..isAntiAlias = true;
    final spark = Paint()
      ..color = kGoldLit.withValues(alpha: 0.45 + 0.40 * breathe);

    for (final e in eyePoints) {
      final Offset c = Offset(e.dx * size.width, e.dy * size.height);
      // Base ring.
      canvas.drawCircle(c, r, ring);
      // Champagne glint circling the rim.
      canvas.drawArc(
        Rect.fromCircle(center: c, radius: r),
        glintPhase,
        1.35, // ~77° of lit rim
        false,
        glint,
      );
      // Four diagonal setting-ticks around the ring.
      for (var i = 0; i < 4; i++) {
        final double a = math.pi / 4 + i * math.pi / 2;
        final Offset d = Offset(math.cos(a), math.sin(a));
        canvas.drawLine(c + d * (r + 1.6), c + d * (r + 3.4), tick);
      }
      // Centre catchlight — the sparkle in the eye.
      canvas.drawCircle(c, 1.0, spark);
    }
  }

  /// Full-screen face/animal corner brackets (camera AF style). Drawn on its own
  /// full-screen layer so boxes track faces anywhere, even over the UI panels.
  void _paintFaceBoxes(Canvas canvas, Size size) {
    for (final b in faceBoxes) {
      if (b.opacity <= 0.01) continue;
      // Subtle scale-in: start 8% smaller and settle to full size on appear.
      final scale = 0.92 + 0.08 * b.appear;
      final w = b.w * size.width * scale;
      final h = b.h * size.height * scale;
      final cx = b.cx * size.width;
      final cy = b.cy * size.height;
      final rect = Rect.fromCenter(center: Offset(cx, cy), width: w, height: h);

      final a = b.opacity.clamp(0.0, 1.0);
      final align = b.alignGlow.clamp(0.0, 1.0);
      const gold = kGold; // composition-text gold (aligned)
      const grid = Color(0xFFFFFFFF); // grid-line white (not aligned)
      final arm = (math.min(rect.width, rect.height) * 0.26).clamp(8.0, 26.0);
      final r = math.min(8.0, arm * 0.6);

      // colorT: 0 = grid white (no alignment), 1 = full gold (point inside box).
      // align ramps 0 → 0.45 ("Almost") → 1.0 ("Perfect"), so reaching ~0.45
      // already gives full gold; the glow keeps intensifying toward Perfect.
      final colorT = (align / 0.45).clamp(0.0, 1.0);
      final Color lineColor = Color.lerp(grid, gold, colorT)!;

      // Blurred glow is the expensive part — only for boxes on a point (align>0),
      // light for "Almost", heavy for "Perfect". Other faces are cheap strokes.
      if (align > 0.02) {
        final glow = Paint()
          ..color = gold.withValues(alpha: (0.18 + 0.5 * align) * a)
          ..strokeWidth = 4.0 + 4.0 * align
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, 2.5 + 4.0 * align);
        _corner(canvas, rect.topLeft, 1, 1, arm, r, glow);
        _corner(canvas, rect.topRight, -1, 1, arm, r, glow);
        _corner(canvas, rect.bottomRight, -1, -1, arm, r, glow);
        _corner(canvas, rect.bottomLeft, 1, -1, arm, r, glow);
      }

      // Thin grid-white when not aligned; thicker gold when on a point.
      final stroke = Paint()
        ..color = lineColor.withValues(alpha: (0.42 + 0.5 * colorT) * a)
        ..strokeWidth = 1.2 + 1.8 * align
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..isAntiAlias = true;
      _corner(canvas, rect.topLeft, 1, 1, arm, r, stroke);
      _corner(canvas, rect.topRight, -1, 1, arm, r, stroke);
      _corner(canvas, rect.bottomRight, -1, -1, arm, r, stroke);
      _corner(canvas, rect.bottomLeft, 1, -1, arm, r, stroke);
    }
  }

  /// Directional nudge arrow for Horizon Grid: a bobbing gold double-chevron
  /// pointing the way to move the phone so the true horizon meets the best-spot
  /// guide. [dy] is the signed true−guide offset (< 0 → nudge up). Fades in with
  /// the gap and out as the line nears the guide.
  void _drawHzArrow(
    Canvas canvas,
    double dy,
    double op,
    Offset userDown,
    Offset centre,
  ) {
    final double mag = dy.abs() - 0.02; // small dead-zone around the guide
    if (mag <= 0) return;
    final double aOp = (mag / 0.06).clamp(0.0, 1.0) * op;
    if (aOp <= 0.02) return;

    final bool up = dy < 0; // true horizon above the guide → nudge phone up
    // Gentle bob in the pointing direction (the painter repaints ~60fps here).
    final double t = DateTime.now().millisecondsSinceEpoch / 1000.0;
    final double bob = (math.sin(t * 4.0) * 0.5 + 0.5) * 6.0 * (up ? -1 : 1);

    const double w = 30, h = 12, gap = 12;
    final glow = Paint()
      ..color = kGold.withValues(alpha: 0.45 * aOp)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 7
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5);
    final stroke = Paint()
      ..color = kGold.withValues(alpha: 0.95 * aOp)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.5
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    void chevron(double yc) {
      final double apexY = up ? yc - h / 2 : yc + h / 2;
      final double endY = up ? yc + h / 2 : yc - h / 2;
      final path = Path()
        ..moveTo(-w / 2, endY)
        ..lineTo(0, apexY)
        ..lineTo(w / 2, endY);
      canvas.drawPath(path, glow);
      canvas.drawPath(path, stroke);
    }

    // Rotate the frame so screen-down maps onto the user's "down" for this hold,
    // then draw the (vertical) chevrons — they point along the user's up/down.
    canvas.save();
    canvas.translate(centre.dx, centre.dy);
    canvas.rotate(math.atan2(userDown.dy, userDown.dx) - math.pi / 2);
    // Two stacked chevrons → a clear directional "move" cue.
    chevron(bob - gap / 2);
    chevron(bob + gap / 2);
    canvas.restore();
  }

  /// Small frosted gold pill label riding the horizon line. Fades with [op].
  /// [rot] rotates the pill so its text stays upright for the current hold.
  void _drawHzLabel(
    Canvas canvas,
    String text,
    Offset center,
    double op, {
    double rot = 0,
    Rect? keepWithin,
  }) {
    if (op <= 0.02) return;
    const gold = kGold;
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: gold.withValues(alpha: (0.95 * op).clamp(0.0, 1.0)),
          fontSize: 9.5,
          fontWeight: FontWeight.w600,
          letterSpacing: 1.8,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    // Keep the pill fully inside [keepWithin] (the camera band): in landscape
    // the tag is rotated a quarter-turn, so its on-screen footprint runs
    // VERTICALLY and a spot along the line can land under the chrome panels —
    // where the band clip would slice it. Quarter-turn rotations just swap the
    // pill's on-screen extents.
    if (keepWithin != null) {
      final double pw = tp.width + 18, ph = tp.height + 9;
      final bool quarter = (rot / (math.pi / 2)).round().isOdd;
      final double hx = (quarter ? ph : pw) / 2;
      final double hy = (quarter ? pw : ph) / 2;
      center = Offset(
        center.dx.clamp(keepWithin.left + hx, keepWithin.right - hx),
        center.dy.clamp(keepWithin.top + hy, keepWithin.bottom - hy),
      );
    }
    // Rotate the pill about its centre so the tag reads upright for the hold.
    canvas.save();
    canvas.translate(center.dx, center.dy);
    canvas.rotate(rot);
    canvas.translate(-center.dx, -center.dy);
    final Rect r = Rect.fromCenter(
      center: center,
      width: tp.width + 18,
      height: tp.height + 9,
    );
    final RRect pill = RRect.fromRectAndRadius(r, const Radius.circular(20));
    canvas.drawRRect(
      pill,
      Paint()
        ..color = const Color(
          0xFF000000,
        ).withValues(alpha: (0.34 * op).clamp(0.0, 1.0)),
    );
    canvas.drawRRect(
      pill,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.8
        ..color = gold.withValues(alpha: (0.4 * op).clamp(0.0, 1.0)),
    );
    tp.paint(
      canvas,
      Offset(r.center.dx - tp.width / 2, r.center.dy - tp.height / 2),
    );
    canvas.restore();
  }

  /// Draws a dashed line from [a] to [b] (used by the Horizon Grid guide line).
  void _drawDashedLine(
    Canvas canvas,
    Offset a,
    Offset b,
    Paint paint, {
    double dash = 8,
    double gap = 6,
  }) {
    final double total = (b - a).distance;
    if (total <= 0) return;
    final Offset dir = (b - a) / total;
    double d = 0;
    while (d < total) {
      final double end = math.min(d + dash, total);
      canvas.drawLine(a + dir * d, a + dir * end, paint);
      d = end + gap;
    }
  }

  /// Draws [draw] rotated to follow the current device hold, so orientation-aware
  /// compositions (Pyramid, V / L-Arrangement, Focal Mass, Compound Curve, Aspect
  /// Ratio) stay upright — and correctly proportioned — for the user's view when
  /// the phone is turned to landscape, instead of staying locked to portrait. For
  /// odd turns the frame is swapped (w↔h) so the composition is designed for the
  /// landscape aspect the user actually sees. Portrait (turns 0) is a fast path.
  void _drawOriented(
    Canvas canvas,
    Size grid,
    void Function(Canvas, Size) draw,
  ) {
    final int q = (-deviceTurns) & 3; // quarter-turns that keep content upright
    if (q == 0) {
      draw(canvas, grid);
      return;
    }
    canvas.save();
    canvas.translate(grid.width / 2, grid.height / 2);
    canvas.rotate(q * (math.pi / 2));
    final Size s2 = q.isOdd ? Size(grid.height, grid.width) : grid;
    canvas.translate(-s2.width / 2, -s2.height / 2);
    draw(canvas, s2);
    canvas.restore();
  }

  // ── Rule of Thirds ──────────────────────────────────────────────────────────
  // Two equally spaced verticals + two equally spaced horizontals → 9 equal cells.
  // StrokeCap.butt ensures lines stay strictly within the frame boundaries.
  void _drawRuleOfThirds(Canvas canvas, Size s) {
    final p = _gp();

    final double col1 = s.width / 3;
    final double col2 = s.width * 2 / 3;
    final double row1 = s.height / 3;
    final double row2 = s.height * 2 / 3;

    // Vertical lines — from top edge to bottom edge
    canvas.drawLine(Offset(col1, 0), Offset(col1, s.height), p);
    canvas.drawLine(Offset(col2, 0), Offset(col2, s.height), p);

    // Horizontal lines — from left edge to right edge
    canvas.drawLine(Offset(0, row1), Offset(s.width, row1), p);
    canvas.drawLine(Offset(0, row2), Offset(s.width, row2), p);
  }

  // ── Golden Section ──────────────────────────────────────────────────────────
  // Divides width and height by the golden ratio φ ≈ 1.618.
  // Each dimension is split at (1/φ) ≈ 0.618 from one edge
  // and at (1/φ²) ≈ 0.382 from the other, giving two lines per axis.
  void _drawGoldenSection(Canvas canvas, Size s) {
    final p = _gp();

    const double phi = 1.6180339887;
    // Smaller division: 1/φ² ≈ 0.382 from one edge
    // Larger division: 1/φ  ≈ 0.618 from the same edge (= 1 − 0.382)
    final double wSmall = s.width / (phi * phi); // ≈ 0.382 × W
    final double wLarge = s.width / phi; // ≈ 0.618 × W
    final double hSmall = s.height / (phi * phi);
    final double hLarge = s.height / phi;

    // Vertical lines — span full height, flush to top and bottom edges
    canvas.drawLine(Offset(wSmall, 0), Offset(wSmall, s.height), p);
    canvas.drawLine(Offset(wLarge, 0), Offset(wLarge, s.height), p);

    // Horizontal lines — span full width, flush to left and right edges
    canvas.drawLine(Offset(0, hSmall), Offset(s.width, hSmall), p);
    canvas.drawLine(Offset(0, hLarge), Offset(s.width, hLarge), p);
  }

  // ── Golden Triangles ────────────────────────────────────────────────────────
  // One main diagonal (TL→BR) plus a perpendicular dropped from each of the
  // two remaining corners (TR and BL) onto that diagonal.
  // Result: 3 unique lines, 4 non-overlapping triangles, all within the frame.
  void _drawGoldenTriangles(Canvas canvas, Size s) {
    final p = _gp()..color = _gold.withValues(alpha: 0.45 * _gridDip);

    final double w = s.width;
    final double h = s.height;
    final double d2 = w * w + h * h; // |diagonal|²

    // 1. Main diagonal: top-left → bottom-right
    canvas.drawLine(Offset(0, 0), Offset(w, h), p);

    // 2. Perpendicular from top-right corner (w, 0) to main diagonal
    //    Foot: t = (w·w + 0·h) / d2
    final double t2 = (w * w) / d2;
    canvas.drawLine(Offset(w, 0), Offset(t2 * w, t2 * h), p);

    // 3. Perpendicular from bottom-left corner (0, h) to main diagonal
    //    Foot: t = (0·w + h·h) / d2
    final double t3 = (h * h) / d2;
    canvas.drawLine(Offset(0, h), Offset(t3 * w, t3 * h), p);
  }

  // ── Golden Spiral ───────────────────────────────────────────────────────────
  void _drawGoldenSpiral(Canvas canvas, Size s) {
    final double dip = _gridDip;
    final p = _p..color = _gold.withValues(alpha: 0.45 * dip);
    const double phi = 1.6180339887;

    // 90°-per-step rotation lets the user aim the spiral's eye at any corner.
    // Odd steps stand the spiral on its long edge, so we fit the golden rectangle
    // into a frame with width/height swapped, then rotate the whole drawing about
    // the band centre to drop it back into place (still fitting the band).
    final int turns = spiralTurns & 3;
    final bool swap = turns.isOdd;
    final double fw = swap ? s.height : s.width;
    final double fh = swap ? s.width : s.height;

    // Largest *landscape* golden rectangle (φ:1, wider than tall) that fits the
    // (possibly swapped) frame, centred — the classic golden-spiral framing.
    final double maxW = fw * _goldenSpiralFill;
    final double maxH = fh * _goldenSpiralFill;
    double w = maxW;
    double h = w / phi;
    if (h > maxH) {
      h = maxH;
      w = h * phi;
    }
    Rect rect = Rect.fromLTWH((fw - w) / 2, (fh - h) / 2, w, h);

    canvas.save();
    // Rotate the drawing frame about the band centre; the (fw × fh) frame is
    // centred there so the rotated rectangle lands back inside the band.
    canvas.translate(s.width / 2, s.height / 2);
    if (spiralFlipped) canvas.scale(-1.0, 1.0); // mirror eye to opposite side
    canvas.rotate(turns * (math.pi / 2));
    canvas.translate(-fw / 2, -fh / 2);

    // Outer rectangle border intentionally NOT drawn — it left stray edge lines
    // (left/right in portrait, top/bottom in landscape). The spiral keeps its
    // 1.0× size; only the inner golden-section dividers + the arc are drawn.

    // Start by cutting the right square so the spiral winds inward toward the
    // left, the eye settling near the lower-left golden-section point.
    int dir = 0;
    final path = Path();
    bool isFirst = true;

    // Cut squares, drawing the golden-section dividing line for each (the lines
    // overlaid in the reference) plus a continuous quarter-arc through it. 12
    // iterations reach the sub-pixel "eye".
    for (int i = 0; i < 12; i++) {
      final double sqSize = math.min(rect.width, rect.height);
      Offset center;
      double startAngle;
      const double sweepAngle = math.pi / 2;

      if (dir == 0) {
        // Cut Right Square — divider is its left edge (vertical, full height).
        center = Offset(rect.right - sqSize, rect.top);
        startAngle = 0;
        canvas.drawLine(
          Offset(rect.right - sqSize, rect.top),
          Offset(rect.right - sqSize, rect.bottom),
          p,
        );
        rect = Rect.fromLTRB(
          rect.left,
          rect.top,
          rect.right - sqSize,
          rect.bottom,
        );
      } else if (dir == 1) {
        // Cut Bottom Square — divider is its top edge (horizontal, full width).
        center = Offset(rect.right, rect.bottom - sqSize);
        startAngle = math.pi / 2;
        canvas.drawLine(
          Offset(rect.left, rect.bottom - sqSize),
          Offset(rect.right, rect.bottom - sqSize),
          p,
        );
        rect = Rect.fromLTRB(
          rect.left,
          rect.top,
          rect.right,
          rect.bottom - sqSize,
        );
      } else if (dir == 2) {
        // Cut Left Square — divider is its right edge (vertical, full height).
        center = Offset(rect.left + sqSize, rect.bottom);
        startAngle = math.pi;
        canvas.drawLine(
          Offset(rect.left + sqSize, rect.top),
          Offset(rect.left + sqSize, rect.bottom),
          p,
        );
        rect = Rect.fromLTRB(
          rect.left + sqSize,
          rect.top,
          rect.right,
          rect.bottom,
        );
      } else {
        // Cut Top Square — divider is its bottom edge (horizontal, full width).
        center = Offset(rect.left, rect.top + sqSize);
        startAngle = -math.pi / 2;
        canvas.drawLine(
          Offset(rect.left, rect.top + sqSize),
          Offset(rect.right, rect.top + sqSize),
          p,
        );
        rect = Rect.fromLTRB(
          rect.left,
          rect.top + sqSize,
          rect.right,
          rect.bottom,
        );
      }

      final arcRect = Rect.fromCircle(center: center, radius: sqSize);
      path.arcTo(arcRect, startAngle, sweepAngle, isFirst);
      isFirst = false;
      dir = (dir + 1) % 4;
    }

    canvas.drawPath(path, p);
    canvas.restore();
  }

  // ── Cross ───────────────────────────────────────────────────────────────────
  void _drawCross(Canvas canvas, Size s) {
    final p = _p;
    // Live rendered state from the easing ticker (default when warming up).
    final c = cross?.value ?? (y: kCrossDefaultY, angle: 0.0, glow: 0.0);

    // Christian cross — centered horizontally. The vertical arm is a FIXED
    // track; the user slides the crossbar up/down within it (c.y).
    final double cx = s.width * 0.50;
    final double top = s.height * kCrossTopFrac;
    final double bottom = s.height * kCrossBottomFrac;
    final double cy = (s.height * c.y).clamp(top, bottom);

    // Horizontal crossbar: symmetric, does not reach screen edges.
    final double armLeft = s.width * 0.18;
    final double armRight = s.width * 0.18;

    // Hold-to-rotate spins the whole cross about the vertical arm's centre.
    final double pivotY = (top + bottom) / 2;
    canvas.save();
    if (c.angle != 0) {
      canvas.translate(cx, pivotY);
      canvas.rotate(c.angle);
      canvas.translate(-cx, -pivotY);
    }
    final Offset vTop = Offset(cx, top);
    final Offset vBottom = Offset(cx, bottom);
    final Offset hLeft = Offset(cx - armLeft, cy);
    final Offset hRight = Offset(cx + armRight, cy);

    // Selection glow: two soft, blurred gold halos that fade outward — a gentle
    // bloom rather than a hard outline. Only active briefly while held.
    if (c.glow > 0.01) {
      for (final layer in const [
        (width: 13.0, alpha: 0.16, blur: 9.0),
        (width: 5.0, alpha: 0.38, blur: 4.0),
      ]) {
        final bloom = Paint()
          ..color = _gold.withValues(alpha: layer.alpha * c.glow)
          ..strokeWidth = _sw + layer.width * c.glow
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, layer.blur);
        canvas.drawLine(vTop, vBottom, bloom);
        canvas.drawLine(hLeft, hRight, bloom);
      }
    }

    // Vertical line (fixed track) + horizontal crossbar (slides within it).
    canvas.drawLine(vTop, vBottom, p);
    canvas.drawLine(hLeft, hRight, p);
    canvas.restore();
  }

  // ── Focal Mass ──────────────────────────────────────────────────────────────
  // Scattered dot cluster in the upper-center (like reference image)
  void _drawFocalMass(Canvas canvas, Size s) {
    // Each tap turns the cluster 90° about the band centre, fading out + back in
    // through the shared grid-flip dip so the swap is hidden.
    final double dip = _gridDip;

    // Spotlight the cluster: dim the rest, keeping the subject area in focus.
    // Focal Mass repaints every frame (drifting bubbles), so use the cheap
    // radial-gradient scrim (no layer/blur) at the rotated cluster centre.
    final double a = (focalTurns & 3) * (math.pi / 2);
    final double vx = s.width * 0.33 - s.width / 2;
    final double vy = s.height * 0.50 - s.height / 2;
    final Offset fc = Offset(
      s.width / 2 + vx * math.cos(a) - vy * math.sin(a),
      s.height / 2 + vx * math.sin(a) + vy * math.cos(a),
    );
    _drawRadialScrim(canvas, s, fc, s.width * 0.40, dip);

    canvas.save();
    canvas.translate(s.width / 2, s.height / 2);
    canvas.rotate((focalTurns & 3) * (math.pi / 2));
    canvas.translate(-s.width / 2, -s.height / 2);

    // Left-of-centre cluster. The dot layout is computed ONCE (_focalDots) — no
    // per-frame maths — and only the big dots animate, so this stays cheap.
    final double cx = s.width * 0.33;
    final double cy = s.height * 0.50;
    // Scale the cluster by the frame width (vs a 390pt reference) so it occupies
    // the SAME proportion on every iPhone, from SE to Pro Max. The cache stays in
    // reference px; offsets, radii and drift are scaled here at draw time.
    final double k = s.width / 390.0;
    final double t = DateTime.now().millisecondsSinceEpoch / 1000.0;
    final dot = Paint()..style = PaintingStyle.fill;
    final glow = Paint()..style = PaintingStyle.fill;

    for (final d in _focalDots) {
      // Every bubble drifts on its own pattern + speed; brighter ones glow more.
      final double fx = math.sin(t * d.speed + d.phase) * d.driftX;
      final double fy = math.cos(t * d.speed * 0.85 + d.phase * 1.3) * d.driftY;
      final double pulse = 0.5 + 0.5 * math.sin(t * d.speed * 1.5 + d.phase);
      final Offset p = Offset(cx + (d.dx + fx) * k, cy + (d.dy + fy) * k);
      if (d.glow > 0.02) {
        // Slight soft halo (no blur — cheap), gently breathing.
        glow.color = _gold.withValues(
          alpha: d.glow * (0.45 + 0.4 * pulse) * dip,
        );
        canvas.drawCircle(p, d.r * 2.8 * k, glow);
      }
      dot.color = _gold.withValues(alpha: d.a * (0.75 + 0.25 * pulse) * dip);
      canvas.drawCircle(p, d.r * k, dot);
    }
    canvas.restore();
  }

  // ── V Arrangement ───────────────────────────────────────────────────────────
  // V shape opening upward, vertex at bottom-center
  void _drawVArrangement(Canvas canvas, Size s) {
    // Fade through the shared flip dip so the upside-down swap is hidden.
    final double dip = _gridDip;
    final p = _p..color = _gold.withValues(alpha: 0.45 * dip);

    // Vertex at lower-center; arms rise symmetrically to the upper corners
    // of a contained region — fully visible, no clipping at edges.
    final double vx = s.width * 0.50; // horizontal center
    final double vy = s.height * 0.78; // vertex near bottom

    // Arm endpoints — symmetric, inset from frame edges.
    final double topY = s.height * 0.12;
    final double topLeftX = s.width * 0.08;
    final double topRightX = s.width * 0.92;

    // Flip button turns the V upside-down (V ↔ ∧), mirrored about its centre.
    final double midY = (topY + vy) / 2;
    canvas.save();
    if (vFlipped) {
      canvas.translate(0, midY);
      canvas.scale(1, -1);
      canvas.translate(0, -midY);
    }
    // Left arm: vertex → upper-left
    canvas.drawLine(Offset(vx, vy), Offset(topLeftX, topY), p);
    // Right arm: vertex → upper-right (mirror)
    canvas.drawLine(Offset(vx, vy), Offset(topRightX, topY), p);
    canvas.restore();
  }

  // ── Diagonal ────────────────────────────────────────────────────────────────
  // A strong diagonal springing from one corner, with two helper lines fanning
  // to ~85px apart near the opposite corner. The turn button cycles the corner.
  void _drawDiagonal(Canvas canvas, Size s) {
    final double dip = _gridDip;
    final p = _p..color = _gold.withValues(alpha: 0.45 * dip);

    // Offsets as fractions so the helpers stay ~85px apart near the far corner.
    final double ox = 85 / s.width;
    final double oy = 85 / s.height;

    // Turn 0 (normalised, unit square): fan from the top-right corner toward BL.
    const Offset origin = Offset(1, 0); // top-right
    final Offset end1 = Offset(0, 1 - oy); // left edge, above BL
    final Offset end2 = Offset(ox, 1); // bottom edge, right of BL

    // Rotate the whole config 90°·turns about the centre — in the unit square so
    // corners map to corners — then scale to the frame.
    final int turns = diagonalTurns & 3;
    Offset place(Offset q) {
      double x = q.dx - 0.5, y = q.dy - 0.5;
      for (int i = 0; i < turns; i++) {
        final double nx = -y, ny = x; // 90° clockwise (screen space)
        x = nx;
        y = ny;
      }
      return Offset((x + 0.5) * s.width, (y + 0.5) * s.height);
    }

    final Offset o = place(origin);
    canvas.drawLine(o, place(end1), p);
    canvas.drawLine(o, place(end2), p);
  }

  // ── Radial ──────────────────────────────────────────────────────────────────
  // Lines radiating from center like a star
  void _drawRadial(Canvas canvas, Size s) {
    final p = _p;
    final Offset center = Offset(s.width / 2, s.height / 2);

    // Fixed arm length: 40% of the shorter screen dimension so all 8 lines
    // are equal length, stay well clear of the edges, and never overlap.
    final double armLength = math.min(s.width, s.height) * 0.40;

    // 8 lines = 16 arms evenly spaced at 360°/8 = 45° apart.
    const int count = 8;
    for (int i = 0; i < count; i++) {
      final double angle = i * 2 * math.pi / count;
      final double cos = math.cos(angle);
      final double sin = math.sin(angle);
      canvas.drawLine(
        Offset(center.dx - cos * armLength, center.dy - sin * armLength),
        Offset(center.dx + cos * armLength, center.dy + sin * armLength),
        p,
      );
    }
  }

  // ── L Arrangement ───────────────────────────────────────────────────────────
  void _drawLArrangement(Canvas canvas, Size s) {
    final double dip = _gridDip;
    final p = _p..color = _gold.withValues(alpha: 0.45 * dip);

    // Normalised (turn 0, unflipped): corner low-left, vertical bar rising, foot
    // across the bottom to the right — a standard "L" by default. Flip mirrors
    // it; turns cycle the corner.
    const Offset corner = Offset(0.32, 0.80);
    const Offset vEnd = Offset(0.32, 0.18);
    const Offset hEnd = Offset(0.80, 0.80);

    final int turns = lTurns & 3;
    Offset place(Offset q) {
      double x = lFlipped ? 1 - q.dx : q.dx; // mirror horizontally first
      double y = q.dy;
      x -= 0.5;
      y -= 0.5;
      for (int i = 0; i < turns; i++) {
        final double nx = -y, ny = x; // 90° clockwise (screen space)
        x = nx;
        y = ny;
      }
      return Offset((x + 0.5) * s.width, (y + 0.5) * s.height);
    }

    final Offset c = place(corner);
    canvas.drawLine(c, place(vEnd), p);
    canvas.drawLine(c, place(hEnd), p);
  }

  // ── Compound Curve ──────────────────────────────────────────────────────────
  // S-curve through center using two cubic bezier segments
  void _drawCompoundCurve(Canvas canvas, Size s) {
    final p = _p;
    final path = Path();

    // S-curve flowing top→bottom across the full frame height (portrait).
    // Start: top edge at horizontal center.
    // End:   bottom edge at horizontal center.
    // Two cubic segments share a smooth join at the frame center,
    // with control points that pull each half in opposite horizontal
    // directions to form a balanced vertical S.
    //
    //  Top half:    bows right (CP1 right-upper, CP2 right-lower of center)
    //  Bottom half: bows left  (CP1 left-upper,  CP2 left-lower  of center)

    final double cx = s.width * 0.50;
    final double cy = s.height * 0.50;
    final double bow = s.width * 0.28; // horizontal amplitude of each arc

    // Segment 1: top-edge mid → frame center
    path.moveTo(cx, 0);
    path.cubicTo(
      cx + bow,
      s.height * 0.20, // CP1 — bows right
      cx + bow,
      s.height * 0.40, // CP2 — stays right before center
      cx,
      cy, // end at frame center
    );

    // Segment 2: frame center → bottom-edge mid (mirrors segment 1)
    path.cubicTo(
      cx - bow,
      s.height * 0.60, // CP1 — bows left
      cx - bow,
      s.height * 0.80, // CP2 — stays left before bottom
      cx,
      s.height, // end at bottom-edge mid
    );

    canvas.drawPath(path, p);
  }

  // ── Pyramid ─────────────────────────────────────────────────────────────────
  void _drawPyramid(Canvas canvas, Size s) {
    final p = _p;
    final Offset apex = Offset(s.width * 0.5, s.height * 0.22);
    final Offset baseL = Offset(s.width * 0.12, s.height * 0.80);
    final Offset baseR = Offset(s.width * 0.88, s.height * 0.80);
    final path = Path()
      ..moveTo(apex.dx, apex.dy)
      ..lineTo(baseL.dx, baseL.dy)
      ..lineTo(baseR.dx, baseR.dy)
      ..close();
    _drawFocusScrim(canvas, s, path); // dim outside, keep the pyramid in focus
    canvas.drawPath(path, p);
  }

  // ── Circular ────────────────────────────────────────────────────────────────
  void _drawCircular(Canvas canvas, Size s) {
    final p = _p;
    final Offset center = Offset(s.width / 2, s.height / 2);
    final double radius = math.min(s.width, s.height) * 0.36;
    final path = Path()
      ..addOval(Rect.fromCircle(center: center, radius: radius));
    _drawFocusScrim(canvas, s, path); // dim outside, keep the circle in focus
    canvas.drawCircle(center, radius, p);
  }

  /// "Spotlight" the inside of [shape]: darken the rest of the band and punch a
  /// soft, blurred hole over the shape so the subject inside reads as focused
  /// and the surroundings fade out. One cached masked layer — Pyramid/Circular
  /// don't animate, so the live preview just composites under it each frame.
  void _drawFocusScrim(Canvas canvas, Size s, Path shape) {
    final Rect band = Offset.zero & s;
    canvas.saveLayer(band, Paint());
    canvas.drawRect(band, Paint()..color = const Color(0x80000000)); // ~50% dim
    canvas.drawPath(
      shape,
      Paint()
        ..color = const Color(0xFF000000)
        ..blendMode = BlendMode
            .dstOut // erase the scrim inside the shape
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, s.width * 0.06),
    );
    canvas.restore();
  }

  /// Cheap radial "spotlight" — a single gradient fill (no layer/mask), for modes
  /// that repaint every frame (Focal Mass): clear at [center], fading to ~50%
  /// dark by [radius]. [opacity] scales the dim (e.g. with the flip dip).
  void _drawRadialScrim(
    Canvas canvas,
    Size s,
    Offset center,
    double radius,
    double opacity,
  ) {
    if (opacity <= 0.01) return;
    final int alpha = (0x80 * opacity).round().clamp(0, 255);
    final shader = RadialGradient(
      colors: [const Color(0x00000000), Color(alpha << 24)],
      stops: const [0.5, 1.0],
    ).createShader(Rect.fromCircle(center: center, radius: radius));
    canvas.drawRect(Offset.zero & s, Paint()..shader = shader);
  }

  // ── Symmetry ──────────────────────────────────────────────────────────────
  // A single crisp vertical mirror axis down the centre (with a faint horizontal
  // for reference). Place the subject on the line so the two halves balance.
  void _drawSymmetry(Canvas canvas, Size s) {
    final p = _p;
    final double cx = s.width / 2;
    // Vertical mirror axis — full height, the primary guide.
    canvas.drawLine(Offset(cx, 0), Offset(cx, s.height), p);
    // Faint horizontal reference at the vertical centre.
    final faint = Paint()
      ..color = _gold.withValues(alpha: 0.18)
      ..strokeWidth = _sw
      ..style = PaintingStyle.stroke
      ..isAntiAlias = true;
    canvas.drawLine(
      Offset(0, s.height / 2),
      Offset(s.width, s.height / 2),
      faint,
    );
  }

  // ── Aspect Ratio ────────────────────────────────────────────────────────────
  // Crop framing guide for the selected ratio ([aspect] = W/H). Draws the largest
  // crop of that ratio centred in the band and dims everything outside it, so the
  // user can frame for 1:1 / 4:5 / 16:9 social or print output.
  void _drawAspectRatio(Canvas canvas, Size s) {
    // The largest crop of the selected ratio, centred in the frame [s], which
    // _drawOriented has already rotated to the device hold. In a landscape hold
    // the ratio is oriented to the frame the user sees, so a portrait ratio (4:5)
    // is drawn as its landscape form (5:4) — reading widescreen like 16:9 instead
    // of a tall sliver with fat side bars. 16:9 (already wide) and 1:1 are
    // unaffected, and a portrait hold keeps every ratio as authored.
    double r = aspect <= 0 ? 1.0 : aspect;
    if (deviceTurns.isOdd && r < 1) r = 1 / r;
    double w, h;
    if (s.width / s.height > r) {
      // Height-limited: the crop is narrower than the view (1:1 / 5:4 in a
      // landscape hold), so a full-height crop would dim ONLY the side pillars.
      // Inset it into a floating window instead — the dim then frames the crop
      // on all four sides, giving the top/bottom letterbox strips that 16:9
      // shows, while the ratio stays true. Width-limited crops (16:9 here, and
      // every ratio in portrait) are untouched: full width, top/bottom bars.
      h = s.height * _kAspectWindowFrac;
      w = h * r;
    } else {
      w = s.width;
      h = w / r;
    }
    final Rect crop = Rect.fromCenter(
      center: Offset(s.width / 2, s.height / 2),
      width: w,
      height: h,
    );

    // Dim outside the crop using an even-odd path (band rect with the crop as a
    // hole).
    final dim = Path()
      ..addRect(Rect.fromLTWH(0, 0, s.width, s.height))
      ..addRect(crop)
      ..fillType = PathFillType.evenOdd;
    canvas.drawPath(dim, Paint()..color = Colors.black.withValues(alpha: 0.38));

    // Crop border.
    canvas.drawRect(crop, _gp());
  }

  @override
  bool shouldRepaint(_CompositionPainter old) =>
      old.mode != mode ||
      old.glowSegs != glowSegs ||
      old.faceBoxes != faceBoxes ||
      old.topInset != topInset ||
      old.bottomInset != bottomInset ||
      old.spiralTurns != spiralTurns ||
      old.spiralFlipped != spiralFlipped ||
      old.focalTurns != focalTurns ||
      old.diagonalTurns != diagonalTurns ||
      old.lTurns != lTurns ||
      old.lFlipped != lFlipped ||
      old.trianglesFlipped != trianglesFlipped ||
      old.vFlipped != vFlipped ||
      old.aspect != aspect ||
      old.deviceTurns != deviceTurns ||
      old.eyePoints != eyePoints;
}
