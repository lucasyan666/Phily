import 'dart:math';
import 'package:flutter/material.dart';

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
    const gold = Color(0xFFE5C158);
    return Container(
      color: Colors.black,
      child: Center(
        // Gentle one-shot fade-in so the mark doesn't pop on launch.
        child: TweenAnimationBuilder<double>(
          tween: Tween(begin: 0, end: 1),
          duration: const Duration(milliseconds: 600),
          curve: Curves.easeOut,
          builder: (_, t, child) => Opacity(opacity: t, child: child),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 150,
                height: 150,
                child: AnimatedBuilder(
                  animation: _spin,
                  builder: (_, _) => CustomPaint(
                    painter: FibonacciSpiralPainter(
                      rotationAngle: _spin.value * 2 * pi,
                      color: gold,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 36),
              const Text(
                'Phily',
                style: TextStyle(
                  fontSize: 30,
                  fontWeight: FontWeight.w300,
                  color: Colors.white,
                  letterSpacing: 6,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
