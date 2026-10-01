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
  return showGildedSheet(
    context: context,
    barrierLabel: 'Dismiss Phily Pro',
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
        // The shared frosted sheet: the camera scene melts into smoked glass
        // behind it, under the gold aura and gold-leaf edge.
        return GildedSheet(
          // Scrolls when it must: the content is a fixed Column, so on
          // any phone shorter than it the paywall simply CLIPPED —
          // 233pt off the bottom of an SE at the default text size,
          // taking the purchase buttons with it. A user could not buy.
          child: GildedSheetBody(
            padding: EdgeInsets.fromLTRB(24, 0, 24, 18 + bottom),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    const Icon(
                      Icons.workspace_premium_rounded,
                      color: kGold,
                      size: 26,
                    ),
                    const SizedBox(width: 10),
                    // Flexible: the wordmark grows with the text size
                    // and pushed this row 215pt past the edge at AX2.
                    Flexible(
                      child:
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
                                color: Colors.white, // recoloured by the shader
                                letterSpacing: 0.2,
                              ),
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
                  GildedButton(
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
                  GildedButton(
                    label: _busy
                        ? 'Please wait…'
                        : selProduct == null
                        ? 'Continue'
                        : _selectedIsSub
                        ? 'Subscribe — ${selProduct.price}'
                        : 'Unlock — ${selProduct.price}',
                    onTap: (_busy || selProduct == null) ? null : _purchase,
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
                // Apple-required legal links. A Wrap, not a Row: both
                // links carry a 44pt minimum tap target, so on a
                // narrow phone the pair plus its separator overflowed
                // the row — they drop to a second line instead.
                Wrap(
                  alignment: WrapAlignment.center,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    LegalLink(
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
                    LegalLink(
                      label: 'Privacy Policy',
                      onTap: () => _openUrl(kPrivacyPolicyUrl),
                    ),
                  ],
                ),
              ],
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
    // PopTap, like every other control in the app: the row ticks and bubbles
    // on tap, is announced as a selectable button, and stills under Reduce
    // Motion. `constraints` guarantees the 44pt minimum target — the padding
    // alone left short rows under it.
    return PopTap(
      onTap: onTap,
      semanticLabel: price == null
          ? tier.name
          : '${tier.name}, $price ${tier.cadence}',
      toggled: selected,
      // Animated so selection GLIDES between tiers — the gilt fill, rim and
      // glow melt from one row to the next rather than snapping.
      child: AnimatedContainer(
        duration: motionOf(context, kDurFast),
        curve: kEaseOut,
        constraints: const BoxConstraints(minHeight: 44),
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
                      // Flexible: the name sits beside a badge and a price
                      // column, and an unconstrained Text here overflowed the
                      // row by up to 60pt on an SE at the DEFAULT text size.
                      Flexible(
                        child: Text(
                          tier.name,
                          overflow: TextOverflow.ellipsis,
                          style: brandLabel(
                            size: 15,
                            weight: FontWeight.w600,
                            color: kPaper,
                            letterSpacing: 0.2,
                          ),
                        ),
                      ),
                      if (tier.badge != null) ...[
                        const SizedBox(width: 8),
                        // Flexible: "BEST VALUE" at AX sizes is wider than the
                        // row can give it beside the name.
                        Flexible(
                          child: Container(
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
            const SizedBox(width: 8),
            // Flexible too: at accessibility text sizes the price and the tier
            // name were both unconstrained in one row and fought for the same
            // width, overflowing by up to 492pt. Now each takes what it needs
            // and the price wins ties (it is the number being decided on).
            Flexible(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    price ?? '—',
                    textAlign: TextAlign.end,
                    style: brandDisplay(
                      size: 17,
                      weight: FontWeight.w600,
                      color: kGold,
                      letterSpacing: 0.2,
                    ),
                  ),
                  Text(
                    tier.cadence,
                    textAlign: TextAlign.end,
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.45),
                      fontSize: 10.5,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
