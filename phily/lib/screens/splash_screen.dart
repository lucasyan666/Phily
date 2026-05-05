import 'package:flutter/material.dart';
import 'dart:math';

class FibonacciSpiralPainter extends CustomPainter {
  final double rotationAngle;

  FibonacciSpiralPainter({this.rotationAngle = 0});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0xFFD4A574)
      ..strokeWidth = 3.0
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    final center = Offset(size.width / 2, size.height / 2);
    final fibonacci = [1, 1, 2, 3, 5, 8, 13, 21, 34];
    final maxFib = fibonacci.reduce((a, b) => a > b ? a : b).toDouble();

    double radius = 5;
    double angle = rotationAngle;

    for (int i = 0; i < fibonacci.length; i++) {
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
  bool shouldRepaint(FibonacciSpiralPainter oldDelegate) =>
      oldDelegate.rotationAngle != rotationAngle;
}

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _fadeAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 850),
      vsync: this,
    );

    _fadeAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeIn),
    );

    _controller.forward();

    // Navigate to home after 3 seconds
    Future.delayed(const Duration(milliseconds: 850), () {
      if (mounted) {
        Navigator.of(context).pushReplacementNamed('/home');
      }
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFD4E4F7),
      body: Center(
        child: FadeTransition(
          opacity: _fadeAnimation,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // Fibonacci spiral
              SizedBox(
                width: 150,
                height: 150,
                child: CustomPaint(
                  painter: FibonacciSpiralPainter(
                    rotationAngle: _controller.value * 2 * pi,
                  ),
                ),
              ),
              const SizedBox(height: 40),
              // App name
              const Text(
                'Phily',
                style: TextStyle(
                  fontSize: 32,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF4A5B7C),
                  letterSpacing: 2,
                ),
              ),
              const SizedBox(height: 40),
              // Loading text
              const Text(
                'Loading...',
                style: TextStyle(
                  fontSize: 12,
                  color: Color(0xFF8B9BB4),
                  fontStyle: FontStyle.italic,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
