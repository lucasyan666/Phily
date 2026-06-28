import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback;
import 'package:google_fonts/google_fonts.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Phily design system
//
// One source of truth for the app's look: the brand accent, the shape/elevation
// scale, the type system, and the shared "liquid glass" surface. Build chrome
// from these so every screen reads as the same product.
// ─────────────────────────────────────────────────────────────────────────────

// ── Colour ───────────────────────────────────────────────────────────────────

/// Phily's brand accent — warm gold. The single source of the literal; don't
/// re-declare `Color(0xFFE5C158)` elsewhere.
const Color kGold = Color(0xFFE5C158);

/// A softer, antique-gold partner for fine rules, gradients and secondary marks.
const Color kGoldDeep = Color(0xFFB8923D);

/// Warm off-white for brand surfaces — more refined than pure white, and the
/// primary text colour on the dark chrome.
const Color kPaper = Color(0xFFF6F1E7);

/// App background.
const Color kBackground = Color(0xFF000000);

// ── Type ─────────────────────────────────────────────────────────────────────
//
// Two faces carry the brand voice:
//  • Fraunces — an editorial, high-contrast serif for the wordmark and headline
//    moments (the "couture" voice).
//  • Outfit — a clean geometric sans for all UI, set app-wide via the theme so
//    every label inherits it.

/// Editorial display serif — wordmark + headline brand moments.
TextStyle brandDisplay({
  double size = 30,
  FontWeight weight = FontWeight.w400,
  Color color = kPaper,
  double letterSpacing = 0,
  double? height,
  FontStyle? style,
}) => GoogleFonts.fraunces(
  fontSize: size,
  fontWeight: weight,
  color: color,
  letterSpacing: letterSpacing,
  height: height,
  fontStyle: style,
);

/// Refined tracked UI label (small caps-style chrome labels).
TextStyle brandLabel({
  double size = 11,
  FontWeight weight = FontWeight.w500,
  Color color = kPaper,
  double letterSpacing = 1.5,
}) => GoogleFonts.outfit(
  fontSize: size,
  fontWeight: weight,
  color: color,
  letterSpacing: letterSpacing,
);

/// App-wide UI text theme (geometric sans). Apply in [ThemeData.textTheme] so
/// every Text inherits the brand typeface without per-widget changes.
TextTheme appTextTheme(TextTheme base) => GoogleFonts.outfitTextTheme(base);

// ── Motion ───────────────────────────────────────────────────────────────────
//
// One easing + duration language across the app: calm, settled entrances and a
// touch of acceleration on exits — never linear, never bouncy.

const Curve kEaseOut = Curves.easeOutCubic; // entrances / settles
const Curve kEaseIn = Curves.easeInCubic; // exits / retracts
const Duration kDurFast = Duration(milliseconds: 200); // taps, toggles
const Duration kDurMed = Duration(milliseconds: 340); // pills, hints
const Duration kDurSlow = Duration(milliseconds: 460); // sheets, reveals

// ── Haptics ──────────────────────────────────────────────────────────────────

/// The app's standard tap tick — selection-style, used on every deliberate tap.
void hapticTap() => HapticFeedback.selectionClick();

/// A warmer confirmation, for rewarding moments (alignment locking to "Perfect").
void hapticReward() => HapticFeedback.mediumImpact();

// ── Shape ────────────────────────────────────────────────────────────────────

const double kRadiusSm = 8; // thumbnails, badges, small chips
const double kRadiusMd = 14; // cards, sheets
const double kRadiusLg = 20; // pills / floating bubbles

// ── Elevation ────────────────────────────────────────────────────────────────

/// Layered soft shadow for floating glass chrome — a deep ambient drop plus a
/// tight contact shadow, for real depth off the backdrop.
const List<BoxShadow> kSoftShadow = [
  BoxShadow(color: Color(0x59000000), blurRadius: 24, offset: Offset(0, 10)),
  BoxShadow(color: Color(0x24000000), blurRadius: 6, offset: Offset(0, 2)),
];

// ── Glass ────────────────────────────────────────────────────────────────────

/// The app's shared frosted-glass surface, matching the camera page's chrome: a
/// real `BackdropFilter` blur under a top white sheen that fades to a dark base
/// (which keeps white icons/text legible over any backdrop), with a thin white
/// rim and a soft shadow. Save-layer clipped so the blur fills cleanly to the
/// very edge (no unblurred sliver). Sizes to its [child].
///
/// This is the single definition of Phily's glass — the gallery's date bubble and
/// action buttons build from it so they read as the same material as the camera.
class GlassSurface extends StatelessWidget {
  final Widget child;
  final BorderRadius borderRadius;
  final EdgeInsetsGeometry padding;
  final double blur;
  const GlassSurface({
    super.key,
    required this.child,
    required this.borderRadius,
    this.padding = EdgeInsets.zero,
    this.blur = 24,
  });

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: borderRadius,
        boxShadow: kSoftShadow,
      ),
      child: Stack(
        children: [
          // Frosted body — a strong blur under a diagonal sheen→dark gradient,
          // with a soft specular bloom at the light source (top-left) and a faint
          // reflection along the bottom lip. Save-layer clipped so the blur and
          // every highlight fill cleanly to the rounded edge.
          Positioned.fill(
            child: ClipRRect(
              borderRadius: borderRadius,
              clipBehavior: Clip.antiAliasWithSaveLayer,
              child: BackdropFilter(
                filter: ui.ImageFilter.blur(sigmaX: blur, sigmaY: blur),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        Colors.white.withValues(alpha: 0.20),
                        Colors.white.withValues(alpha: 0.06),
                        Colors.black.withValues(alpha: 0.30),
                      ],
                      stops: const [0.0, 0.45, 1.0],
                    ),
                  ),
                  child: DecoratedBox(
                    // Specular bloom where light strikes the glass.
                    decoration: BoxDecoration(
                      gradient: RadialGradient(
                        center: const Alignment(-0.7, -1.0),
                        radius: 1.2,
                        colors: [
                          Colors.white.withValues(alpha: 0.34),
                          Colors.white.withValues(alpha: 0.0),
                        ],
                        stops: const [0.0, 0.55],
                      ),
                    ),
                    child: DecoratedBox(
                      // Light bouncing off the bottom lip.
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.bottomCenter,
                          end: Alignment.center,
                          colors: [
                            Colors.white.withValues(alpha: 0.10),
                            Colors.white.withValues(alpha: 0.0),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          // Content.
          Padding(padding: padding, child: child),
          // The art: a directional, light-aware rim — bright where light catches
          // the edge (top-left), fading round to the far side, with a brighter
          // inner top "lip" highlight that gives the glass a sense of thickness.
          Positioned.fill(
            child: IgnorePointer(
              child: CustomPaint(painter: _GlassRimPainter(borderRadius)),
            ),
          ),
        ],
      ),
    );
  }
}

/// Paints the light-aware glass rim: a gradient-lit outer stroke plus a brighter
/// inner top-edge highlight, so the surface reads as a real glass slab catching a
/// directional light rather than a flat outline.
class _GlassRimPainter extends CustomPainter {
  final BorderRadius radius;
  const _GlassRimPainter(this.radius);

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;

    // Outer rim — brightest at the top-left light source, faint on the far side.
    canvas.drawRRect(
      radius.toRRect(rect.deflate(0.6)),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2
        ..isAntiAlias = true
        ..shader = const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xD9FFFFFF), Color(0x33FFFFFF), Color(0x14FFFFFF)],
          stops: [0.0, 0.5, 1.0],
        ).createShader(rect),
    );

    // Inner top "lip" — a crisp highlight just inside the top edge, fading down.
    canvas.drawRRect(
      radius.toRRect(rect.deflate(1.8)),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.0
        ..isAntiAlias = true
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Colors.white.withValues(alpha: 0.5),
            Colors.white.withValues(alpha: 0.0),
          ],
          stops: const [0.0, 0.45],
        ).createShader(rect),
    );
  }

  @override
  bool shouldRepaint(_GlassRimPainter old) => old.radius != radius;
}
