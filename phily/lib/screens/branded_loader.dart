import 'dart:math';
import 'package:flutter/material.dart';
import 'package:phily/theme.dart';

/// Fibonacci-spiral mark — gold hairline segments stepping outward from the
/// centre by Fibonacci radii, rotating a quarter-turn at each step.
class FibonacciSpiralPainter extends CustomPainter {
  final double rotationAngle;
  final Color color;

  const FibonacciSpiralPainter({this.rotationAngle = 0, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 2.5
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    final center = Offset(size.width / 2, size.height / 2);
    const fibonacci = [1, 1, 2, 3, 5, 8, 13, 21, 34];
    const maxFib = 34.0;

    double radius = 5;
    double angle = rotationAngle;

    for (var i = 0; i < fibonacci.length; i++) {
      final scale = fibonacci[i] / maxFib * 40;
      final x1 = center.dx + radius * cos(angle);
      final y1 = center.dy + radius * sin(angle);

      radius += scale;
      angle += pi / 2;

      final x2 = center.dx + radius * cos(angle);
      final y2 = center.dy + radius * sin(angle);

      canvas.drawLine(Offset(x1, y1), Offset(x2, y2), paint);
    }
  }

  @override
  bool shouldRepaint(FibonacciSpiralPainter old) =>
      old.rotationAngle != rotationAngle || old.color != color;
}

/// Full-screen branded loading state shown only while the camera is starting
/// up. Unlike the old timer-based splash, this is gated on real readiness by
/// the caller — it vanishes the instant the preview is live. Dark-themed to
/// match the camera UI so there's no seam when it crossfades away.
class BrandedLoader extends StatefulWidget {
  const BrandedLoader({super.key});

  @override
  State<BrandedLoader> createState() => _BrandedLoaderState();
}

class _BrandedLoaderState extends State<BrandedLoader>
    with SingleTickerProviderStateMixin {
  late final AnimationController _spin;

  @override
  void initState() {
    super.initState();
    // Slow, continuous rotation — calm rather than busy.
    _spin = AnimationController(
      duration: const Duration(seconds: 5),
      vsync: this,
    )..repeat();
  }

  @override
  void dispose() {
    _spin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const gold = kGold;
    return Container(
      color: Colors.black,
      child: Center(
        // Gentle one-shot fade + rise so the mark settles in rather than popping.
        child: TweenAnimationBuilder<double>(
          tween: Tween(begin: 0, end: 1),
          duration: const Duration(milliseconds: 750),
          curve: Curves.easeOutCubic,
          builder: (_, t, child) => Opacity(
            opacity: t,
            child: Transform.translate(
              offset: Offset(0, (1 - t) * 14),
              child: child,
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // The φ-spiral mark, lit from within by a soft gold aura.
              SizedBox(
                width: 160,
                height: 160,
                child: Stack(
                  alignment: Alignment.center,
                  clipBehavior: Clip.none,
                  children: [
                    Container(
                      width: 160,
                      height: 160,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: RadialGradient(
                          colors: [
                            gold.withValues(alpha: 0.16),
                            Colors.transparent,
                          ],
                          stops: const [0.0, 0.72],
                        ),
                      ),
                    ),
                    AnimatedBuilder(
                      animation: _spin,
                      builder: (_, _) => CustomPaint(
                        size: const Size(150, 150),
                        painter: FibonacciSpiralPainter(
                          rotationAngle: _spin.value * 2 * pi,
                          color: gold,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 42),
              // Wordmark — editorial serif, finished with a gilded gradient.
              ShaderMask(
                shaderCallback: (r) => const LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [kPaper, kGold],
                  stops: [0.3, 1.0],
                ).createShader(r),
                child: Text(
                  'Phily',
                  style: brandDisplay(
                    size: 52,
                    weight: FontWeight.w400,
                    color: Colors.white, // recoloured by the shader
                    letterSpacing: 0.5,
                  ),
                ),
              ),
              const SizedBox(height: 20),
              // Fine gold rule.
              Container(
                width: 44,
                height: 1,
                color: gold.withValues(alpha: 0.5),
              ),
              const SizedBox(height: 16),
              // Pronunciation — the name is from φ ("phi", as in Phi Grid), not
              // "Philly". Tracked caps so it reads as a refined maison tagline.
              Text(
                'PRONOUNCED  “FY-LEE”',
                style: brandLabel(
                  size: 10,
                  weight: FontWeight.w500,
                  color: gold.withValues(alpha: 0.68),
                  letterSpacing: 3,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
