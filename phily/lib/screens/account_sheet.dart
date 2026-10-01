import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:path_parsing/path_parsing.dart';
import 'package:phily/screens/feedback_sheet.dart';
import 'package:phily/screens/paywall.dart';
import 'package:phily/services/account.dart';
import 'package:phily/services/feedback.dart';
import 'package:phily/services/phily_pro.dart';
import 'package:phily/theme.dart';
import 'package:url_launcher/url_launcher.dart';

/// Where the account sheet sends the user next. The sheet closes first and
/// the caller opens the next one, so only ever one sheet is on screen.
enum _Next { feedback, composition, pro }

/// Open the account sheet, then whatever the user picked from it.
Future<void> openAccount(BuildContext context) async {
  final _Next? next = await showGildedSheet<_Next>(
    context: context,
    barrierLabel: 'Dismiss account',
    builder: (_) => const AccountSheet(),
  );
  if (!context.mounted) return;
  switch (next) {
    case _Next.feedback:
      await showFeedbackSheet(context);
    case _Next.composition:
      await showFeedbackSheet(context, kind: FeedbackKind.composition);
    case _Next.pro:
      await showPhilyProPaywall(context);
    case null:
      break;
  }
}

/// The round glass button that opens the account sheet — a person glyph when
/// signed out, the user's initial in gold when signed in.
class AccountButton extends StatefulWidget {
  final double size;
  const AccountButton({super.key, this.size = 40});

  @override
  State<AccountButton> createState() => _AccountButtonState();
}

class _AccountButtonState extends State<AccountButton> {
  @override
  void initState() {
    super.initState();
    PhilyAccount.instance.ensureStarted();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: PhilyAccount.instance,
      builder: (context, _) {
        final acct = PhilyAccount.instance;
        final String? initial = _initialOf(acct);
        return PopTap(
          onTap: () => openAccount(context),
          semanticLabel: acct.signedIn
              ? 'Account and feedback, signed in'
              : 'Account and feedback',
          child: AnimatedContainer(
            duration: motionOf(context, kDurFast),
            curve: kEaseOut,
            width: widget.size,
            height: widget.size,
            decoration: glassChipDecoration(
              circle: true,
              active: acct.signedIn,
            ),
            child: AnimatedSwitcher(
              duration: motionOf(context, kDurMed),
              child: initial == null
                  ? Icon(
                      Icons.person_outline_rounded,
                      key: const ValueKey('glyph'),
                      color: kPaper.withValues(alpha: 0.92),
                      size: widget.size * 0.46,
                    )
                  : Center(
                      key: ValueKey(initial),
                      child: Text(
                        initial,
                        style: brandDisplay(
                          size: widget.size * 0.42,
                          weight: FontWeight.w500,
                          color: kGold,
                        ),
                      ),
                    ),
            ),
          ),
        );
      },
    );
  }
}

String? _initialOf(PhilyAccount acct) {
  if (!acct.signedIn) return null;
  final String? src = acct.firstName ?? acct.email;
  if (src == null || src.isEmpty) return null;
  return src.characters.first.toUpperCase();
}

/// Signed out, it offers Apple, Google or an email link, plus feedback and
/// Pro. Signed in, it greets the user and offers sign-out and deletion.
/// Either way the camera works without it — that is said up front.
class AccountSheet extends StatefulWidget {
  const AccountSheet({super.key});

  @override
  State<AccountSheet> createState() => _AccountSheetState();
}

enum _Step { home, email, sent }

class _AccountSheetState extends State<AccountSheet> {
  final TextEditingController _email = TextEditingController();
  _Step _step = _Step.home;

  /// Which action is in flight: 'apple', 'google', 'email', 'delete'.
  String? _busy;
  String? _error;
  bool _confirmDelete = false;

  PhilyAccount get _acct => PhilyAccount.instance;

  @override
  void initState() {
    super.initState();
    _email.addListener(() => setState(() {}));
    _acct.ensureStarted().then((_) {
      if (!mounted) return;
      final String? pending = _acct.pendingEmail;
      // A link is already on its way: reopen at "check your inbox".
      if (pending != null) {
        _email.text = pending;
        setState(() => _step = _Step.sent);
      }
    });
  }

  @override
  void dispose() {
    _email.dispose();
    super.dispose();
  }

  Future<void> _run(String what, Future<bool> Function() action) async {
    setState(() {
      _busy = what;
      _error = null;
    });
    try {
      final bool done = await action();
      if (done) hapticReward();
    } on AccountException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (_) {
      if (mounted) setState(() => _error = 'That didn\'t work. Try again.');
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  Future<void> _sendLink() => _run('email', () async {
    await _acct.sendEmailLink(_email.text);
    if (mounted) setState(() => _step = _Step.sent);
    return false;
  });

  Future<void> _finishLink() => _run('email', () async {
    await _acct.completeEmailLink(_email.text);
    return true;
  });

  Future<void> _delete() => _run('delete', () async {
    final bool gone = await _acct.deleteAccount();
    if (gone && mounted) {
      setState(() {
        _confirmDelete = false;
        _step = _Step.home;
      });
      showPhilyToast(context, 'Your account has been deleted.');
    }
    return false;
  });

  void _go(_Next next) => Navigator.of(context).pop(next);

  @override
  Widget build(BuildContext context) {
    final double keyboard = MediaQuery.viewInsetsOf(context).bottom;
    final double safe = MediaQuery.paddingOf(context).bottom;
    final Duration d = motionOf(context, kDurMed);
    return AnimatedBuilder(
      animation: _acct,
      builder: (context, _) {
        final String key = _acct.signedIn
            ? 'in'
            : _acct.linkAwaitingEmail
            ? 'confirm'
            : _step.name;
        final Widget body = switch (key) {
          'in' => _signedIn(),
          'confirm' => _confirmLink(),
          'email' => _emailStep(),
          'sent' => _sentStep(),
          _ => _home(),
        };
        return AnimatedPadding(
          duration: motionOf(context, kDurFast),
          curve: kEaseOut,
          padding: EdgeInsets.only(bottom: keyboard),
          child: GildedSheet(
            child: GildedSheetBody(
              padding: EdgeInsets.fromLTRB(
                24,
                0,
                24,
                (keyboard > 0 ? 16 : safe + 14),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Steps crossfade in place and the sheet eases to each
                  // one's height, so moving between them reads as the same
                  // card turning over rather than a new screen.
                  AnimatedSize(
                    duration: d,
                    curve: kEaseOut,
                    alignment: Alignment.topCenter,
                    child: AnimatedSwitcher(
                      duration: d,
                      switchInCurve: kEaseOut,
                      switchOutCurve: kEaseIn,
                      layoutBuilder: (current, previous) => Stack(
                        alignment: Alignment.topCenter,
                        children: [...previous, ?current],
                      ),
                      child: KeyedSubtree(key: ValueKey(key), child: body),
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

  // ── Signed out ─────────────────────────────────────────────────────────────

  Widget _home() {
    final bool idle = _busy == null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const FadeUp(
          child: GoldEyebrow(
            icon: Icons.person_outline_rounded,
            text: 'Your Phily',
          ),
        ),
        const SizedBox(height: 6),
        FadeUp(
          delay: const Duration(milliseconds: 40),
          child: Text(
            'Sign in, if you like.',
            style: brandDisplay(size: 26, weight: FontWeight.w500),
          ),
        ),
        const SizedBox(height: 6),
        FadeUp(
          delay: const Duration(milliseconds: 80),
          child: _Body(
            'The camera never needs an account. Signing in lets us reply to '
            'what you send us, and keeps a place for what\'s coming.',
          ),
        ),
        const SizedBox(height: 20),
        FadeUp(
          delay: const Duration(milliseconds: 120),
          child: _ProviderButton(
            logo: const Icon(Icons.apple, color: Colors.black, size: 21),
            // Apple's sign-in button guidelines ask for the system font.
            label: 'Continue with Apple',
            labelStyle: const TextStyle(
              fontFamily: 'CupertinoSystemText',
              fontSize: 16.5,
              fontWeight: FontWeight.w600,
              letterSpacing: -0.2,
              color: Colors.black,
            ),
            busy: _busy == 'apple',
            onTap: idle ? () => _run('apple', _acct.signInWithApple) : null,
          ),
        ),
        const SizedBox(height: 10),
        FadeUp(
          delay: const Duration(milliseconds: 160),
          child: _ProviderButton(
            logo: const CustomPaint(painter: _GoogleGPainter()),
            label: 'Continue with Google',
            // Google's branding guidelines ask for Roboto Medium.
            labelStyle: GoogleFonts.roboto(
              fontSize: 15.5,
              fontWeight: FontWeight.w500,
              color: const Color(0xFF1F1F1F),
            ),
            busy: _busy == 'google',
            onTap: idle ? () => _run('google', _acct.signInWithGoogle) : null,
          ),
        ),
        const SizedBox(height: 10),
        FadeUp(
          delay: const Duration(milliseconds: 200),
          child: _GlassWideButton(
            icon: Icons.mail_outline_rounded,
            label: 'Continue with email',
            onTap: idle
                ? () => setState(() {
                    _error = null;
                    _step = _Step.email;
                  })
                : null,
          ),
        ),
        _errorSlot(),
        const SizedBox(height: 22),
        const GildedHairline(opacity: 0.45),
        const SizedBox(height: 8),
        ..._destinations(delayFrom: 240),
        const SizedBox(height: 4),
        _legalRow(),
      ],
    );
  }

  Widget _emailStep() {
    final bool ok = FeedbackService.isEmail(_email.text);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _BackLink(
          onTap: () => setState(() {
            _error = null;
            _step = _Step.home;
          }),
        ),
        const SizedBox(height: 6),
        const GoldEyebrow(
          icon: Icons.mail_outline_rounded,
          text: 'Sign in with email',
        ),
        const SizedBox(height: 6),
        Text(
          'We\'ll email you a link.',
          style: brandDisplay(size: 26, weight: FontWeight.w500),
        ),
        const SizedBox(height: 6),
        _Body(
          'Open it on this iPhone and you\'re in. No password to remember.',
        ),
        const SizedBox(height: 18),
        GildedField(
          controller: _email,
          hint: 'you@example.com',
          autofocus: true,
          autocorrect: false,
          keyboardType: TextInputType.emailAddress,
          autofillHints: const [AutofillHints.email],
          textInputAction: TextInputAction.send,
          onSubmitted: (_) {
            if (ok && _busy == null) _sendLink();
          },
        ),
        _errorSlot(),
        const SizedBox(height: 16),
        GildedButton(
          label: 'Send link',
          busy: _busy == 'email',
          busyLabel: 'Sending…',
          onTap: ok ? _sendLink : null,
        ),
        const SizedBox(height: 6),
      ],
    );
  }

  Widget _sentStep() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 8),
        const Center(child: _FloatingEnvelope()),
        const SizedBox(height: 18),
        Text(
          'Check your inbox',
          textAlign: TextAlign.center,
          style: brandDisplay(size: 26, weight: FontWeight.w500),
        ),
        const SizedBox(height: 8),
        Text.rich(
          TextSpan(
            children: [
              const TextSpan(text: 'We sent a sign-in link to\n'),
              TextSpan(
                text: _acct.pendingEmail ?? _email.text.trim(),
                style: const TextStyle(color: kGold),
              ),
              const TextSpan(text: '\nOpen it on this iPhone to finish.'),
            ],
          ),
          textAlign: TextAlign.center,
          style: _Body.style.copyWith(height: 1.55),
        ),
        const SizedBox(height: 22),
        GildedButton(
          label: 'Open Mail',
          onTap: () => launchUrl(Uri.parse('message://')),
        ),
        const SizedBox(height: 4),
        Center(
          child: LegalLink(
            label: 'Use a different email',
            onTap: () async {
              await _acct.cancelEmailLink();
              if (mounted) setState(() => _step = _Step.email);
            },
          ),
        ),
      ],
    );
  }

  /// The link was opened on a phone that didn't ask for it; Firebase needs
  /// the address it was sent to before it will sign in.
  Widget _confirmLink() {
    final bool ok = FeedbackService.isEmail(_email.text);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const GoldEyebrow(
          icon: Icons.mark_email_read_outlined,
          text: 'Almost there',
        ),
        const SizedBox(height: 6),
        Text(
          'Finish signing in',
          style: brandDisplay(size: 26, weight: FontWeight.w500),
        ),
        const SizedBox(height: 6),
        _Body('Confirm the email address the link was sent to.'),
        const SizedBox(height: 18),
        GildedField(
          controller: _email,
          hint: 'you@example.com',
          autofocus: true,
          autocorrect: false,
          keyboardType: TextInputType.emailAddress,
          autofillHints: const [AutofillHints.email],
          textInputAction: TextInputAction.done,
        ),
        _errorSlot(),
        const SizedBox(height: 16),
        GildedButton(
          label: 'Sign in',
          busy: _busy == 'email',
          busyLabel: 'Signing in…',
          onTap: ok ? _finishLink : null,
        ),
        const SizedBox(height: 4),
        Center(
          child: LegalLink(
            label: 'Not now',
            onTap: () => _acct.cancelEmailLink(),
          ),
        ),
      ],
    );
  }

  // ── Signed in ──────────────────────────────────────────────────────────────

  Widget _signedIn() {
    final String? name = _acct.firstName;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FadeUp(
          child: Row(
            children: [
              _Avatar(
                photoUrl: _acct.photoUrl,
                initial: _initialOf(_acct) ?? 'P',
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name == null ? 'You\'re signed in' : 'Hello, $name',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: brandDisplay(size: 24, weight: FontWeight.w500),
                    ),
                    if (_acct.email != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        _acct.email!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: _Body.style.copyWith(fontSize: 13),
                      ),
                    ],
                    const SizedBox(height: 7),
                    _ProviderTag(label: 'VIA ${_acct.providerLabel ?? ''}'),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 22),
        const GildedHairline(opacity: 0.45),
        const SizedBox(height: 8),
        ..._destinations(delayFrom: 60),
        const SizedBox(height: 10),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            LegalLink(label: 'Sign out', onTap: _acct.signOut),
            LegalLink(
              label: 'Delete account',
              onTap: () => setState(() {
                _error = null;
                _confirmDelete = !_confirmDelete;
              }),
            ),
          ],
        ),
        // Deletion is confirmed in place, not in a dialog: the sheet opens
        // a panel that says exactly what goes and what stays.
        AnimatedSize(
          duration: motionOf(context, kDurMed),
          curve: kEaseOut,
          alignment: Alignment.topCenter,
          child: !_confirmDelete
              ? const SizedBox(width: double.infinity)
              : _DeletePanel(
                  busy: _busy == 'delete',
                  appleSignIn: _acct.providerLabel == 'Apple',
                  onKeep: () => setState(() => _confirmDelete = false),
                  onDelete: _delete,
                ),
        ),
        _errorSlot(),
        _legalRow(),
      ],
    );
  }

  // ── Shared pieces ──────────────────────────────────────────────────────────

  List<Widget> _destinations({required int delayFrom}) {
    final pro = PhilyPro.instance;
    final String proLine = pro.lifetime
        ? 'Lifetime — thank you'
        : pro.subscribed
        ? 'Subscribed'
        : pro.trialActive
        ? '${pro.trialDaysLeft} ${pro.trialDaysLeft == 1 ? 'day' : 'days'} '
              'left in your free trial'
        : 'See what Pro unlocks';
    final rows = [
      _SheetRow(
        icon: Icons.forum_outlined,
        title: 'Send feedback',
        subtitle: 'Ideas, and anything that feels off',
        onTap: () => _go(_Next.feedback),
      ),
      _SheetRow(
        icon: Icons.auto_awesome_mosaic_outlined,
        title: 'Request a composition',
        subtitle: 'Tell us which guide to build next',
        onTap: () => _go(_Next.composition),
      ),
      _SheetRow(
        icon: Icons.workspace_premium_outlined,
        title: 'Phily Pro',
        subtitle: proLine,
        onTap: () => _go(_Next.pro),
      ),
    ];
    return [
      for (int i = 0; i < rows.length; i++)
        FadeUp(
          delay: Duration(milliseconds: delayFrom + 40 * i),
          child: rows[i],
        ),
    ];
  }

  Widget _errorSlot() => AnimatedSize(
    duration: motionOf(context, kDurMed),
    curve: kEaseOut,
    alignment: Alignment.topCenter,
    child: _error == null
        ? const SizedBox(width: double.infinity)
        : Padding(
            padding: const EdgeInsets.only(top: 14),
            child: Semantics(
              liveRegion: true,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.error_outline_rounded,
                    size: 16,
                    color: kGold.withValues(alpha: 0.9),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _error!,
                      style: _Body.style.copyWith(
                        color: kPaper.withValues(alpha: 0.82),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
  );

  Widget _legalRow() => Wrap(
    alignment: WrapAlignment.center,
    crossAxisAlignment: WrapCrossAlignment.center,
    children: [
      LegalLink(
        label: 'Terms of Use',
        onTap: () => launchUrl(
          Uri.parse(kTermsOfUseUrl),
          mode: LaunchMode.externalApplication,
        ),
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
        onTap: () => launchUrl(
          Uri.parse(kPrivacyPolicyUrl),
          mode: LaunchMode.externalApplication,
        ),
      ),
    ],
  );
}

/// Calm body copy for the sheet.
class _Body extends StatelessWidget {
  final String text;
  const _Body(this.text);

  static TextStyle get style => brandLabel(
    size: 13.5,
    weight: FontWeight.w400,
    color: kPaper.withValues(alpha: 0.6),
    letterSpacing: 0.1,
  ).copyWith(height: 1.45);

  @override
  Widget build(BuildContext context) => Text(text, style: style);
}

/// A sign-in provider's own button: white, with its logo and label in the
/// face its guidelines ask for — the one place the app steps out of gold,
/// because a sign-in button has to be recognisable at a glance.
class _ProviderButton extends StatelessWidget {
  final Widget logo;
  final String label;
  final TextStyle labelStyle;
  final bool busy;
  final VoidCallback? onTap;
  const _ProviderButton({
    required this.logo,
    required this.label,
    required this.labelStyle,
    required this.busy,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return _PressScale(
      // Busy stays fully opaque (it is the thing happening); the others dim
      // while it works.
      onTap: busy ? () {} : onTap,
      semanticLabel: label,
      child: Container(
        constraints: const BoxConstraints(minHeight: 50),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(kRadiusMd),
          boxShadow: const [
            BoxShadow(
              color: Color(0x59000000),
              blurRadius: 14,
              offset: Offset(0, 5),
            ),
          ],
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            SizedBox.square(
              dimension: 20,
              child: AnimatedSwitcher(
                duration: motionOf(context, kDurFast),
                child: busy
                    ? const Padding(
                        key: ValueKey('busy'),
                        padding: EdgeInsets.all(2),
                        child: CircularProgressIndicator(
                          strokeWidth: 1.8,
                          color: Color(0xCC000000),
                        ),
                      )
                    : KeyedSubtree(key: const ValueKey('logo'), child: logo),
              ),
            ),
            const SizedBox(width: 12),
            Flexible(
              child: Text(
                label,
                textAlign: TextAlign.center,
                style: labelStyle,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The email option, in the app's own glass beside the two white buttons.
class _GlassWideButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  const _GlassWideButton({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return _PressScale(
      onTap: onTap,
      semanticLabel: label,
      child: Container(
        constraints: const BoxConstraints(minHeight: 50),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
        decoration: glassChipDecoration(radius: kRadiusMd),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: kGold, size: 19),
            const SizedBox(width: 12),
            Flexible(
              child: Text(
                label,
                textAlign: TextAlign.center,
                style: brandLabel(
                  size: 15.5,
                  weight: FontWeight.w500,
                  color: kPaper,
                  letterSpacing: 0.1,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Press feedback for wide controls. [PopTap]'s 114% swell suits a chip but
/// throws a full-width row past the sheet's edges, so wide targets sink to
/// 98% under the finger instead — same tick, same button trait, same dimming
/// when disabled.
class _PressScale extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;
  final String? semanticLabel;
  const _PressScale({required this.child, this.onTap, this.semanticLabel});

  @override
  State<_PressScale> createState() => _PressScaleState();
}

class _PressScaleState extends State<_PressScale> {
  bool _down = false;

  void _set(bool v) {
    if (_down != v) setState(() => _down = v);
  }

  @override
  Widget build(BuildContext context) {
    final bool enabled = widget.onTap != null;
    return MergeSemantics(
      child: Semantics(
        button: true,
        enabled: enabled,
        label: widget.semanticLabel,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: enabled ? (_) => _set(true) : null,
          onTapUp: enabled ? (_) => _set(false) : null,
          onTapCancel: () => _set(false),
          onTap: enabled
              ? () {
                  hapticTap();
                  widget.onTap!();
                }
              : null,
          child: AnimatedOpacity(
            duration: motionOf(context, kDurFast),
            opacity: enabled ? 1 : 0.4,
            child: AnimatedScale(
              scale: _down ? 0.98 : 1,
              duration: motionOf(context, const Duration(milliseconds: 120)),
              curve: kEaseOut,
              child: widget.child,
            ),
          ),
        ),
      ),
    );
  }
}

/// A destination in the sheet: gold glyph on a glass tile, title, one line
/// of what's there, and a chevron.
class _SheetRow extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  const _SheetRow({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return _PressScale(
      onTap: onTap,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 60),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: glassChipDecoration(radius: 12),
                child: Icon(icon, color: kGold, size: 18),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: brandLabel(
                        size: 15,
                        weight: FontWeight.w500,
                        color: kPaper,
                        letterSpacing: 0.1,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: brandLabel(
                        size: 12,
                        weight: FontWeight.w400,
                        color: kPaper.withValues(alpha: 0.5),
                        letterSpacing: 0.1,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.chevron_right_rounded,
                color: kPaper.withValues(alpha: 0.32),
                size: 22,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _BackLink extends StatelessWidget {
  final VoidCallback onTap;
  const _BackLink({required this.onTap});

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.centerLeft,
    child: PopTap(
      onTap: onTap,
      semanticLabel: 'Back',
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 44, minWidth: 44),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.chevron_left_rounded,
              color: kPaper.withValues(alpha: 0.6),
              size: 22,
            ),
            Text(
              'Back',
              style: brandLabel(
                size: 13,
                weight: FontWeight.w400,
                color: kPaper.withValues(alpha: 0.6),
                letterSpacing: 0.2,
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class _ProviderTag extends StatelessWidget {
  final String label;
  const _ProviderTag({required this.label});

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
    decoration: glassChipDecoration(radius: kRadiusSm, active: true),
    child: Text(
      label,
      style: brandLabel(
        size: 8.5,
        weight: FontWeight.w600,
        color: kGold.withValues(alpha: 0.9),
        letterSpacing: 1.6,
      ),
    ),
  );
}

/// The user in a polished gold bezel: their Google photo, or their initial
/// in the display serif.
class _Avatar extends StatelessWidget {
  final String? photoUrl;
  final String initial;
  const _Avatar({required this.photoUrl, required this.initial});

  @override
  Widget build(BuildContext context) {
    const double size = 60;
    final Widget letter = Center(
      child: Text(
        initial,
        style: brandDisplay(size: 24, weight: FontWeight.w500, color: kGold),
      ),
    );
    return SizedBox.square(
      dimension: size,
      child: Stack(
        fit: StackFit.expand,
        children: [
          Padding(
            padding: const EdgeInsets.all(4),
            child: ClipOval(
              child: DecoratedBox(
                decoration: BoxDecoration(color: kGold.withValues(alpha: 0.08)),
                child: photoUrl == null
                    ? letter
                    : Image.network(
                        photoUrl!,
                        fit: BoxFit.cover,
                        errorBuilder: (_, _, _) => letter,
                      ),
              ),
            ),
          ),
          const CustomPaint(painter: MetalRingPainter(width: 2)),
        ],
      ),
    );
  }
}

/// Deletion, confirmed in place.
class _DeletePanel extends StatelessWidget {
  final bool busy;
  final bool appleSignIn;
  final VoidCallback onKeep;
  final VoidCallback onDelete;
  const _DeletePanel({
    required this.busy,
    required this.appleSignIn,
    required this.onKeep,
    required this.onDelete,
  });

  /// Terracotta: a warning that belongs to the gold palette, not alarm red.
  static const Color _warn = Color(0xFFE08A6F);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(kRadiusMd),
          color: _warn.withValues(alpha: 0.06),
          border: Border.all(color: _warn.withValues(alpha: 0.45), width: 0.8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Delete your account?',
              style: brandLabel(
                size: 15,
                weight: FontWeight.w600,
                color: kPaper,
                letterSpacing: 0.1,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'This removes your account and any feedback linked to it, for '
              'good. Your photos and your Phily Pro purchase aren\'t '
              'affected.'
              '${appleSignIn ? ' Apple will ask you to confirm once more.' : ''}',
              style: _Body.style.copyWith(fontSize: 12.5),
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: _PressScale(
                    onTap: busy ? null : onKeep,
                    semanticLabel: 'Keep my account',
                    child: Container(
                      constraints: const BoxConstraints(minHeight: 44),
                      alignment: Alignment.center,
                      decoration: glassChipDecoration(radius: 12),
                      child: Text(
                        'Keep it',
                        style: brandLabel(
                          size: 14,
                          weight: FontWeight.w500,
                          color: kPaper,
                          letterSpacing: 0.2,
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _PressScale(
                    onTap: busy ? () {} : onDelete,
                    semanticLabel: 'Delete my account',
                    child: Container(
                      constraints: const BoxConstraints(minHeight: 44),
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(12),
                        color: _warn.withValues(alpha: 0.16),
                        border: Border.all(color: _warn.withValues(alpha: 0.8)),
                      ),
                      child: busy
                          ? const SizedBox.square(
                              dimension: 16,
                              child: CircularProgressIndicator(
                                strokeWidth: 1.8,
                                color: _warn,
                              ),
                            )
                          : Text(
                              'Delete',
                              style: brandLabel(
                                size: 14,
                                weight: FontWeight.w600,
                                color: _warn,
                                letterSpacing: 0.2,
                              ),
                            ),
                    ),
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

/// A gold-ringed envelope that bobs gently while the link is on its way.
class _FloatingEnvelope extends StatefulWidget {
  const _FloatingEnvelope();

  @override
  State<_FloatingEnvelope> createState() => _FloatingEnvelopeState();
}

class _FloatingEnvelopeState extends State<_FloatingEnvelope>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2600),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (reduceMotionOf(context)) {
      _c.stop();
    } else if (!_c.isAnimating) {
      _c.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: 76,
      child: Stack(
        fit: StackFit.expand,
        children: [
          const GoldAura(height: 76, strength: 0.22, radius: 0.6),
          const CustomPaint(painter: MetalRingPainter(width: 1.6)),
          AnimatedBuilder(
            animation: _c,
            builder: (_, child) => Transform.translate(
              offset: Offset(0, -3 + 6 * Curves.easeInOut.transform(_c.value)),
              child: child,
            ),
            child: const Icon(
              Icons.mail_outline_rounded,
              color: kGoldLit,
              size: 30,
            ),
          ),
        ],
      ),
    );
  }
}

/// Google's "G", drawn from the paths in Google's own sign-in button artwork
/// (a 48×48 viewBox) so it's the real mark, not a lookalike.
class _GoogleGPainter extends CustomPainter {
  const _GoogleGPainter();

  static final List<(Color, Path)> _marks = [
    (
      const Color(0xFFEA4335),
      _svg(
        'M24 9.5c3.54 0 6.71 1.22 9.21 3.6l6.85-6.85C35.9 2.38 30.47 0 24 0 '
        '14.62 0 6.51 5.38 2.56 13.22l7.98 6.19C12.43 13.72 17.74 9.5 24 9.5z',
      ),
    ),
    (
      const Color(0xFF4285F4),
      _svg(
        'M46.98 24.55c0-1.57-.15-3.09-.38-4.55H24v9.02h12.94c-.58 2.96-2.26 '
        '5.48-4.78 7.18l7.73 6c4.51-4.18 7.09-10.36 7.09-17.65z',
      ),
    ),
    (
      const Color(0xFFFBBC05),
      _svg(
        'M10.53 28.59c-.48-1.45-.76-2.99-.76-4.59s.27-3.14.76-4.59l-7.98-6.19C.92 '
        '16.46 0 20.12 0 24c0 3.88.92 7.54 2.56 10.78l7.97-6.19z',
      ),
    ),
    (
      const Color(0xFF34A853),
      _svg(
        'M24 48c6.48 0 11.93-2.13 15.89-5.81l-7.73-6c-2.15 1.45-4.92 2.3-8.16 '
        '2.3-6.26 0-11.57-4.22-13.47-9.91l-7.98 6.19C6.51 42.62 14.62 48 24 48z',
      ),
    ),
  ];

  static Path _svg(String d) {
    final proxy = _PathBuilder();
    writeSvgPathDataToPath(d, proxy);
    return proxy.path;
  }

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.shortestSide / 48);
    for (final (color, path) in _marks) {
      canvas.drawPath(path, Paint()..color = color);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_GoogleGPainter old) => false;
}

class _PathBuilder extends PathProxy {
  final Path path = Path();

  @override
  void moveTo(double x, double y) => path.moveTo(x, y);

  @override
  void lineTo(double x, double y) => path.lineTo(x, y);

  @override
  void cubicTo(
    double x1,
    double y1,
    double x2,
    double y2,
    double x3,
    double y3,
  ) => path.cubicTo(x1, y1, x2, y2, x3, y3);

  @override
  void close() => path.close();
}
