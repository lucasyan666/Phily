import 'package:flutter/material.dart';
import 'package:phily/theme.dart';

/// First launch, one screen (redesign board 1f). No carousel, no lesson: one
/// sentence about what the app does, one button, and the trial as a footnote
/// rather than a headline. Shown once, ever — see [LaunchGate].
class WelcomeScreen extends StatelessWidget {
  final VoidCallback onContinue;
  const WelcomeScreen({super.key, required this.onContinue});

  @override
  Widget build(BuildContext context) {
    final pad = MediaQuery.of(context).padding;
    return Scaffold(
      backgroundColor: kBackground,
      body: Stack(
        children: [
          // Warm aura behind the wordmark — the loader's glow, so the first
          // screen and the loading screen read as one moment.
          Positioned(
            top: -120,
            left: -80,
            right: -80,
            child: IgnorePointer(
              child: Container(
                height: 420,
                decoration: const BoxDecoration(
                  gradient: RadialGradient(
                    radius: 0.7,
                    colors: [Color(0x2EE5C158), Color(0x00E5C158)],
                  ),
                ),
              ),
            ),
          ),
          Padding(
            padding: EdgeInsets.fromLTRB(28, pad.top + 24, 28, pad.bottom + 22),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Spacer(flex: 3),
                // Gilded wordmark — paper melting into gold.
                ShaderMask(
                  shaderCallback: (r) => const LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [kPaper, kGold],
                    stops: [0.35, 1.0],
                  ).createShader(r),
                  child: Text(
                    'Phily',
                    style: brandDisplay(
                      size: 44,
                      weight: FontWeight.w300,
                      color: Colors.white, // recoloured by the shader
                      letterSpacing: -0.5,
                    ),
                  ),
                ),
                const SizedBox(height: 22),
                Text(
                  'Point at something.\nWe\'ll show you where it belongs.',
                  style: brandDisplay(
                    size: 27,
                    weight: FontWeight.w400,
                    color: kPaper,
                    height: 1.18,
                  ),
                ),
                const SizedBox(height: 18),
                Text(
                  'No lesson to read. A dot lights up when your subject is in '
                  'the right place, and the phone buzzes when it\'s square.',
                  style: brandLabel(
                    size: 14.5,
                    weight: FontWeight.w400,
                    color: kPaper.withValues(alpha: 0.62),
                    letterSpacing: 0.1,
                  ).copyWith(height: 1.5),
                ),
                const Spacer(flex: 4),
                _OpenCameraButton(onTap: onContinue),
                const SizedBox(height: 14),
                Center(
                  child: Text(
                    '7 days of everything, free. No card.',
                    style: brandLabel(
                      size: 11.5,
                      weight: FontWeight.w400,
                      color: kPaper.withValues(alpha: 0.42),
                      letterSpacing: 0.3,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The paywall's polished-gold CTA, reused so the first button anyone taps in
/// the app is the same object as the one that unlocks it.
class _OpenCameraButton extends StatelessWidget {
  final VoidCallback onTap;
  const _OpenCameraButton({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () {
        hapticTap();
        onTap();
      },
      behavior: HitTestBehavior.opaque,
      child: Container(
        height: 54,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(kRadiusLg),
          gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [kGoldLit, kGold, kGoldDeep],
          ),
          boxShadow: [
            BoxShadow(color: kGold.withValues(alpha: 0.30), blurRadius: 18),
          ],
        ),
        child: const Text(
          'Open the camera',
          style: TextStyle(
            color: Colors.black,
            fontSize: 16,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.2,
          ),
        ),
      ),
    );
  }
}
