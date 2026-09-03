import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:phily/services/phily_pro.dart';
import 'package:phily/theme.dart';
import 'package:url_launcher/url_launcher.dart';

// Apple requires both of these as live, functional links on the paywall.
const String kPrivacyPolicyUrl =
    'https://lucasyan666.github.io/phily-legal/privacy-policy.html';
const String kTermsOfUseUrl =
    'https://lucasyan666.github.io/phily-legal/terms-of-use.html';

/// Present the Phily Pro paywall as a frosted bottom sheet.
Future<void> showPhilyProPaywall(BuildContext context) {
  return showModalBottomSheet(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (_) => const _PaywallSheet(),
  );
}

/// A purchasable tier shown in the paywall.
class _Tier {
  final String id;
  final String name;
  final String cadence; // shown under the price
  final String? badge;
  final String? note; // small line under the name
  const _Tier(this.id, this.name, this.cadence, {this.badge, this.note});
}

class _PaywallSheet extends StatefulWidget {
  const _PaywallSheet();

  @override
  State<_PaywallSheet> createState() => _PaywallSheetState();
}

class _PaywallSheetState extends State<_PaywallSheet> {
  bool _busy = false;
  String _selectedId = PhilyPro.lifetimeId;

  static const List<_Tier> _tiers = [
    _Tier(
      PhilyPro.lifetimeId,
      'Lifetime',
      'one-time',
      badge: 'BEST VALUE',
      note: 'Pay once · yours forever',
    ),
    _Tier(
      PhilyPro.yearlyId,
      'Annual',
      'per year',
      note: 'Billed yearly · best for regulars',
    ),
    _Tier(PhilyPro.monthlyId, 'Monthly', 'per month'),
  ];

  static const List<String> _benefits = [
    'Every composition guide — Rule of Thirds, Phi Grid, Golden Triangles & Spiral',
    'Live subject detection that locks onto the perfect spot',
    'The gravity level dial — never shoot tilted again',
    'Horizon, Cross, Focal Mass, V-Arrangement & more',
  ];

  bool get _selectedIsSub => _selectedId != PhilyPro.lifetimeId;

  Future<void> _purchase() async {
    final p = PhilyPro.instance.productFor(_selectedId);
    if (p == null) return;
    setState(() => _busy = true);
    await PhilyPro.instance.buy(p);
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _restore() async {
    setState(() => _busy = true);
    await PhilyPro.instance.restore();
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _openUrl(String url) async {
    final uri = Uri.parse(url);
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) {
    final pro = PhilyPro.instance;
    final bottom = MediaQuery.of(context).padding.bottom;
    return AnimatedBuilder(
      animation: pro,
      builder: (context, _) {
        final bool active = pro.subscribed || pro.lifetime;
        final ProductDetails? selProduct = pro.productFor(_selectedId);
        return ClipRRect(
          borderRadius: const BorderRadius.vertical(
            top: Radius.circular(kRadiusLg + 8),
          ),
          child: BackdropFilter(
            // Deep frost — the camera scene melts into smoked glass behind the
            // sheet (blur is fine here: this is a modal, not the live chrome).
            filter: ui.ImageFilter.blur(sigmaX: 28, sigmaY: 28),
            child: Container(
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
                  // Warm gold aura glowing up from behind the header — the
                  // sheet feels lit by the brand, not just tinted.
                  Positioned(
                    top: -100,
                    left: -40,
                    right: -40,
                    child: IgnorePointer(
                      child: Container(
                        height: 260,
                        decoration: const BoxDecoration(
                          gradient: RadialGradient(
                            radius: 0.75,
                            colors: [Color(0x33E5C158), Color(0x00E5C158)],
                          ),
                        ),
                      ),
                    ),
                  ),
                  // Gold-leaf top edge, burning brightest at the centre.
                  const Positioned(
                    top: 0,
                    left: 0,
                    right: 0,
                    child: GildedHairline(height: 1.2),
                  ),
                  Padding(
                    padding: EdgeInsets.fromLTRB(24, 14, 24, 18 + bottom),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        // Grab handle.
                        Center(
                          child: Container(
                            width: 38,
                            height: 4,
                            margin: const EdgeInsets.only(bottom: 16),
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: 0.25),
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                        ),
                        Row(
                          children: [
                            const Icon(
                              Icons.workspace_premium_rounded,
                              color: kGold,
                              size: 26,
                            ),
                            const SizedBox(width: 10),
                            // Gilded wordmark — paper melting into gold, like the loader.
                            ShaderMask(
                              shaderCallback: (r) => const LinearGradient(
                                begin: Alignment.topLeft,
                                end: Alignment.bottomRight,
                                colors: [kPaper, kGold],
                                stops: [0.35, 1.0],
                              ).createShader(r),
                              child: Text(
                                'Phily Pro',
                                style: brandDisplay(
                                  size: 28,
                                  weight: FontWeight.w500,
                                  color:
                                      Colors.white, // recoloured by the shader
                                  letterSpacing: 0.2,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Text(
                          active
                              ? (pro.lifetime
                                    ? 'Lifetime unlock active — thank you!'
                                    : 'Your subscription is active.')
                              : pro.trialActive
                              ? '${pro.trialDaysLeft} day(s) left in your free trial'
                              : 'Unlock every composition tool.',
                          style: TextStyle(
                            color: kGold.withValues(alpha: 0.85),
                            fontSize: 13,
                          ),
                        ),
                        const SizedBox(height: 16),
                        for (final b in _benefits)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 10),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                // Gold-ringed check chip — a jewelled tick, not a stock icon.
                                Container(
                                  width: 20,
                                  height: 20,
                                  margin: const EdgeInsets.only(top: 1),
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    gradient: LinearGradient(
                                      begin: Alignment.topLeft,
                                      end: Alignment.bottomRight,
                                      colors: [
                                        kGold.withValues(alpha: 0.30),
                                        kGold.withValues(alpha: 0.06),
                                      ],
                                    ),
                                    border: Border.all(
                                      color: kGold.withValues(alpha: 0.55),
                                      width: 0.8,
                                    ),
                                  ),
                                  child: const Icon(
                                    Icons.check_rounded,
                                    color: kGoldLit,
                                    size: 13,
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Text(
                                    b,
                                    style: TextStyle(
                                      color: kPaper.withValues(alpha: 0.86),
                                      fontSize: 13,
                                      height: 1.3,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        const SizedBox(height: 8),

                        if (active)
                          _PrimaryButton(
                            label: 'Done',
                            onTap: () => Navigator.of(context).maybePop(),
                          )
                        else ...[
                          for (final t in _tiers)
                            _TierRow(
                              tier: t,
                              price: pro.productFor(t.id)?.price,
                              selected: _selectedId == t.id,
                              onTap: () => setState(() => _selectedId = t.id),
                            ),
                          const SizedBox(height: 6),
                          _PrimaryButton(
                            label: _busy
                                ? 'Please wait…'
                                : selProduct == null
                                ? 'Continue'
                                : _selectedIsSub
                                ? 'Subscribe — ${selProduct.price}'
                                : 'Unlock — ${selProduct.price}',
                            onTap: (_busy || selProduct == null)
                                ? null
                                : _purchase,
                          ),
                          const SizedBox(height: 10),
                          Text(
                            _selectedIsSub
                                ? 'Auto-renews until cancelled. Manage or cancel anytime '
                                      'in Settings › Apple ID › Subscriptions.'
                                : 'One-time purchase — unlocks Phily Pro forever.',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.45),
                              fontSize: 10.5,
                              height: 1.35,
                            ),
                          ),
                        ],
                        const SizedBox(height: 2),
                        Center(
                          child: TextButton(
                            onPressed: _busy ? null : _restore,
                            child: Text(
                              'Restore purchases',
                              style: TextStyle(
                                color: Colors.white.withValues(alpha: 0.6),
                                fontSize: 12.5,
                              ),
                            ),
                          ),
                        ),
                        if (!active && selProduct == null && pro.storeReady)
                          Center(
                            child: Text(
                              'Pricing unavailable — check back shortly.',
                              style: TextStyle(
                                color: Colors.white.withValues(alpha: 0.4),
                                fontSize: 11,
                              ),
                            ),
                          ),
                        // Apple-required legal links.
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            _LegalLink(
                              label: 'Terms of Use',
                              onTap: () => _openUrl(kTermsOfUseUrl),
                            ),
                            Text(
                              '  ·  ',
                              style: TextStyle(
                                color: Colors.white.withValues(alpha: 0.3),
                                fontSize: 11,
                              ),
                            ),
                            _LegalLink(
                              label: 'Privacy Policy',
                              onTap: () => _openUrl(kPrivacyPolicyUrl),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// A single selectable pricing tier (radio + name + price + optional badge).
class _TierRow extends StatelessWidget {
  final _Tier tier;
  final String? price;
  final bool selected;
  final VoidCallback onTap;
  const _TierRow({
    required this.tier,
    required this.price,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      // Animated so selection GLIDES between tiers — the gilt fill, rim and
      // glow melt from one row to the next rather than snapping.
      child: AnimatedContainer(
        duration: kDurFast,
        curve: kEaseOut,
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: selected ? null : Colors.white.withValues(alpha: 0.04),
          // Selected tier fills with champagne-lit gilt and lifts on a gold glow.
          gradient: selected
              ? LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    kGoldLit.withValues(alpha: 0.22),
                    kGold.withValues(alpha: 0.14),
                    kGold.withValues(alpha: 0.04),
                  ],
                  stops: const [0.0, 0.35, 1.0],
                )
              : null,
          borderRadius: BorderRadius.circular(kRadiusMd),
          border: Border.all(
            color: selected
                ? kGold.withValues(alpha: 0.9)
                : Colors.white.withValues(alpha: 0.16),
            width: selected ? 1.6 : 1,
          ),
          boxShadow: selected
              ? [
                  BoxShadow(
                    color: kGold.withValues(alpha: 0.22),
                    blurRadius: 18,
                    spreadRadius: -3,
                  ),
                ]
              : null,
        ),
        child: Row(
          children: [
            Icon(
              selected
                  ? Icons.radio_button_checked_rounded
                  : Icons.radio_button_unchecked_rounded,
              color: selected ? kGold : Colors.white.withValues(alpha: 0.4),
              size: 20,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        tier.name,
                        style: brandLabel(
                          size: 15,
                          weight: FontWeight.w600,
                          color: kPaper,
                          letterSpacing: 0.2,
                        ),
                      ),
                      if (tier.badge != null) ...[
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 7,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            // Metallic badge: lit lip → gold → antique base.
                            gradient: const LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [kGoldLit, kGold, kGoldDeep],
                            ),
                            borderRadius: BorderRadius.circular(5),
                            boxShadow: [
                              BoxShadow(
                                color: kGold.withValues(alpha: 0.35),
                                blurRadius: 8,
                              ),
                            ],
                          ),
                          child: Text(
                            tier.badge!,
                            style: const TextStyle(
                              color: Colors.black,
                              fontSize: 9,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 0.4,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                  if (tier.note != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        tier.note!,
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.5),
                          fontSize: 11,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  price ?? '—',
                  style: brandDisplay(
                    size: 17,
                    weight: FontWeight.w600,
                    color: kGold,
                    letterSpacing: 0.2,
                  ),
                ),
                Text(
                  tier.cadence,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.45),
                    fontSize: 10.5,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// A small, muted underlined text link for the legal (Terms / Privacy) row.
class _LegalLink extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  const _LegalLink({required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
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

/// The gilded CTA bar — polished metal under moving light. A champagne lit lip
/// melts through gold to an antique base; every ~2.8s a soft diagonal light
/// band sweeps across (the "jewellery counter" shimmer), and the bar presses
/// in with a gentle scale. The shimmer lives only on this modal sheet — never
/// over the live camera chrome.
class _PrimaryButton extends StatefulWidget {
  final String label;
  final VoidCallback? onTap;
  const _PrimaryButton({required this.label, this.onTap});

  @override
  State<_PrimaryButton> createState() => _PrimaryButtonState();
}

class _PrimaryButtonState extends State<_PrimaryButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _sweep = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2800),
  )..repeat();
  bool _pressed = false;

  @override
  void dispose() {
    _sweep.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bool enabled = widget.onTap != null;
    return GestureDetector(
      onTap: widget.onTap,
      onTapDown: enabled ? (_) => setState(() => _pressed = true) : null,
      onTapUp: enabled ? (_) => setState(() => _pressed = false) : null,
      onTapCancel: () => setState(() => _pressed = false),
      child: AnimatedScale(
        scale: _pressed ? 0.97 : 1.0,
        duration: kDurFast,
        curve: kEaseOut,
        child: Container(
          height: 52,
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(kRadiusMd),
            // Metallic gilt: a bright lit lip up top melting through gold into a
            // deeper antique-gold base — a polished bar, not a flat fill.
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: enabled
                  ? [kGoldLit, kGold, kGoldDeep]
                  : [
                      kGold.withValues(alpha: 0.32),
                      kGold.withValues(alpha: 0.26),
                    ],
              stops: enabled ? const [0.0, 0.5, 1.0] : null,
            ),
            boxShadow: enabled
                ? [
                    BoxShadow(
                      color: kGold.withValues(alpha: 0.38),
                      blurRadius: 20,
                      offset: const Offset(0, 7),
                    ),
                  ]
                : null,
          ),
          child: Stack(
            fit: StackFit.expand,
            children: [
              // Light sweep: a soft white band gliding across the metal.
              if (enabled)
                AnimatedBuilder(
                  animation: _sweep,
                  builder: (_, _) => FractionalTranslation(
                    translation: Offset(
                      -1.0 + 2.0 * Curves.easeInOut.transform(_sweep.value),
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
              Center(
                child: Text(
                  widget.label,
                  style: const TextStyle(
                    color: Colors.black,
                    fontSize: 15.5,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.2,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Trial welcome — the launch popup that replaces the persistent chip
// ─────────────────────────────────────────────────────────────────────────────

/// Announce the free trial once at launch, instead of parking a chip over the
/// viewfinder where it collided with the composition hints and advice bubbles.
///
/// Shown after [PhilyPro.init] has settled (so the day count is real) and only
/// while the trial is actually running. Dismisses to the camera; "See what's
/// included" hands off to the full paywall.
Future<void> showTrialWelcome(BuildContext context) {
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Dismiss',
    // Deep smoke rather than flat black — the chrome's material, not a scrim.
    barrierColor: kSmoke.withValues(alpha: 0.72),
    transitionDuration: const Duration(milliseconds: 340),
    pageBuilder: (_, _, _) => const _TrialWelcomeDialog(),
    transitionBuilder: (_, anim, _, child) {
      // Settle in: the card rises a touch and swells from 96% — the same
      // unhurried easing as the rest of the app's chrome.
      final curved = CurvedAnimation(
        parent: anim,
        curve: Curves.easeOutCubic,
        reverseCurve: Curves.easeInCubic,
      );
      return FadeTransition(
        opacity: curved,
        child: SlideTransition(
          position: Tween(
            begin: const Offset(0, 0.04),
            end: Offset.zero,
          ).animate(curved),
          child: ScaleTransition(
            scale: Tween(begin: 0.96, end: 1.0).animate(curved),
            child: child,
          ),
        ),
      );
    },
  );
}

class _TrialWelcomeDialog extends StatelessWidget {
  const _TrialWelcomeDialog();

  @override
  Widget build(BuildContext context) {
    final pro = PhilyPro.instance;
    final int d = pro.trialDaysLeft;
    final String headline = d <= 0
        ? 'Your free trial ends today'
        : d == PhilyPro.trialDays
        ? 'Your free trial starts now'
        : '$d day${d == 1 ? '' : 's'} left in your trial';

    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 28),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 380),
          // The app's shared glass — same material as the camera chrome and the
          // gallery's bubbles, so the popup reads as part of the instrument.
          child: GlassSurface(
            borderRadius: BorderRadius.circular(kRadiusLg),
            padding: const EdgeInsets.fromLTRB(24, 26, 24, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Gilded seal — the paywall's premium mark, ringed in machined
                // gold like the level dial's bezel.
                Center(
                  child: SizedBox(
                    width: 58,
                    height: 58,
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        Container(
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            gradient: RadialGradient(
                              colors: [
                                kGold.withValues(alpha: 0.22),
                                Colors.transparent,
                              ],
                              stops: const [0.0, 0.78],
                            ),
                          ),
                        ),
                        const CustomPaint(
                          size: Size(58, 58),
                          painter: MetalRingPainter(width: 2.0),
                        ),
                        const Icon(
                          Icons.workspace_premium_rounded,
                          color: kGold,
                          size: 26,
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                // Gilded wordmark — paper melting into gold, like the loader
                // and the paywall header.
                Center(
                  child: ShaderMask(
                    shaderCallback: (r) => const LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [kPaper, kGold],
                      stops: [0.35, 1.0],
                    ).createShader(r),
                    child: Text(
                      'Phily Pro',
                      style: brandDisplay(
                        size: 26,
                        weight: FontWeight.w500,
                        color: Colors.white, // recoloured by the shader
                        letterSpacing: 0.2,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                Center(
                  child: Text(
                    headline.toUpperCase(),
                    textAlign: TextAlign.center,
                    style: brandLabel(
                      size: 10.5,
                      weight: FontWeight.w600,
                      color: kGold,
                      letterSpacing: 2.0,
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                const GildedHairline(opacity: 0.5),
                const SizedBox(height: 14),
                Text(
                  'Every composition guide is unlocked while your trial runs — '
                  'the grids, the golden ratio, the horizon level, all of it.',
                  textAlign: TextAlign.center,
                  style: brandLabel(
                    size: 12.5,
                    weight: FontWeight.w400,
                    color: kPaper.withValues(alpha: 0.72),
                    letterSpacing: 0.3,
                  ),
                ),
                const SizedBox(height: 20),
                // Primary: straight into the shot. The trial needs no action,
                // so the calm option is the default one.
                _TrialWelcomeButton(
                  label: 'Start shooting',
                  primary: true,
                  onTap: () {
                    hapticTap();
                    Navigator.of(context).pop();
                  },
                ),
                const SizedBox(height: 8),
                _TrialWelcomeButton(
                  label: "See what's included",
                  primary: false,
                  onTap: () {
                    hapticTap();
                    Navigator.of(context).pop();
                    showPhilyProPaywall(context);
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Buttons for the welcome popup: the primary wears the polished-gold fill of
/// the paywall's purchase button, the secondary a quiet glass rim.
class _TrialWelcomeButton extends StatelessWidget {
  final String label;
  final bool primary;
  final VoidCallback onTap;
  const _TrialWelcomeButton({
    required this.label,
    required this.primary,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        height: 46,
        alignment: Alignment.center,
        decoration: primary
            ? BoxDecoration(
                borderRadius: BorderRadius.circular(kRadiusLg),
                gradient: const LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [kGoldLit, kGold, kGoldDeep],
                ),
                boxShadow: [
                  BoxShadow(
                    color: kGold.withValues(alpha: 0.28),
                    blurRadius: 14,
                  ),
                ],
              )
            : glassChipDecoration(radius: kRadiusLg),
        child: Text(
          label,
          style: primary
              ? const TextStyle(
                  color: Colors.black,
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.2,
                )
              : brandLabel(
                  size: 12.5,
                  weight: FontWeight.w600,
                  color: kPaper.withValues(alpha: 0.80),
                  letterSpacing: 1.4,
                ),
        ),
      ),
    );
  }
}
