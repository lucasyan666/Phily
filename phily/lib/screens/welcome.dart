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
          // One screen when it fits — the Spacers place the copy — and a scroll
          // only when it can't (large accessibility text, a landscape hold), so
          // the button and footnote are never clipped off the bottom. Side
          // insets include the safe area: in landscape the sensor housing sits
          // at the left or right edge, not the top.
          LayoutBuilder(
            builder: (context, box) {
              final inset = EdgeInsets.fromLTRB(
                28 + pad.left,
                pad.top + 24,
                28 + pad.right,
                pad.bottom + 22,
              );
              return SingleChildScrollView(
                padding: inset,
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    minHeight: (box.maxHeight - inset.vertical).clamp(
                      0.0,
                      double.infinity,
                    ),
                  ),
                  child: IntrinsicHeight(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Spacer(flex: 3),
                        // Gilded wordmark — the same object the loader draws.
                        const GildedWordmark(
                          size: 44,
                          weight: FontWeight.w300,
                          letterSpacing: -0.5,
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
                ),
              );
            },
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
    // PopTap, like every other control: it brings the selection tick (which
    // replaces the manual hapticTap here), the 114% bubble, the button trait
    // and Reduce Motion. This is the first button anyone taps in the app —
    // it should feel like the rest of it.
    return PopTap(
      onTap: onTap,
      semanticLabel: 'Open the camera',
      // minHeight, not height: at accessibility text sizes the label wraps
      // and the button grows with it instead of the type spilling past the
      // gold. At default sizes this is exactly 54pt, as before.
      child: Container(
        constraints: const BoxConstraints(minHeight: 54),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
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
          textAlign: TextAlign.center,
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
