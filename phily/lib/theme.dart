import 'dart:async';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show HapticFeedback, LengthLimitingTextInputFormatter;
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

/// Lit champagne — the highlight where light strikes polished gold. Tops the
/// metallic gradients (CTA bar, capture ring, badges) so gold reads as metal
/// catching light, never as a flat fill.
const Color kGoldLit = Color(0xFFFBE6B4);

/// Warm near-black for the smoked-glass chrome — a breath of warmth over pure
/// black so panels read as dark glass rather than dead pixels.
const Color kSmoke = Color(0xFF0A0A0C);

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
  List<Shadow>? shadows,
}) => GoogleFonts.outfit(
  fontSize: size,
  fontWeight: weight,
  color: color,
  letterSpacing: letterSpacing,
  shadows: shadows,
);

/// Shadow stack for text floating over the live camera preview. Gold/paper
/// labels on thin smoked glass die over bright scenes (sky, white tabletops) —
/// this is a scrim in type form: a soft dark halo plus a tight contact shadow,
/// invisible over dark scenes but decisive over light ones.
const List<Shadow> kViewfinderShadows = [
  Shadow(color: Color(0xB3000000), blurRadius: 7),
  Shadow(color: Color(0x8C000000), blurRadius: 2, offset: Offset(0, 1)),
];

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

/// iOS Reduce Motion (Settings → Accessibility → Motion). Decorative motion —
/// the tap bubble, fades, zooms — collapses to an instant state change. Motion
/// that carries information (the level line, detection targets) is untouched.
bool reduceMotionOf(BuildContext context) =>
    MediaQuery.disableAnimationsOf(context);

/// [d], or zero under Reduce Motion — for implicit animations' `duration:`.
Duration motionOf(BuildContext context, Duration d) =>
    reduceMotionOf(context) ? Duration.zero : d;

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

// ── Gilded details ───────────────────────────────────────────────────────────

/// A fine gilded rule that burns brightest at the centre and dissolves to
/// nothing at the ends — gold leaf catching light along an edge. Used as the
/// camera chrome's preview-facing lip and as a section ornament on sheets.
class GildedHairline extends StatelessWidget {
  final double height;
  final double opacity;
  const GildedHairline({super.key, this.height = 1, this.opacity = 1});

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: Container(
      height: height,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            kGold.withValues(alpha: 0),
            kGold.withValues(alpha: 0.45 * opacity),
            kGoldLit.withValues(alpha: 0.85 * opacity),
            kGold.withValues(alpha: 0.45 * opacity),
            kGold.withValues(alpha: 0),
          ],
          stops: const [0.0, 0.24, 0.5, 0.76, 1.0],
        ),
      ),
    ),
  );
}

/// The wordmark: "Phily" in the editorial serif, paper melting into gold along
/// a top-left → bottom-right sweep (board 1f). The branded loader and the
/// first-launch screen both draw this one object, so the loading moment and
/// the first screen read as one. Size, weight and tracking are the caller's;
/// the gilding is not.
class GildedWordmark extends StatelessWidget {
  final double size;
  final FontWeight weight;
  final double letterSpacing;
  const GildedWordmark({
    super.key,
    this.size = 44,
    this.weight = FontWeight.w300,
    this.letterSpacing = -0.5,
  });

  @override
  Widget build(BuildContext context) => ShaderMask(
    shaderCallback: (r) => const LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [kPaper, kGold],
      stops: [0.35, 1.0],
    ).createShader(r),
    child: Text(
      'Phily',
      style: brandDisplay(
        size: size,
        weight: weight,
        color: Colors.white, // recoloured by the shader
        letterSpacing: letterSpacing,
      ),
    ),
  );
}

/// Smoked-glass chip — the shared decoration for the camera's small floating
/// controls (grid toggle, mode action buttons, zoom tag). Deliberately
/// gradient-faked glass: a warm dark body under a diagonal sheen, finished with
/// a gold-kissed ([active]) or paper hairline rim and a soft contact shadow.
/// NO BackdropFilter — these chips float over the live preview, where a real
/// blur re-rasterises every frame and costs FPS.
BoxDecoration glassChipDecoration({
  double radius = kRadiusMd,
  bool circle = false,
  bool active = false,
}) => BoxDecoration(
  shape: circle ? BoxShape.circle : BoxShape.rectangle,
  borderRadius: circle ? null : BorderRadius.circular(radius),
  gradient: LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [
      Colors.white.withValues(alpha: active ? 0.16 : 0.10),
      Colors.white.withValues(alpha: 0.03),
      kSmoke.withValues(alpha: 0.52),
    ],
    stops: const [0.0, 0.42, 1.0],
  ),
  border: Border.all(
    color: active
        ? kGold.withValues(alpha: 0.65)
        : Colors.white.withValues(alpha: 0.22),
    width: active ? 1.0 : 0.8,
  ),
  boxShadow: [
    BoxShadow(
      color: Colors.black.withValues(alpha: 0.32),
      blurRadius: 10,
      offset: const Offset(0, 3),
    ),
    if (active) BoxShadow(color: kGold.withValues(alpha: 0.16), blurRadius: 12),
  ],
);

/// Polished-metal ring — a sweep-gradient stroke that reads as a machined gold
/// bezel: champagne where the light strikes (upper-left), deepening to antique
/// gold around the band and back. One stroked circle, so it costs nothing.
class MetalRingPainter extends CustomPainter {
  final double width;
  const MetalRingPainter({this.width = 2.5});

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.drawCircle(
      rect.center,
      (size.shortestSide - width) / 2,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = width
        ..isAntiAlias = true
        ..shader = const SweepGradient(
          transform: GradientRotation(-2.4), // light source ≈ upper-left
          colors: [kGoldLit, kGold, kGoldDeep, kGold, kGoldLit],
          stops: [0.0, 0.22, 0.55, 0.82, 1.0],
        ).createShader(rect),
    );
  }

  @override
  bool shouldRepaint(MetalRingPainter old) => old.width != width;
}

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

// ── Interaction ──────────────────────────────────────────────────────────────

/// Tap feedback for the app's small chrome controls, camera and gallery alike:
/// a selection tick and a quick "bubble" — the control swells to 114% and
/// settles back, ~260ms, easeOutBack on the way up so it overshoots like
/// something soft. Only scale animates, so it costs nothing over the live
/// preview.
class PopTap extends StatefulWidget {
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final Widget child;

  /// VoiceOver name for icon-only controls. Text children announce
  /// themselves (their label merges into this node), so leave it null there.
  final String? semanticLabel;

  /// On/off controls (grid toggle, favourite) announce their state.
  final bool? toggled;
  const PopTap({
    super.key,
    this.onTap,
    this.onLongPress,
    required this.child,
    this.semanticLabel,
    this.toggled,
  });

  @override
  State<PopTap> createState() => _PopTapState();
}

class _PopTapState extends State<PopTap> with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 260),
  );
  late final Animation<double> _scale = TweenSequence<double>([
    TweenSequenceItem(
      tween: Tween(
        begin: 1.0,
        end: 1.14,
      ).chain(CurveTween(curve: Curves.easeOutBack)),
      weight: 40,
    ),
    TweenSequenceItem(
      tween: Tween(
        begin: 1.14,
        end: 1.0,
      ).chain(CurveTween(curve: Curves.easeOutCubic)),
      weight: 60,
    ),
  ]).animate(_ctrl);

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _pop() {
    HapticFeedback.selectionClick();
    // The tick stays under Reduce Motion; only the bubble is motion.
    if (!reduceMotionOf(context)) _ctrl.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    final bool enabled = widget.onTap != null || widget.onLongPress != null;
    // One semantics node per control — the button trait, its name and its
    // state — merged with whatever the child says, so VoiceOver reads
    // "Share, button" for an icon and "GOT IT, button" for a text chip.
    return MergeSemantics(
      child: Semantics(
        button: enabled,
        enabled: enabled,
        label: widget.semanticLabel,
        toggled: widget.toggled,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap == null
              ? null
              : () {
                  _pop();
                  widget.onTap!();
                },
          onLongPress: widget.onLongPress == null
              ? null
              : () {
                  _pop();
                  widget.onLongPress!();
                },
          child: Opacity(
            opacity: enabled ? 1.0 : 0.4,
            child: ScaleTransition(scale: _scale, child: widget.child),
          ),
        ),
      ),
    );
  }
}

/// A 46pt round glass control — the camera's grid toggle and the gallery's
/// share / favourite / delete are all this object. [active] gilds the rim and
/// the glyph.
class GlassRoundButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback? onTap;
  final bool active;
  final double size;
  final double iconSize;
  final String? semanticLabel; // icon-only: name it for VoiceOver
  final bool? toggled; // on/off controls announce their state
  const GlassRoundButton({
    super.key,
    required this.icon,
    required this.onTap,
    this.active = false,
    this.size = 46,
    this.iconSize = 20,
    this.semanticLabel,
    this.toggled,
  });

  @override
  Widget build(BuildContext context) => PopTap(
    onTap: onTap,
    semanticLabel: semanticLabel,
    toggled: toggled,
    child: AnimatedContainer(
      duration: motionOf(context, kDurFast),
      curve: Curves.easeOut,
      width: size,
      height: size,
      decoration: glassChipDecoration(circle: true, active: active),
      child: Icon(
        icon,
        color: active ? kGold : kPaper.withValues(alpha: 0.92),
        size: iconSize,
      ),
    ),
  );
}

/// A 48pt square glass control (radius 16) — the camera's guide "i" and the
/// gallery's back button share this shape.
class GlassSquareButton extends StatelessWidget {
  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final bool active;
  final String? semanticLabel; // glyph-only: name it for VoiceOver
  const GlassSquareButton({
    super.key,
    required this.child,
    required this.onTap,
    this.onLongPress,
    this.active = false,
    this.semanticLabel,
  });

  @override
  Widget build(BuildContext context) => PopTap(
    onTap: onTap,
    onLongPress: onLongPress,
    semanticLabel: semanticLabel,
    child: Container(
      width: 48,
      height: 48,
      alignment: Alignment.center,
      decoration: glassChipDecoration(radius: 16, active: active),
      child: child,
    ),
  );
}

/// The app's switch — a gilded track with a polished thumb, in the same
/// gold-and-glass language as every other control. Replaces
/// `Switch.adaptive`, whose iOS-green track was the one place the app showed
/// a platform default instead of its own palette.
///
/// A [PopTap] underneath gives it the shared tick, bubble and button trait;
/// [semanticLabel] names it, and the on/off state is announced.
class GildedSwitch extends StatelessWidget {
  final bool value;
  final ValueChanged<bool>? onChanged;
  final String? semanticLabel;
  const GildedSwitch({
    super.key,
    required this.value,
    required this.onChanged,
    this.semanticLabel,
  });

  static const double _w = 46;
  static const double _h = 27;
  static const double _pad = 3;

  @override
  Widget build(BuildContext context) {
    const double thumb = _h - _pad * 2;
    return PopTap(
      onTap: onChanged == null ? null : () => onChanged!(!value),
      semanticLabel: semanticLabel,
      toggled: value,
      child: AnimatedContainer(
        duration: motionOf(context, kDurFast),
        curve: kEaseOut,
        width: _w,
        height: _h,
        padding: const EdgeInsets.all(_pad),
        alignment: value ? Alignment.centerRight : Alignment.centerLeft,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(_h / 2),
          // On: lit gilt melting to gold, the paywall CTA's metal. Off: the
          // same smoked glass as an inactive chip.
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: value
                ? const [kGoldLit, kGold, kGoldDeep]
                : [
                    Colors.white.withValues(alpha: 0.10),
                    Colors.white.withValues(alpha: 0.03),
                    kSmoke.withValues(alpha: 0.52),
                  ],
            stops: const [0.0, 0.5, 1.0],
          ),
          border: Border.all(
            color: value
                ? kGold.withValues(alpha: 0.9)
                : Colors.white.withValues(alpha: 0.22),
            width: value ? 1.0 : 0.8,
          ),
          boxShadow: value
              ? [
                  BoxShadow(
                    color: kGold.withValues(alpha: 0.22),
                    blurRadius: 10,
                  ),
                ]
              : null,
        ),
        child: Container(
          width: thumb,
          height: thumb,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: value ? kSmoke : kPaper.withValues(alpha: 0.82),
            boxShadow: const [
              BoxShadow(
                color: Color(0x40000000),
                blurRadius: 4,
                offset: Offset(0, 1),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The breathing half of an emphasised [HintPill]: the gold rim and glow whose
/// alpha rides the pulse. Painted *over* an already-built pill, so a 60fps
/// breathe costs one decoration rebuild per frame instead of re-shaping text
/// over the live preview. Non-hit-testing — the pill beneath keeps its taps.
class _PulseOverlay extends StatelessWidget {
  final double pulse;
  final Widget child;
  const _PulseOverlay({required this.pulse, required this.child});

  @override
  Widget build(BuildContext context) => IgnorePointer(
    ignoring: true,
    child: DecoratedBox(
      position: DecorationPosition.foreground,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(kRadiusLg),
        border: Border.all(
          color: kGold.withValues(alpha: 0.5 + 0.4 * pulse),
          width: 1.0,
        ),
        boxShadow: [
          BoxShadow(
            color: kGold.withValues(alpha: 0.10 + 0.20 * pulse),
            blurRadius: 14,
          ),
        ],
      ),
      child: child,
    ),
  );
}

/// The warm gold aura that sits behind a brand moment — the loader's mark, the
/// first-launch wordmark, the paywall's crown. A soft radial bloom of [kGold]
/// fading to nothing, so those screens read as lit from within by the same
/// light.
///
/// Was hand-written three times with the brand gold spelled as raw hex
/// (`0x2EE5C158`), which had already drifted apart in alpha (0x2E vs 0x33).
/// [strength] is the centre alpha; [radius] how far the bloom reaches.
class GoldAura extends StatelessWidget {
  final double height;
  final double strength;
  final double radius;
  const GoldAura({
    super.key,
    required this.height,
    this.strength = 0.18,
    this.radius = 0.75,
  });

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: Container(
      height: height,
      decoration: BoxDecoration(
        gradient: RadialGradient(
          radius: radius,
          colors: [
            kGold.withValues(alpha: strength),
            kGold.withValues(alpha: 0),
          ],
        ),
      ),
    ),
  );
}

/// Present [child] as a centred card that fades up in place.
///
/// The app's one modal gesture for *reference* surfaces — the composition
/// guide, the level-line preferences. Both are cards about the frame you are
/// already looking at, so they arrive **over** the shot rather than travelling
/// across it: a slide-up drags the eye down and away from the thing being
/// explained.
///
/// Deliberately NOT used by the paywall, which is a destination rather than a
/// reference, or by the debug menu, which is a list of actions — a docked
/// sheet is the right shape for both.
///
/// Honours Reduce Motion: the card appears with no transition at all.
Future<T?> showGildedCard<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  String barrierLabel = 'Dismiss',
}) {
  final bool still = reduceMotionOf(context);
  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: true,
    barrierLabel: barrierLabel,
    barrierColor: Colors.black.withValues(alpha: 0.56),
    transitionDuration: still ? Duration.zero : kDurMed,
    // Transparent Material ancestor. Without one, Flutter paints every Text in
    // the card with a yellow DOUBLE UNDERLINE — its "unstyled text" marker for
    // text outside a Material. A bottom sheet supplies this implicitly; a
    // general dialog does not, so the underlines appeared the moment these
    // cards became dialogs. `type: transparency` keeps the glass look intact.
    pageBuilder: (ctx, _, _) =>
        Material(type: MaterialType.transparency, child: builder(ctx)),
    transitionBuilder: (context, anim, _, child) {
      final curved = CurvedAnimation(
        parent: anim,
        curve: kEaseOut,
        reverseCurve: Curves.easeInCubic,
      );
      return FadeTransition(
        opacity: curved,
        // A whisper of scale so it *settles* into place rather than blinking
        // on — the same arrival the rest of the app's chrome uses.
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

// ── Hint pill ────────────────────────────────────────────────────────────────

/// The app's one text bubble: glyph · hairline · message on gradient-faked
/// glass with a gold-tinted rim. The camera's hint dock and the gallery's
/// guide pill and date chip are all this recipe, so a message reads the same
/// wherever it appears. [emphasis] switches to gold text + a gold rim whose
/// alpha rides [pulse] (0..1) for a breathing "Perfect" state.
class HintPill extends StatelessWidget {
  final IconData? icon;
  final Widget? leading; // custom glyph instead of [icon]
  final String text;
  final Widget? below; // optional second line (e.g. the time)
  final bool emphasis;
  final double pulse;

  /// Cap on the pill's width. Defaults to null, meaning "as wide as the
  /// screen sensibly allows" — see [build]. Pass a number only where a
  /// narrower pill is the design.
  final double? maxWidth;
  const HintPill({
    super.key,
    this.icon,
    this.leading,
    required this.text,
    this.below,
    this.emphasis = false,
    this.pulse = 0,
    this.maxWidth,
  });

  /// Widest the pill may get regardless of screen — beyond this a single line
  /// of chrome copy becomes a wall of text rather than a glance.
  static const double _kCap = 340;

  /// Kept clear at each side so the pill reads as a floating dock, not a bar.
  static const double _kSideInset = 24;

  /// A breathing pill, without rebuilding the pill.
  ///
  /// [pulse] only drives three alpha values — the glyph tint, the rim and the
  /// glow. Everything else (the text, its layout, the whole child subtree) is
  /// identical on every frame, so driving a [HintPill] straight from a 60fps
  /// animation re-ran text shaping 60×/second over the live preview. This
  /// builds the pill once and rebuilds only the decoration around it.
  ///
  /// [listenable] ticks the animation; [pulseOf] reads 0..1 from it.
  static Widget breathing({
    Key? key,
    IconData? icon,
    Widget? leading,
    required String text,
    Widget? below,
    double maxWidth = double.nan,
    required Listenable listenable,
    required double Function() pulseOf,
  }) => AnimatedBuilder(
    key: key,
    animation: listenable,
    // Built once: the costly half (text shaping, layout, the child subtree).
    child: HintPill(
      icon: icon,
      leading: leading,
      text: text,
      below: below,
      emphasis: true,
      maxWidth: maxWidth.isNaN ? null : maxWidth,
      pulse: 0,
    ),
    builder: (context, child) => _PulseOverlay(pulse: pulseOf(), child: child!),
  );

  @override
  Widget build(BuildContext context) {
    final Widget? glyph =
        leading ??
        (icon == null
            ? null
            : Icon(
                icon,
                size: 13,
                color: kGold.withValues(
                  alpha: emphasis ? 0.75 + 0.25 * pulse : 0.85,
                ),
              ));
    // A fixed 260pt cap ignored the screen it was docked on: the same pill on
    // a 430pt Pro Max used the same 260pt, and at accessibility text sizes it
    // grew *downward* instead — 620pt tall at AX5, a tower over the
    // viewfinder where board 1b asks for one docked strip. Take the width
    // that is actually there, then cap it.
    final double available = MediaQuery.sizeOf(context).width - _kSideInset * 2;
    final double limit = maxWidth ?? available.clamp(200.0, _kCap);
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: limit, minHeight: 38),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(kRadiusLg),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Colors.white.withValues(alpha: 0.11),
              Colors.white.withValues(alpha: 0.03),
              kSmoke.withValues(alpha: 0.66),
            ],
            stops: const [0.0, 0.42, 1.0],
          ),
          border: Border.all(
            color: kGold.withValues(alpha: emphasis ? 0.5 + 0.4 * pulse : 0.40),
            width: emphasis ? 1.0 : 0.8,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.40),
              blurRadius: 12,
              offset: const Offset(0, 3),
            ),
            if (emphasis)
              BoxShadow(
                color: kGold.withValues(alpha: 0.10 + 0.20 * pulse),
                blurRadius: 14,
              ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (glyph != null) ...[
              glyph,
              const SizedBox(width: 10),
              Container(
                width: 1,
                height: 16,
                color: kPaper.withValues(alpha: 0.16),
              ),
              const SizedBox(width: 12),
            ],
            Flexible(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Text(
                    text,
                    textAlign: TextAlign.center,
                    style: brandLabel(
                      size: emphasis ? 12.5 : 13,
                      weight: emphasis ? FontWeight.w600 : FontWeight.w400,
                      color: emphasis ? kGold : kPaper,
                      letterSpacing: emphasis ? 1.0 : 0.2,
                    ).copyWith(height: 1.25),
                  ),
                  if (below != null) ...[const SizedBox(height: 2), below!],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Sheets ───────────────────────────────────────────────────────────────────
//
// The docked sheet is the app's shape for *destinations* (see showGildedCard
// for reference cards): the paywall, the feedback form, the account. They
// share one body, one handle, one eyebrow, one button, so moving between them
// feels like turning pages of the same object.

/// Present [builder] as a frosted docked sheet that can grow to fit its
/// content, and rides up with the keyboard.
Future<T?> showGildedSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  required String barrierLabel,
}) {
  return showModalBottomSheet<T>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    // A sheet that grows to fit (large text, the keyboard up) stops at the
    // status bar instead of sliding under the clock and the Dynamic Island.
    useSafeArea: true,
    // Named for assistive tech — VoiceOver otherwise announces an anonymous
    // region behind the sheet.
    barrierLabel: barrierLabel,
    builder: builder,
  );
}

/// The sheet's body: deep frost over whatever is behind (a modal can afford a
/// real blur — it is not live chrome), a warm aura glowing up behind the
/// header and a gold-leaf top edge.
///
/// Sizes to [child]; put the scrolling inside it.
class GildedSheet extends StatelessWidget {
  final Widget child;
  const GildedSheet({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: const BorderRadius.vertical(
        top: Radius.circular(kRadiusLg + 8),
      ),
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 28, sigmaY: 28),
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Colors.white.withValues(alpha: 0.12),
                Colors.black.withValues(alpha: 0.62),
                Colors.black.withValues(alpha: 0.82),
              ],
              stops: const [0.0, 0.4, 1.0],
            ),
          ),
          child: Stack(
            children: [
              Positioned(
                top: -100,
                left: -40,
                right: -40,
                child: const GoldAura(height: 260, strength: 0.20),
              ),
              const Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: GildedHairline(height: 1.2),
              ),
              child,
            ],
          ),
        ),
      ),
    );
  }
}

/// The small bar at the top of a docked sheet that says "drag me down".
class SheetHandle extends StatelessWidget {
  const SheetHandle({super.key});

  @override
  Widget build(BuildContext context) => Center(
    child: Container(
      width: 38,
      height: 4,
      margin: const EdgeInsets.only(bottom: 16),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.25),
        borderRadius: BorderRadius.circular(2),
      ),
    ),
  );
}

/// A docked sheet's handle and scrolling body, in one piece.
///
/// When the content is taller than the space (a small phone, large text, the
/// keyboard up), a drag on it only scrolls, so the sheet could never be swiped
/// away. Two things fix that. The handle sits *outside* the scroll view, so
/// dragging it always pulls the sheet down. And a pull past the top of the
/// content closes the sheet, the way iOS sheets behave. Dragging the content
/// also puts the keyboard away.
class GildedSheetBody extends StatefulWidget {
  final EdgeInsets padding;
  final Widget child;
  const GildedSheetBody({
    super.key,
    required this.padding,
    required this.child,
  });

  @override
  State<GildedSheetBody> createState() => _GildedSheetBodyState();
}

class _GildedSheetBodyState extends State<GildedSheetBody> {
  /// How far past the top the content must be pulled before the sheet goes.
  static const double _kPullToClose = 64;

  bool _closing = false;

  bool _onScroll(ScrollUpdateNotification n) {
    final bool pulledPastTop =
        n.dragDetails != null && n.metrics.pixels < -_kPullToClose;
    // Once only: a drag keeps reporting while the route animates away, and a
    // second pop would take the screen underneath with it.
    if (pulledPastTop &&
        !_closing &&
        ModalRoute.of(context)?.isCurrent == true) {
      _closing = true;
      hapticTap();
      Navigator.of(context).pop();
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Full-width drag target: the bottom sheet's own drag handles it.
        const Padding(padding: EdgeInsets.only(top: 14), child: SheetHandle()),
        Flexible(
          child: NotificationListener<ScrollUpdateNotification>(
            onNotification: _onScroll,
            child: SingleChildScrollView(
              // Bouncing, as on iOS, so a pull past the top is measurable
              // (a clamping list reports nothing there).
              physics: const BouncingScrollPhysics(),
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              padding: widget.padding,
              child: widget.child,
            ),
          ),
        ),
      ],
    );
  }
}

/// A gold tracked eyebrow over a sheet or card title: glyph + small caps, the
/// guide card's "✦ GUIDE" recipe.
class GoldEyebrow extends StatelessWidget {
  final IconData icon;
  final String text;
  const GoldEyebrow({
    super.key,
    this.icon = Icons.auto_awesome_rounded,
    required this.text,
  });

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(icon, color: kGold, size: 12),
      const SizedBox(width: 6),
      Flexible(
        child: Text(
          text.toUpperCase(),
          style: brandLabel(
            size: 9,
            weight: FontWeight.w600,
            color: kGold.withValues(alpha: 0.85),
            letterSpacing: 2.8,
          ),
        ),
      ),
    ],
  );
}

/// The gilded CTA bar — polished metal under moving light. A champagne lit lip
/// melts through gold to an antique base; every ~2.8s a soft diagonal light
/// band sweeps across (the "jewellery counter" shimmer), and the bar presses
/// in with a gentle scale. The shimmer lives only on modal sheets — never over
/// the live camera chrome.
///
/// [busy] keeps the bar lit but deaf to taps, and crossfades the label to a
/// small spinner beside [busyLabel] — the wait reads as work in progress, not
/// as a button that went dead.
class GildedButton extends StatefulWidget {
  final String label;
  final VoidCallback? onTap;
  final bool busy;
  final String? busyLabel;
  const GildedButton({
    super.key,
    required this.label,
    this.onTap,
    this.busy = false,
    this.busyLabel,
  });

  @override
  State<GildedButton> createState() => _GildedButtonState();
}

class _GildedButtonState extends State<GildedButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _sweep = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2800),
  );
  bool _pressed = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // The shimmer is decoration: a light band crossing the bar every 2.8s,
    // forever. Under Reduce Motion the bar rests as polished metal instead.
    final still = reduceMotionOf(context);
    if (still && _sweep.isAnimating) {
      _sweep.stop();
    } else if (!still && !_sweep.isAnimating) {
      _sweep.repeat();
    }
  }

  @override
  void dispose() {
    _sweep.dispose();
    super.dispose();
  }

  static const TextStyle _labelStyle = TextStyle(
    color: Colors.black,
    fontSize: 15.5,
    fontWeight: FontWeight.w700,
    letterSpacing: 0.2,
  );

  @override
  Widget build(BuildContext context) {
    final bool tappable = widget.onTap != null && !widget.busy;
    final bool lit = widget.onTap != null || widget.busy;
    // The CTA is a bare GestureDetector (it owns a press scale and a shimmer,
    // so it is not a PopTap); it still has to announce itself as a button.
    return Semantics(
      button: true,
      enabled: tappable,
      child: GestureDetector(
        onTap: tappable ? widget.onTap : null,
        onTapDown: tappable ? (_) => setState(() => _pressed = true) : null,
        onTapUp: tappable ? (_) => setState(() => _pressed = false) : null,
        onTapCancel: () => setState(() => _pressed = false),
        child: AnimatedScale(
          scale: _pressed ? 0.97 : 1.0,
          duration: motionOf(context, kDurFast),
          curve: kEaseOut,
          child: AnimatedContainer(
            duration: motionOf(context, kDurMed),
            curve: kEaseOut,
            // minHeight, not height: at accessibility text sizes the label
            // wraps and a fixed 52pt box clipped it — on the button a user
            // taps to pay. Exactly 52pt at ordinary sizes.
            //
            // The Stack below holds a full-bleed shimmer, which cannot size
            // itself, so the label is the Stack's sizing child.
            constraints: const BoxConstraints(minHeight: 52),
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(kRadiusMd),
              // Metallic gilt: a bright lit lip up top melting through gold
              // into a deeper antique-gold base — a polished bar, not a flat
              // fill.
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: lit
                    ? const [kGoldLit, kGold, kGoldDeep]
                    : [
                        kGold.withValues(alpha: 0.32),
                        kGold.withValues(alpha: 0.29),
                        kGold.withValues(alpha: 0.26),
                      ],
                stops: const [0.0, 0.5, 1.0],
              ),
              boxShadow: [
                BoxShadow(
                  color: kGold.withValues(alpha: lit ? 0.38 : 0.0),
                  blurRadius: 20,
                  offset: const Offset(0, 7),
                ),
              ],
            ),
            child: Stack(
              children: [
                Center(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 10,
                    ),
                    child: AnimatedSwitcher(
                      duration: motionOf(context, kDurFast),
                      switchInCurve: kEaseOut,
                      switchOutCurve: kEaseIn,
                      child: widget.busy
                          ? Row(
                              key: const ValueKey('busy'),
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const SizedBox(
                                  width: 15,
                                  height: 15,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 1.8,
                                    color: Color(0xCC000000),
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Flexible(
                                  child: Text(
                                    widget.busyLabel ?? widget.label,
                                    textAlign: TextAlign.center,
                                    style: _labelStyle,
                                  ),
                                ),
                              ],
                            )
                          : Text(
                              widget.label,
                              key: ValueKey(widget.label),
                              textAlign: TextAlign.center,
                              style: lit
                                  ? _labelStyle
                                  : _labelStyle.copyWith(
                                      color: Colors.black.withValues(
                                        alpha: 0.45,
                                      ),
                                    ),
                            ),
                    ),
                  ),
                ),
                // Light sweep: a soft white band gliding across the metal.
                if (tappable)
                  Positioned.fill(
                    child: IgnorePointer(
                      child: AnimatedBuilder(
                        animation: _sweep,
                        builder: (_, _) => FractionalTranslation(
                          translation: Offset(
                            -1.0 +
                                2.0 * Curves.easeInOut.transform(_sweep.value),
                            0,
                          ),
                          child: const DecoratedBox(
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.centerLeft,
                                end: Alignment.centerRight,
                                colors: [
                                  Color(0x00FFFFFF),
                                  Color(0x59FFFFFF),
                                  Color(0x00FFFFFF),
                                ],
                                stops: [0.35, 0.5, 0.65],
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
        ),
      ),
    );
  }
}

/// A small, muted underlined text link — the legal (Terms / Privacy) row and
/// other quiet asides. Still a real tap target: PopTap's tick and button
/// trait, and a 44pt minimum box around the small text.
class LegalLink extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  const LegalLink({super.key, required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return PopTap(
      onTap: onTap,
      child: Container(
        constraints: const BoxConstraints(minHeight: 44, minWidth: 44),
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Text(
          label,
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.55),
            fontSize: 11,
            decoration: TextDecoration.underline,
            decorationColor: Colors.white.withValues(alpha: 0.35),
          ),
        ),
      ),
    );
  }
}

// ── Inputs ───────────────────────────────────────────────────────────────────

/// The app's text field: a slab of the same smoked glass as the chips, whose
/// rim warms to gold while it has focus. No floating label, no underline, no
/// Material counter — a hint inside, and the caller shows any count itself.
class GildedField extends StatefulWidget {
  final TextEditingController controller;
  final String hint;
  final int minLines;
  final int maxLines;
  final int? maxLength;
  final TextInputType? keyboardType;
  final TextInputAction? textInputAction;
  final Iterable<String>? autofillHints;
  final TextCapitalization textCapitalization;
  final bool autofocus;
  final bool autocorrect;
  final bool enabled;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  const GildedField({
    super.key,
    required this.controller,
    required this.hint,
    this.minLines = 1,
    this.maxLines = 1,
    this.maxLength,
    this.keyboardType,
    this.textInputAction,
    this.autofillHints,
    this.textCapitalization = TextCapitalization.none,
    this.autofocus = false,
    this.autocorrect = true,
    this.enabled = true,
    this.onChanged,
    this.onSubmitted,
  });

  @override
  State<GildedField> createState() => _GildedFieldState();
}

class _GildedFieldState extends State<GildedField> {
  final FocusNode _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _focus.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bool on = _focus.hasFocus;
    final TextStyle text = brandLabel(
      size: 15,
      weight: FontWeight.w400,
      color: kPaper,
      letterSpacing: 0.1,
    ).copyWith(height: 1.4);
    return AnimatedContainer(
      duration: motionOf(context, kDurFast),
      curve: kEaseOut,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Colors.white.withValues(alpha: on ? 0.09 : 0.07),
            Colors.white.withValues(alpha: 0.02),
            kSmoke.withValues(alpha: 0.5),
          ],
          stops: const [0.0, 0.42, 1.0],
        ),
        border: Border.all(
          color: on
              ? kGold.withValues(alpha: 0.7)
              : Colors.white.withValues(alpha: 0.18),
          width: on ? 1.0 : 0.8,
        ),
        boxShadow: [
          BoxShadow(
            color: kGold.withValues(alpha: on ? 0.14 : 0.0),
            blurRadius: 14,
          ),
        ],
      ),
      child: TextField(
        controller: widget.controller,
        focusNode: _focus,
        enabled: widget.enabled,
        autofocus: widget.autofocus,
        autocorrect: widget.autocorrect,
        minLines: widget.minLines,
        maxLines: widget.maxLines,
        keyboardType: widget.keyboardType,
        textInputAction: widget.textInputAction,
        textCapitalization: widget.textCapitalization,
        autofillHints: widget.autofillHints,
        keyboardAppearance: Brightness.dark,
        cursorColor: kGold,
        style: text,
        // A formatter rather than `maxLength`, which would also draw
        // Material's counter under the glass.
        inputFormatters: widget.maxLength == null
            ? null
            : [LengthLimitingTextInputFormatter(widget.maxLength)],
        onChanged: widget.onChanged,
        onSubmitted: widget.onSubmitted,
        // Tapping anywhere else puts the keyboard away, as iOS users expect.
        // Flutter's mobile default is to do nothing. Other text fields share
        // this field's tap group, so hopping between fields doesn't count as
        // "outside" and the keyboard stays up.
        onTapOutside: (_) => _focus.unfocus(),
        decoration: InputDecoration(
          isCollapsed: true,
          border: InputBorder.none,
          hintText: widget.hint,
          hintMaxLines: 4,
          hintStyle: text.copyWith(color: kPaper.withValues(alpha: 0.34)),
        ),
      ),
    );
  }
}

/// A row of equal segments with one gold pill that *glides* between them —
/// the paywall tiers' gilt, at the size of a control. [labels] and [value]
/// are indices so the caller keeps its own enum.
class GildedSegments extends StatelessWidget {
  final List<String> labels;
  final int value;
  final ValueChanged<int> onChanged;
  const GildedSegments({
    super.key,
    required this.labels,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final int n = labels.length;
    final Duration d = motionOf(context, kDurMed);
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: glassChipDecoration(radius: 16),
      child: Stack(
        children: [
          // The pill: sized to one segment, sliding by alignment.
          Positioned.fill(
            child: AnimatedAlign(
              duration: d,
              curve: kEaseOut,
              alignment: Alignment(n == 1 ? 0 : -1 + 2 * value / (n - 1), 0),
              child: FractionallySizedBox(
                widthFactor: 1 / n,
                heightFactor: 1,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        kGoldLit.withValues(alpha: 0.24),
                        kGold.withValues(alpha: 0.14),
                        kGold.withValues(alpha: 0.05),
                      ],
                      stops: const [0.0, 0.35, 1.0],
                    ),
                    border: Border.all(
                      color: kGold.withValues(alpha: 0.85),
                      width: 1.0,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: kGold.withValues(alpha: 0.20),
                        blurRadius: 14,
                        spreadRadius: -3,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          Row(
            children: [
              for (int i = 0; i < n; i++)
                Expanded(
                  child: PopTap(
                    onTap: i == value ? () {} : () => onChanged(i),
                    toggled: i == value,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(minHeight: 38),
                      child: Center(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 6),
                          child: AnimatedDefaultTextStyle(
                            duration: d,
                            curve: kEaseOut,
                            style: brandLabel(
                              size: 13,
                              weight: i == value
                                  ? FontWeight.w600
                                  : FontWeight.w400,
                              color: i == value
                                  ? kGold
                                  : kPaper.withValues(alpha: 0.66),
                              letterSpacing: 0.3,
                            ),
                            child: FittedBox(
                              fit: BoxFit.scaleDown,
                              child: Text(labels[i], maxLines: 1),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

// ── Moments ──────────────────────────────────────────────────────────────────

/// Content that rises a few points into place as it fades in, after
/// [delay]. Stagger a column's children with increasing delays and a sheet
/// *settles* into view rather than blinking on — the same calm arrival as
/// the reference cards. Appears at once under Reduce Motion.
class FadeUp extends StatefulWidget {
  final Widget child;
  final Duration delay;
  const FadeUp({super.key, required this.child, this.delay = Duration.zero});

  @override
  State<FadeUp> createState() => _FadeUpState();
}

class _FadeUpState extends State<FadeUp> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 420),
  );
  late final Animation<double> _t = CurvedAnimation(
    parent: _c,
    curve: kEaseOut,
  );
  Timer? _wait;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_c.value > 0 || _c.isAnimating || _wait != null) return;
    if (reduceMotionOf(context)) {
      _c.value = 1;
    } else if (widget.delay == Duration.zero) {
      _c.forward();
    } else {
      _wait = Timer(widget.delay, () {
        if (mounted) _c.forward();
      });
    }
  }

  @override
  void dispose() {
    _wait?.cancel();
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FadeTransition(
    opacity: _t,
    child: AnimatedBuilder(
      animation: _t,
      child: widget.child,
      builder: (_, child) => Transform.translate(
        offset: Offset(0, 10 * (1 - _t.value)),
        child: child,
      ),
    ),
  );
}

/// A gold ring that draws itself round, then a tick drawn through it — the
/// "it's done" moment after a send. Wall-clock driven, so it takes the same
/// time on any device; complete at once under Reduce Motion.
class DrawnCheck extends StatefulWidget {
  final double size;
  const DrawnCheck({super.key, this.size = 64});

  @override
  State<DrawnCheck> createState() => _DrawnCheckState();
}

class _DrawnCheckState extends State<DrawnCheck>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (reduceMotionOf(context)) {
      _c.value = 1;
    } else if (_c.value == 0 && !_c.isAnimating) {
      _c.forward();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: widget.size,
    child: RepaintBoundary(
      child: AnimatedBuilder(
        animation: _c,
        builder: (_, _) => CustomPaint(painter: _DrawnCheckPainter(_c.value)),
      ),
    ),
  );
}

class _DrawnCheckPainter extends CustomPainter {
  final double t;
  const _DrawnCheckPainter(this.t);

  @override
  void paint(Canvas canvas, Size size) {
    final double ring = Curves.easeInOutCubic.transform(
      (t / 0.62).clamp(0.0, 1.0),
    );
    final double tick = Curves.easeOutCubic.transform(
      ((t - 0.48) / 0.52).clamp(0.0, 1.0),
    );
    final Rect r = Offset.zero & size;
    final double w = size.shortestSide;

    // Soft bloom that swells in with the ring.
    canvas.drawCircle(
      r.center,
      w * 0.5,
      Paint()
        ..shader = RadialGradient(
          colors: [
            kGold.withValues(alpha: 0.22 * ring),
            kGold.withValues(alpha: 0),
          ],
        ).createShader(r),
    );

    final Paint stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..isAntiAlias = true;

    // The ring: machined metal, drawn clockwise from twelve o'clock.
    canvas.drawArc(
      r.deflate(w * 0.08),
      -1.5708,
      6.2832 * ring,
      false,
      stroke
        ..strokeWidth = w * 0.035
        ..shader = const SweepGradient(
          transform: GradientRotation(-2.4),
          colors: [kGoldLit, kGold, kGoldDeep, kGold, kGoldLit],
          stops: [0.0, 0.22, 0.55, 0.82, 1.0],
        ).createShader(r),
    );

    if (tick > 0) {
      final Path path = Path()
        ..moveTo(w * 0.31, w * 0.52)
        ..lineTo(w * 0.44, w * 0.645)
        ..lineTo(w * 0.70, w * 0.38);
      for (final m in path.computeMetrics()) {
        canvas.drawPath(
          m.extractPath(0, m.length * tick),
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeCap = StrokeCap.round
            ..strokeJoin = StrokeJoin.round
            ..strokeWidth = w * 0.05
            ..color = kGoldLit
            ..isAntiAlias = true,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_DrawnCheckPainter old) => old.t != t;
}

/// A [HintPill] that slides down under the status bar for a moment, then
/// leaves — for news that arrives while the user is elsewhere (an email link
/// completing sign-in). One at a time: a new toast replaces the last.
void showPhilyToast(
  BuildContext context,
  String text, {
  IconData icon = Icons.check_rounded,
}) {
  final OverlayState overlay = Overlay.of(context, rootOverlay: true);
  _Toast.current?.remove();
  late final OverlayEntry entry;
  entry = OverlayEntry(
    builder: (_) => _Toast(
      text: text,
      icon: icon,
      onDone: () {
        if (_Toast.current == entry) _Toast.current = null;
        entry.remove();
      },
    ),
  );
  _Toast.current = entry;
  overlay.insert(entry);
}

class _Toast extends StatefulWidget {
  static OverlayEntry? current;

  final String text;
  final IconData icon;
  final VoidCallback onDone;
  const _Toast({required this.text, required this.icon, required this.onDone});

  @override
  State<_Toast> createState() => _ToastState();
}

class _ToastState extends State<_Toast> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: kDurMed,
    reverseDuration: kDurFast,
  );
  Timer? _hold;

  @override
  void initState() {
    super.initState();
    _c.forward();
    _hold = Timer(const Duration(milliseconds: 2800), () async {
      if (!mounted) return;
      await _c.reverse();
      widget.onDone();
    });
  }

  @override
  void dispose() {
    _hold?.cancel();
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final curved = CurvedAnimation(
      parent: _c,
      curve: kEaseOut,
      reverseCurve: kEaseIn,
    );
    final bool still = reduceMotionOf(context);
    return Positioned(
      top: MediaQuery.paddingOf(context).top + 10,
      left: 0,
      right: 0,
      child: IgnorePointer(
        child: Semantics(
          liveRegion: true,
          child: FadeTransition(
            opacity: curved,
            child: SlideTransition(
              position: Tween<Offset>(
                begin: Offset(0, still ? 0 : -0.35),
                end: Offset.zero,
              ).animate(curved),
              child: Center(
                child: HintPill(icon: widget.icon, text: widget.text),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
