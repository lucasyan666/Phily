part of 'camera_page.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Composition guide sheet
//
// A frosted reference card for one composition mode: the mode's own painter
// draws a staged diagram (the same canned-state trick as the launch warm-up),
// followed by BEST FOR / HOW TO USE IT / WHAT IT IS copy from the registry.
// Opened by long-pressing a mode on the belt, or tapping the "Best for" bubble.
// Lives in the camera_page library so it can use _CompositionPainter directly.
// ─────────────────────────────────────────────────────────────────────────────

/// Present the guide sheet for [mode]. No-op for [CompositionMode.none].
Future<void> showCompositionGuide(BuildContext context, CompositionMode mode) {
  if (mode == CompositionMode.none) return Future.value();
  hapticTap();
  // Fades up in place rather than sliding in from the bottom edge. The guide
  // is a reference card about the frame you are already looking at, so it
  // should arrive *over* the shot, not travel across it — a slide-up drags the
  // eye down and away from the composition being explained.
  final bool still = reduceMotionOf(context);
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Dismiss guide',
    barrierColor: Colors.black.withValues(alpha: 0.56),
    transitionDuration: still
        ? Duration.zero
        : const Duration(milliseconds: 260),
    pageBuilder: (_, _, _) =>
        _CompositionGuideSheet(spec: kCompositionByMode[mode]!),
    transitionBuilder: (context, anim, _, child) {
      final curved = CurvedAnimation(
        parent: anim,
        curve: Curves.easeOutCubic,
        reverseCurve: Curves.easeInCubic,
      );
      return FadeTransition(
        opacity: curved,
        // A whisper of scale so it *settles* into place instead of blinking
        // on — the app's one arrival gesture, same easing as the belt.
        child: still
            ? child
            : ScaleTransition(
                scale: Tween<double>(begin: 0.96, end: 1.0).animate(curved),
                child: child,
              ),
      );
    },
  );
}

class _CompositionGuideSheet extends StatefulWidget {
  final CompositionSpec spec;
  const _CompositionGuideSheet({required this.spec});

  @override
  State<_CompositionGuideSheet> createState() => _CompositionGuideSheetState();
}

class _CompositionGuideSheetState extends State<_CompositionGuideSheet>
    with SingleTickerProviderStateMixin {
  /// Draws the guide on once as the card settles. Slow enough to follow the
  /// line with your eye, short enough that it never delays reading the copy.
  late final AnimationController _draw = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  );

  CompositionSpec get spec => widget.spec;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Instant under Reduce Motion: the diagram is information, so it must be
    // complete either way — only the drawing-on is motion.
    if (reduceMotionOf(context)) {
      _draw.value = 1.0;
    } else if (!_draw.isAnimating && _draw.value == 0.0) {
      // A beat after the card's own fade, so the two don't compete.
      Future<void>.delayed(const Duration(milliseconds: 140), () {
        if (mounted) _draw.forward();
      });
    }
  }

  @override
  void dispose() {
    _draw.dispose();
    super.dispose();
  }

  /// Staged demo face for the detection modes — locked onto the top-left power
  /// point, glowing, exactly as it looks live when a shot lines up.
  static final _FaceBox _demoFace = _FaceBox(1 / 3, 1 / 3, 0.3, 0.36, 0)
    ..opacity = 1.0
    ..appear = 1.0
    ..matched = true
    ..perfect = true
    ..alignGlow = 1.0;

  /// How much heavier the guide is drawn here than on the live viewfinder.
  ///
  /// The camera keeps its guide quiet on purpose — it is a hint over a moving
  /// subject. This sheet is the opposite: a still photograph the reader opened
  /// *to study the guide*, often a bright one (sky, pale tabletop), where the
  /// viewfinder's 0.45 alpha at 0.8pt all but disappears. See
  /// [_CompositionPainter.emphasis].
  static const double _kSheetEmphasis = 2.6;

  /// Widest the card may get. A reference card is a column of prose; on a
  /// phone held landscape an uncapped card ran 816pt wide — line lengths no
  /// one reads comfortably, and it swallowed the frame it is explaining.
  static const double _kCardMaxW = 460;

  /// The mode's overlay painter with staged state, so the diagram shows the
  /// guide mid-use rather than bare lines.
  CustomPainter _diagramPainter(double reveal) {
    switch (spec.mode) {
      case CompositionMode.ruleOfThirds:
        return _CompositionPainter(
          spec.mode,
          faceBoxes: [_demoFace],
          powerGlow: const [1.0, 0.25, 0.25, 0.25],
          emphasis: _kSheetEmphasis,
          reveal: reveal,
        );
      case CompositionMode.goldenSection:
        // First phi point glows — the scene stands its figure there.
        return _CompositionPainter(
          spec.mode,
          powerGlow: const [1.0, 0.25, 0.25, 0.25],
          emphasis: _kSheetEmphasis,
          reveal: reveal,
        );
      case CompositionMode.horizonGrid:
        // A slightly-tilted true horizon approaching the gold guide.
        return _CompositionPainter(
          spec.mode,
          horizon: ValueNotifier((
            angle: 0.05,
            ax: 0.5,
            ay: 0.55,
            op: 1.0,
            aligned: 0.35,
            dy: -0.04,
          )),
          emphasis: _kSheetEmphasis,
          reveal: reveal,
        );
      case CompositionMode.aspectRatio:
        return _CompositionPainter(
          spec.mode,
          aspect: 4 / 5,
          emphasis: _kSheetEmphasis,
          reveal: reveal,
        );
      default:
        return _CompositionPainter(
          spec.mode,
          emphasis: _kSheetEmphasis,
          reveal: reveal,
        );
    }
  }

  /// Gold tracked section header over calm paper body text.
  Widget _section(String title, String body) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        title,
        style: brandLabel(
          size: 9,
          weight: FontWeight.w600,
          color: kGold.withValues(alpha: 0.85),
          letterSpacing: 2.4,
        ),
      ),
      const SizedBox(height: 5),
      Text(
        body,
        style: brandLabel(
          size: 12.5,
          weight: FontWeight.w400,
          color: kPaper.withValues(alpha: 0.88),
          letterSpacing: 0.2,
        ).copyWith(height: 1.45),
      ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final double maxH = MediaQuery.of(context).size.height * 0.86;
    final String? orient = spec.orientation.label;
    final bool landscapeDiagram =
        spec.orientation == CompoOrientation.landscape;
    // Centred card, not a docked sheet: rounded on all four corners and inset
    // from the edges so the shot stays visible around it.
    //
    // The vertical inset takes the LARGER of the two safe areas, not their
    // sum: `padding.vertical` adds top and bottom together, so a Dynamic
    // Island phone was losing ~93pt of height to an inset meant to clear ~59.
    final EdgeInsets safe = MediaQuery.of(context).padding;
    return Center(
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: 18,
          vertical: math.max(safe.top, safe.bottom) + 24,
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(kRadiusLg + 8),
          child: BackdropFilter(
            // Same deep frost as the paywall — a modal can afford true blur.
            filter: ui.ImageFilter.blur(sigmaX: 28, sigmaY: 28),
            child: Container(
              constraints: BoxConstraints(
                maxHeight: maxH,
                maxWidth: _kCardMaxW,
              ),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.white.withValues(alpha: 0.10),
                    Colors.black.withValues(alpha: 0.66),
                    Colors.black.withValues(alpha: 0.84),
                  ],
                  stops: const [0.0, 0.4, 1.0],
                ),
              ),
              child: Stack(
                children: [
                  // Warm gold aura behind the header.
                  Positioned(
                    top: -90,
                    left: -40,
                    right: -40,
                    child: const GoldAura(height: 220),
                  ),
                  // Gold-leaf top edge.
                  const Positioned(
                    top: 0,
                    left: 0,
                    right: 0,
                    child: GildedHairline(height: 1.2),
                  ),
                  SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(24, 18, 24, 20),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        // Eyebrow: GUIDE + recommended hold. A Wrap, not a Row:
                        // one line with the hold pushed right at normal sizes, and
                        // at accessibility text sizes the hold drops to a second
                        // line instead of overflowing (127px on an SE at AX5).
                        Wrap(
                          alignment: WrapAlignment.spaceBetween,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          runSpacing: 4,
                          children: [
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(
                                  Icons.auto_awesome_rounded,
                                  color: kGold,
                                  size: 12,
                                ),
                                const SizedBox(width: 6),
                                Text(
                                  'GUIDE',
                                  style: brandLabel(
                                    size: 9,
                                    weight: FontWeight.w600,
                                    color: kGold.withValues(alpha: 0.85),
                                    letterSpacing: 2.8,
                                  ),
                                ),
                              ],
                            ),
                            if (orient != null)
                              Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    orient == 'Portrait'
                                        ? Icons.stay_current_portrait_rounded
                                        : orient == 'Landscape'
                                        ? Icons.stay_current_landscape_rounded
                                        : Icons.screen_rotation_rounded,
                                    color: kGold.withValues(alpha: 0.7),
                                    size: 11,
                                  ),
                                  const SizedBox(width: 4),
                                  Text(
                                    orient.toUpperCase(),
                                    style: brandLabel(
                                      size: 9,
                                      weight: FontWeight.w600,
                                      color: kGold.withValues(alpha: 0.7),
                                      letterSpacing: 1.8,
                                    ),
                                  ),
                                ],
                              ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        // Mode name in the editorial serif.
                        Text(
                          spec.label,
                          style: brandDisplay(
                            size: 26,
                            weight: FontWeight.w500,
                            letterSpacing: 0.2,
                          ),
                        ),
                        const SizedBox(height: 14),
                        // The living diagram — a stylised scene (painted, not
                        // photographed: copyright-free by construction) under the
                        // mode's own overlay painter, framed like a print in a
                        // fine gold mat.
                        SizedBox(
                          height: 200,
                          child: Center(
                            child: AspectRatio(
                              aspectRatio: landscapeDiagram ? 4 / 3 : 3 / 4,
                              child: Container(
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(
                                    kRadiusMd,
                                  ),
                                  border: Border.all(
                                    color: kGold.withValues(alpha: 0.35),
                                    width: 0.8,
                                  ),
                                  boxShadow: kSoftShadow,
                                ),
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(
                                    kRadiusMd,
                                  ),
                                  child: Stack(
                                    fit: StackFit.expand,
                                    children: [
                                      // Real example photo when one is bundled
                                      // (assets/guides/<mode>.jpg — see the README
                                      // there); otherwise the painted scene.
                                      Image.asset(
                                        'assets/guides/${spec.mode.name}.jpg',
                                        fit: BoxFit.cover,
                                        errorBuilder: (_, _, _) => CustomPaint(
                                          painter: _GuideScenePainter(
                                            spec.mode,
                                          ),
                                        ),
                                      ),
                                      // Soft scrim so the white guide lines stay
                                      // legible over any photograph.
                                      DecoratedBox(
                                        decoration: BoxDecoration(
                                          gradient: LinearGradient(
                                            begin: Alignment.topCenter,
                                            end: Alignment.bottomCenter,
                                            colors: [
                                              Colors.black.withValues(
                                                alpha: 0.18,
                                              ),
                                              Colors.black.withValues(
                                                alpha: 0.30,
                                              ),
                                            ],
                                          ),
                                        ),
                                      ),
                                      // Own layer: the reveal animates for
                                      // ~1.1s at display rate directly over a
                                      // decoded JPEG and a gradient scrim.
                                      // Without this, every frame of the draw-on
                                      // marks the photo's layer dirty too — the
                                      // guide's whole point is the photograph
                                      // underneath, so it must not be
                                      // re-rasterised 60×/second to animate a
                                      // line over it.
                                      RepaintBoundary(
                                        child: AnimatedBuilder(
                                          animation: _draw,
                                          builder: (_, _) => CustomPaint(
                                            painter: _diagramPainter(
                                              Curves.easeInOutCubic.transform(
                                                _draw.value,
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 16),
                        if (spec.tip != null) ...[
                          _section('BEST FOR', spec.tip!),
                          const SizedBox(height: 14),
                        ],
                        // How-to leads: a user opening this sheet wants to shoot,
                        // not to study. The principle follows for those who want it.
                        if (spec.how != null) ...[
                          _section('HOW TO USE IT', spec.how!),
                          const SizedBox(height: 14),
                        ],
                        if (spec.what != null)
                          _section('WHAT IT IS', spec.what!),
                        const SizedBox(height: 20),
                        // Dismiss — the gallery's gilded filter chip (PopTap, 40pt,
                        // radius 20), so the sheet's one control is the same object
                        // as the rest of the app's chrome. The 2pt vertical pad
                        // lifts the tap target to 44pt without changing the chip.
                        // Shrink-wrapped explicitly: a Container with `alignment`
                        // inside a bounded Center expands to the full width, and
                        // minHeight (not height) lets large type grow the chip
                        // instead of spilling out of it.
                        Center(
                          child: PopTap(
                            onTap: () => Navigator.of(context).pop(),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(vertical: 2),
                              child: Container(
                                constraints: const BoxConstraints(
                                  minHeight: 40,
                                ),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 22,
                                ),
                                decoration: glassChipDecoration(
                                  radius: kRadiusLg,
                                  active: true,
                                ),
                                child: Center(
                                  widthFactor: 1,
                                  heightFactor: 1,
                                  child: Text(
                                    'GOT IT',
                                    style: brandLabel(
                                      size: 10.5,
                                      weight: FontWeight.w600,
                                      color: kGold,
                                      letterSpacing: 2.4,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Stylised example scene behind each guide diagram — PAINTED, not
/// photographed, so it's copyright-free by construction. Every scene is a
/// dusk-lit vignette in the app's smoke-and-gold palette (silhouettes under a
/// warm sky, a champagne sun), composed so the mode's overlay lands on it the
/// way a real shot should: the figure stands on the third, the mountain fills
/// the pyramid, the river runs the S-curve.
class _GuideScenePainter extends CustomPainter {
  final CompositionMode mode;
  const _GuideScenePainter(this.mode);

  // Dusk palette — warm darks so the white guide lines stay legible on top.
  static const Color _skyHi = Color(0xFF3A3120); // lit dusk, high in the sky
  static const Color _skyLo = Color(0xFF181410); // dusk falling to earth
  static const Color _far = Color(0xFF221D14); // far silhouettes
  static const Color _near = Color(0xFF0F0D09); // near silhouettes
  static const Color _sunCore = Color(0xFFF3E0AE);

  void _sky(Canvas c, Size s) {
    final rect = Offset.zero & s;
    c.drawRect(
      rect,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [_skyHi, _skyLo],
        ).createShader(rect),
    );
  }

  void _sun(Canvas c, Offset o, double r) {
    c.drawCircle(
      o,
      r * 2.4,
      Paint()
        ..color = kGoldLit.withValues(alpha: 0.20)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, r * 1.2),
    );
    c.drawCircle(o, r, Paint()..color = _sunCore.withValues(alpha: 0.92));
  }

  /// A standing figure silhouette: head centred at [head], feet on [groundY].
  void _figure(Canvas c, Offset head, double r, double groundY) {
    final p = Paint()..color = _near;
    c.drawCircle(head, r, p);
    final body = Path()
      ..moveTo(head.dx - r * 1.1, groundY)
      ..quadraticBezierTo(
        head.dx - r * 1.3,
        head.dy + r * 1.6,
        head.dx,
        head.dy + r * 1.1,
      )
      ..quadraticBezierTo(
        head.dx + r * 1.3,
        head.dy + r * 1.6,
        head.dx + r * 1.1,
        groundY,
      )
      ..close();
    c.drawPath(body, p);
  }

  /// Filled polygon from relative (0..1) points.
  void _poly(Canvas c, Size s, List<List<double>> pts, Color color) {
    final path = Path()..moveTo(pts[0][0] * s.width, pts[0][1] * s.height);
    for (final p in pts.skip(1)) {
      path.lineTo(p[0] * s.width, p[1] * s.height);
    }
    path.close();
    c.drawPath(path, Paint()..color = color);
  }

  /// Soft photographic vignette so the plate reads as an image, not a chart.
  void _vignette(Canvas c, Size s) {
    final rect = Offset.zero & s;
    c.drawRect(
      rect,
      Paint()
        ..shader = RadialGradient(
          radius: 1.05,
          colors: [Colors.transparent, Colors.black.withValues(alpha: 0.38)],
          stops: const [0.62, 1.0],
        ).createShader(rect),
    );
  }

  @override
  void paint(Canvas canvas, Size size) {
    final double w = size.width, h = size.height;
    _sky(canvas, size);

    switch (mode) {
      case CompositionMode.horizonGrid:
      case CompositionMode.aspectRatio:
        // Open sea at dusk — horizon sitting on the gold guide line.
        _sun(canvas, Offset(w * 0.68, h * 0.36), h * 0.055);
        _poly(canvas, size, const [
          [0, 0.59],
          [1, 0.59],
          [1, 1],
          [0, 1],
        ], _far);
        // A glint of sun on the water.
        canvas.drawLine(
          Offset(w * 0.60, h * 0.66),
          Offset(w * 0.76, h * 0.66),
          Paint()
            ..color = kGoldLit.withValues(alpha: 0.22)
            ..strokeWidth = 2
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2),
        );

      case CompositionMode.ruleOfThirds:
        // A figure in a field, head resting on the top-left power point.
        _sun(canvas, Offset(w * 0.78, h * 0.22), h * 0.05);
        _poly(canvas, size, const [
          [0, 0.78],
          [1, 0.74],
          [1, 1],
          [0, 1],
        ], _far);
        _figure(canvas, Offset(w / 3, h / 3), h * 0.09, h * 0.80);

      case CompositionMode.goldenSection:
        // Same scene, subject a touch more central — on the phi point.
        _sun(canvas, Offset(w * 0.80, h * 0.20), h * 0.05);
        _poly(canvas, size, const [
          [0, 0.78],
          [1, 0.74],
          [1, 1],
          [0, 1],
        ], _far);
        _figure(canvas, Offset(w * 0.382, h * 0.382), h * 0.085, h * 0.80);

      case CompositionMode.goldenTriangles:
        // A hillside road running the main diagonal.
        _sun(canvas, Offset(w * 0.76, h * 0.24), h * 0.05);
        _poly(canvas, size, const [
          [0, 0.06],
          [1, 0.94],
          [1, 1],
          [0, 1],
        ], _far);
        _poly(canvas, size, const [
          [0, 0.30],
          [1, 1.18],
          [0, 1],
        ], _near);

      case CompositionMode.fibonacciSpiral:
        // A river sweeping in toward the spiral's eye.
        _sun(canvas, Offset(w * 0.62, h * 0.40), h * 0.045);
        _poly(canvas, size, const [
          [0, 0.55],
          [1, 0.52],
          [1, 1],
          [0, 1],
        ], _far);
        final river = Path()
          ..moveTo(w * 0.05, h * 1.0)
          ..cubicTo(w * 0.45, h * 0.85, w * 0.95, h * 0.75, w * 0.72, h * 0.58)
          ..quadraticBezierTo(w * 0.55, h * 0.47, w * 0.62, h * 0.42);
        canvas.drawPath(
          river,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = h * 0.06
            ..strokeCap = StrokeCap.round
            ..color = kGoldLit.withValues(alpha: 0.16),
        );

      case CompositionMode.cross:
        // A formal doorway, dead centre.
        _poly(canvas, size, const [
          [0, 0.86],
          [1, 0.86],
          [1, 1],
          [0, 1],
        ], _near);
        _poly(canvas, size, const [
          [0.30, 0.30],
          [0.70, 0.30],
          [0.70, 0.86],
          [0.30, 0.86],
        ], _far);
        _poly(canvas, size, const [
          [0.42, 0.42],
          [0.58, 0.42],
          [0.58, 0.86],
          [0.42, 0.86],
        ], _near);
        _sun(canvas, Offset(w * 0.5, h * 0.20), h * 0.04);

      case CompositionMode.focalMass:
        // One small balloon adrift in a lot of sky.
        _poly(canvas, size, const [
          [0, 0.88],
          [1, 0.84],
          [1, 1],
          [0, 1],
        ], _far);
        _sun(canvas, Offset(w * 0.62, h * 0.38), h * 0.045);
        canvas.drawCircle(
          Offset(w * 0.62, h * 0.38),
          h * 0.032,
          Paint()..color = _near,
        );

      case CompositionMode.vArrangement:
        // A valley — two slopes meeting, light in the notch.
        _sun(canvas, Offset(w * 0.5, h * 0.42), h * 0.05);
        _poly(canvas, size, const [
          [0, 0.18],
          [0.5, 0.62],
          [0, 1],
        ], _far);
        _poly(canvas, size, const [
          [1, 0.18],
          [0.5, 0.62],
          [1, 1],
        ], _far);
        _poly(canvas, size, const [
          [0, 0.86],
          [1, 0.86],
          [1, 1],
          [0, 1],
        ], _near);

      case CompositionMode.diagonal:
        // Long dusk light raking across a street from the corner.
        _sun(canvas, Offset(w * 0.12, h * 0.14), h * 0.055);
        for (final d in const [0.0, 0.16, 0.34]) {
          _poly(canvas, size, [
            [0.0, 0.10 + d],
            [1.0, 0.62 + d * 1.4],
            [1.0, 0.70 + d * 1.4],
            [0.0, 0.18 + d],
          ], kGoldLit.withValues(alpha: 0.05));
        }
        _poly(canvas, size, const [
          [0, 0.80],
          [1, 0.92],
          [1, 1],
          [0, 1],
        ], _near);

      case CompositionMode.radial:
        // A tunnel of light — everything rushing to the hub.
        _sun(canvas, Offset(w * 0.5, h * 0.5), h * 0.06);
        canvas.drawCircle(
          Offset(w * 0.5, h * 0.5),
          h * 0.34,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = h * 0.16
            ..color = _near.withValues(alpha: 0.75)
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 14),
        );

      case CompositionMode.lArrangement:
        // Still life: a bottle holding the corner, space flowing right.
        _poly(canvas, size, const [
          [0, 0.72],
          [1, 0.72],
          [1, 1],
          [0, 1],
        ], _far);
        _poly(canvas, size, const [
          [0.22, 0.38],
          [0.30, 0.38],
          [0.30, 0.72],
          [0.22, 0.72],
        ], _near);
        _poly(canvas, size, const [
          [0.16, 0.46],
          [0.36, 0.46],
          [0.36, 0.72],
          [0.16, 0.72],
        ], _near);
        _sun(canvas, Offset(w * 0.72, h * 0.28), h * 0.04);

      case CompositionMode.compoundCurve:
        // A river tracing the S from the foreground to the far bank.
        _sun(canvas, Offset(w * 0.30, h * 0.28), h * 0.05);
        _poly(canvas, size, const [
          [0, 0.46],
          [1, 0.44],
          [1, 1],
          [0, 1],
        ], _far);
        final s = Path()
          ..moveTo(w * 0.30, h * 1.0)
          ..cubicTo(w * 0.85, h * 0.88, w * 0.05, h * 0.68, w * 0.48, h * 0.56)
          ..quadraticBezierTo(w * 0.72, h * 0.50, w * 0.66, h * 0.45);
        canvas.drawPath(
          s,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = h * 0.055
            ..strokeCap = StrokeCap.round
            ..color = kGoldLit.withValues(alpha: 0.16),
        );

      case CompositionMode.pyramid:
        // A mountain filling the triangle, lit at the summit.
        _sun(canvas, Offset(w * 0.80, h * 0.20), h * 0.045);
        _poly(canvas, size, const [
          [0.5, 0.22],
          [0.96, 0.85],
          [0.04, 0.85],
        ], _far);
        _poly(canvas, size, const [
          [0, 0.85],
          [1, 0.85],
          [1, 1],
          [0, 1],
        ], _near);
        canvas.drawCircle(
          Offset(w * 0.5, h * 0.23),
          h * 0.02,
          Paint()
            ..color = kGoldLit.withValues(alpha: 0.5)
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5),
        );

      case CompositionMode.circular:
        // Top-down table: a plate gathered around the middle.
        canvas.drawRect(Offset.zero & size, Paint()..color = _skyLo);
        canvas.drawCircle(
          Offset(w * 0.5, h * 0.5),
          h * 0.34,
          Paint()..color = _far,
        );
        canvas.drawCircle(
          Offset(w * 0.5, h * 0.5),
          h * 0.28,
          Paint()..color = _near,
        );
        _sun(canvas, Offset(w * 0.5, h * 0.5), h * 0.05);

      case CompositionMode.symmetry:
        // A peak mirrored in still water about the centre line.
        _sun(canvas, Offset(w * 0.5, h * 0.30), h * 0.05);
        _poly(canvas, size, const [
          [0.5, 0.26],
          [0.86, 0.60],
          [0.14, 0.60],
        ], _far);
        _poly(canvas, size, const [
          [0, 0.60],
          [1, 0.60],
          [1, 1],
          [0, 1],
        ], _skyLo);
        _poly(canvas, size, [
          [0.5, 0.90],
          [0.80, 0.60],
          [0.20, 0.60],
        ], _far.withValues(alpha: 0.5));

      case CompositionMode.none:
        break;
    }

    _vignette(canvas, size);
  }

  @override
  bool shouldRepaint(_GuideScenePainter old) => old.mode != mode;
}
