import 'dart:ui' as ui;

import 'package:flutter/material.dart';
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

class _PaywallSheet extends StatefulWidget {
  const _PaywallSheet();

  @override
  State<_PaywallSheet> createState() => _PaywallSheetState();
}

class _PaywallSheetState extends State<_PaywallSheet> {
  bool _busy = false;

  static const List<String> _benefits = [
    'Every composition guide — Rule of Thirds, Phi Grid, Golden Triangles & Spiral',
    'Live subject detection that locks onto the perfect spot',
    'The gravity level dial — never shoot tilted again',
    'Horizon, Cross, Focal Mass, V-Arrangement & more',
  ];

  Future<void> _subscribe() async {
    setState(() => _busy = true);
    await PhilyPro.instance.subscribe();
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
        final bool active = pro.subscribed;
        return ClipRRect(
          borderRadius: const BorderRadius.vertical(
            top: Radius.circular(kRadiusLg + 8),
          ),
          child: BackdropFilter(
            filter: ui.ImageFilter.blur(sigmaX: 24, sigmaY: 24),
            child: Container(
              padding: EdgeInsets.fromLTRB(24, 14, 24, 20 + bottom),
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
                      margin: const EdgeInsets.only(bottom: 18),
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
                        ? 'Your subscription is active.'
                        : pro.trialActive
                        ? '${pro.trialDaysLeft} day(s) left in your free trial'
                        : 'Unlock every composition tool.',
                    style: TextStyle(
                      color: kGold.withValues(alpha: 0.85),
                      fontSize: 13,
                    ),
                  ),
                  const SizedBox(height: 18),
                  for (final b in _benefits)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
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
                                fontSize: 13.5,
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
                  else
                    _PrimaryButton(
                      label: _busy
                          ? 'Please wait…'
                          : pro.priceLabel.isNotEmpty
                          ? 'Subscribe — ${pro.priceLabel}/mo'
                          : 'Subscribe to Phily Pro',
                      onTap: (_busy || pro.product == null) ? null : _subscribe,
                    ),
                  const SizedBox(height: 6),
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
                  if (!active && pro.product == null && pro.storeReady)
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
