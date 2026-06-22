import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:phily/services/phily_pro.dart';
import 'package:phily/theme.dart';

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
            filter: ui.ImageFilter.blur(sigmaX: 24, sigmaY: 24),
            child: Container(
              padding: EdgeInsets.fromLTRB(24, 14, 24, 18 + bottom),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.white.withValues(alpha: 0.10),
                    Colors.black.withValues(alpha: 0.72),
                  ],
                ),
                border: Border(
                  top: BorderSide(color: kGold.withValues(alpha: 0.45)),
                ),
              ),
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
                      Text(
                        'Phily Pro',
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.95),
                          fontSize: 22,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 0.3,
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
                          const Icon(
                            Icons.check_circle_rounded,
                            color: kGold,
                            size: 18,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              b,
                              style: TextStyle(
                                color: Colors.white.withValues(alpha: 0.85),
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
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: selected
              ? kGold.withValues(alpha: 0.12)
              : Colors.white.withValues(alpha: 0.04),
          borderRadius: BorderRadius.circular(kRadiusMd),
          border: Border.all(
            color: selected
                ? kGold.withValues(alpha: 0.9)
                : Colors.white.withValues(alpha: 0.16),
            width: selected ? 1.6 : 1,
          ),
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
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
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
                            color: kGold,
                            borderRadius: BorderRadius.circular(5),
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
                  style: const TextStyle(
                    color: kGold,
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
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

class _PrimaryButton extends StatelessWidget {
  final String label;
  final VoidCallback? onTap;
  const _PrimaryButton({required this.label, this.onTap});

  @override
  Widget build(BuildContext context) {
    final bool enabled = onTap != null;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 52,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(kRadiusMd),
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              kGold.withValues(alpha: enabled ? 0.95 : 0.35),
              kGold.withValues(alpha: enabled ? 0.78 : 0.28),
            ],
          ),
          boxShadow: enabled
              ? [
                  BoxShadow(
                    color: kGold.withValues(alpha: 0.30),
                    blurRadius: 16,
                    offset: const Offset(0, 6),
                  ),
                ]
              : null,
        ),
        child: Text(
          label,
          style: const TextStyle(
            color: Colors.black,
            fontSize: 15.5,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.2,
          ),
        ),
      ),
    );
  }
}
