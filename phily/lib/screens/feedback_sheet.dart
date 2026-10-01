import 'package:flutter/material.dart';
import 'package:phily/screens/paywall.dart' show kPrivacyPolicyUrl;
import 'package:phily/services/account.dart';
import 'package:phily/services/feedback.dart';
import 'package:phily/theme.dart';
import 'package:url_launcher/url_launcher.dart';

/// Open the feedback form. [kind] picks the tab it opens on; [mode] names the
/// composition guide it was opened from, so a request arrives with its
/// context.
Future<void> showFeedbackSheet(
  BuildContext context, {
  FeedbackKind kind = FeedbackKind.idea,
  String? mode,
}) {
  return showGildedSheet<void>(
    context: context,
    barrierLabel: 'Dismiss feedback',
    builder: (_) => FeedbackSheet(initialKind: kind, mode: mode),
  );
}

/// Straight to the people who build Phily: an idea, something that's off, or
/// a composition to add. Email is asked for only if the user switches on
/// "You can reply to me about this", and never stored otherwise.
class FeedbackSheet extends StatefulWidget {
  final FeedbackKind initialKind;
  final String? mode;
  const FeedbackSheet({
    super.key,
    this.initialKind = FeedbackKind.idea,
    this.mode,
  });

  @override
  State<FeedbackSheet> createState() => _FeedbackSheetState();
}

class _FeedbackSheetState extends State<FeedbackSheet> {
  /// A half-written message outlives the sheet: swipe it away by accident
  /// mid-sentence, reopen it, and the words are still there. Cleared once
  /// sent.
  static String _draft = '';

  static const List<String> _tabs = ['Idea', 'Issue', 'Composition'];

  static const Map<FeedbackKind, String> _titles = {
    FeedbackKind.idea: 'What would make Phily better?',
    FeedbackKind.issue: 'What went wrong?',
    FeedbackKind.composition: 'Which composition should we add?',
  };

  static const Map<FeedbackKind, String> _hints = {
    FeedbackKind.idea: 'Something to add, change or take away.',
    FeedbackKind.issue:
        'What happened, and what did you expect? The steps that got you '
        'there help most.',
    FeedbackKind.composition:
        'Name it, or describe the shot: "frame within a frame", "leading '
        'lines", or a photographer who shoots that way.',
  };

  late FeedbackKind _kind = widget.initialKind;
  late final TextEditingController _message = TextEditingController(
    text: _draft,
  );
  final TextEditingController _email = TextEditingController();
  bool _contact = false;
  bool _sending = false;
  bool _sent = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _message.addListener(() {
      _draft = _message.text;
      setState(() {});
    });
    _email.addListener(() => setState(() {}));
    // Signed in? Fill the reply address in advance; it only shows (and is
    // only sent) if they switch contact on.
    PhilyAccount.instance.ensureStarted().then((_) {
      final String? known = PhilyAccount.instance.email;
      if (mounted && known != null && _email.text.isEmpty) {
        _email.text = known;
      }
    });
  }

  @override
  void dispose() {
    _message.dispose();
    _email.dispose();
    super.dispose();
  }

  bool get _emailOk => FeedbackService.isEmail(_email.text);

  bool get _canSend =>
      _message.text.trim().length >= 3 && (!_contact || _emailOk);

  Future<void> _send() async {
    FocusScope.of(context).unfocus();
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      await FeedbackService.send(
        kind: _kind,
        message: _message.text,
        email: _contact ? _email.text : null,
        mode: widget.mode,
      );
      _draft = '';
      hapticReward();
      if (mounted) {
        setState(() {
          _sending = false;
          _sent = true;
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _sending = false;
        _error = e is FeedbackError
            ? e.message
            : 'That didn\'t send. Try again in a moment.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final double keyboard = MediaQuery.viewInsetsOf(context).bottom;
    final double safe = MediaQuery.paddingOf(context).bottom;
    final Duration d = motionOf(context, kDurMed);
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
            (keyboard > 0 ? 16 : safe + 18),
          ),
          child: AnimatedSize(
            duration: d,
            curve: kEaseOut,
            alignment: Alignment.topCenter,
            child: AnimatedSwitcher(
              duration: d,
              switchInCurve: kEaseOut,
              switchOutCurve: kEaseIn,
              transitionBuilder: (child, anim) => FadeTransition(
                opacity: anim,
                child: ScaleTransition(
                  scale: Tween<double>(begin: 0.97, end: 1).animate(anim),
                  child: child,
                ),
              ),
              child: _sent ? _thanks() : _form(),
            ),
          ),
        ),
      ),
    );
  }

  Widget _form() {
    final int length = _message.text.characters.length;
    final Duration d = motionOf(context, kDurMed);
    return Column(
      key: const ValueKey('form'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const FadeUp(child: GoldEyebrow(text: 'Write to the makers')),
        const SizedBox(height: 6),
        FadeUp(
          delay: const Duration(milliseconds: 40),
          // The title follows the tab: each kind asks its own question.
          child: AnimatedSwitcher(
            duration: d,
            switchInCurve: kEaseOut,
            switchOutCurve: kEaseIn,
            layoutBuilder: (current, previous) => Stack(
              alignment: Alignment.centerLeft,
              children: [...previous, ?current],
            ),
            child: Text(
              _titles[_kind]!,
              key: ValueKey(_kind),
              style: brandDisplay(
                size: 25,
                weight: FontWeight.w500,
                height: 1.15,
              ),
            ),
          ),
        ),
        const SizedBox(height: 6),
        FadeUp(
          delay: const Duration(milliseconds: 80),
          child: Text(
            'Every message is read by the person who builds Phily.',
            style: brandLabel(
              size: 13,
              weight: FontWeight.w400,
              color: kPaper.withValues(alpha: 0.58),
              letterSpacing: 0.1,
            ).copyWith(height: 1.4),
          ),
        ),
        if (widget.mode != null) ...[
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: _FromGuideTag(mode: widget.mode!),
          ),
        ],
        const SizedBox(height: 18),
        FadeUp(
          delay: const Duration(milliseconds: 120),
          child: GildedSegments(
            labels: _tabs,
            value: _kind.index,
            onChanged: (i) => setState(() {
              _kind = FeedbackKind.values[i];
              _error = null;
            }),
          ),
        ),
        const SizedBox(height: 12),
        FadeUp(
          delay: const Duration(milliseconds: 160),
          child: GildedField(
            controller: _message,
            hint: _hints[_kind]!,
            // Four lines on an SE-height phone keeps Send above the fold;
            // the box still grows as they write.
            minLines: MediaQuery.sizeOf(context).height < 700 ? 4 : 5,
            maxLines: 9,
            maxLength: FeedbackService.maxLength,
            keyboardType: TextInputType.multiline,
            textCapitalization: TextCapitalization.sentences,
          ),
        ),
        // The count appears only near the limit — a number to watch, not a
        // meter to feel judged by.
        AnimatedOpacity(
          opacity: length > FeedbackService.maxLength * 0.8 ? 1 : 0,
          duration: d,
          child: Padding(
            padding: const EdgeInsets.only(top: 6, right: 4),
            child: Text(
              '$length / ${FeedbackService.maxLength}',
              textAlign: TextAlign.end,
              style: brandLabel(
                size: 11,
                weight: FontWeight.w400,
                color: kPaper.withValues(alpha: 0.45),
                letterSpacing: 0.4,
              ),
            ),
          ),
        ),
        const SizedBox(height: 6),
        FadeUp(
          delay: const Duration(milliseconds: 200),
          child: _ConsentRow(
            value: _contact,
            onChanged: (v) => setState(() {
              _contact = v;
              _error = null;
            }),
          ),
        ),
        // The email field slides open under the switch, and closes with it.
        AnimatedSize(
          duration: d,
          curve: kEaseOut,
          alignment: Alignment.topCenter,
          child: !_contact
              ? const SizedBox(width: double.infinity)
              : Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      GildedField(
                        controller: _email,
                        hint: 'you@example.com',
                        keyboardType: TextInputType.emailAddress,
                        autofillHints: const [AutofillHints.email],
                        autocorrect: false,
                        textInputAction: TextInputAction.done,
                      ),
                      if (_email.text.isNotEmpty && !_emailOk)
                        Padding(
                          padding: const EdgeInsets.only(top: 6, left: 4),
                          child: Text(
                            'That email doesn\'t look right yet.',
                            style: brandLabel(
                              size: 11.5,
                              weight: FontWeight.w400,
                              color: kPaper.withValues(alpha: 0.5),
                              letterSpacing: 0.2,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
        ),
        AnimatedSize(
          duration: d,
          curve: kEaseOut,
          alignment: Alignment.topCenter,
          child: _error == null
              ? const SizedBox(width: double.infinity)
              : Padding(
                  padding: const EdgeInsets.only(top: 14),
                  child: _ErrorLine(_error!),
                ),
        ),
        const SizedBox(height: 18),
        GildedButton(
          label: 'Send',
          busy: _sending,
          busyLabel: 'Sending…',
          onTap: _canSend ? _send : null,
        ),
        const SizedBox(height: 4),
        Wrap(
          alignment: WrapAlignment.center,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(
              'Sent with your app and iOS version — never your photos.',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.42),
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
        ),
      ],
    );
  }

  Widget _thanks() {
    final String line = switch (_kind) {
      FeedbackKind.composition =>
        'Your request is in. The compositions people ask for are the ones we '
            'build next.',
      FeedbackKind.issue =>
        _contact
            ? 'We\'ll look into it, and write to ${_email.text.trim()} if we '
                  'need to know more.'
            : 'We\'ll look into it.',
      FeedbackKind.idea => 'It\'s on its way to the person who builds Phily.',
    };
    return Column(
      key: const ValueKey('thanks'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 10),
        const Center(child: DrawnCheck(size: 72)),
        const SizedBox(height: 18),
        FadeUp(
          delay: const Duration(milliseconds: 380),
          child: Text(
            'Thank you.',
            textAlign: TextAlign.center,
            style: brandDisplay(size: 30, weight: FontWeight.w400),
          ),
        ),
        const SizedBox(height: 8),
        FadeUp(
          delay: const Duration(milliseconds: 460),
          child: Text(
            line,
            textAlign: TextAlign.center,
            style: brandLabel(
              size: 14,
              weight: FontWeight.w400,
              color: kPaper.withValues(alpha: 0.66),
              letterSpacing: 0.1,
            ).copyWith(height: 1.45),
          ),
        ),
        const SizedBox(height: 26),
        FadeUp(
          delay: const Duration(milliseconds: 540),
          child: GildedButton(
            label: 'Done',
            onTap: () => Navigator.of(context).maybePop(),
          ),
        ),
      ],
    );
  }
}

/// The consent switch. Off by default: permission to write back is asked
/// for, never assumed. The label and the line under it are the exact
/// sentence recorded with the email (FeedbackService.consentVersion).
class _ConsentRow extends StatelessWidget {
  final bool value;
  final ValueChanged<bool> onChanged;
  const _ConsentRow({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        hapticTap();
        onChanged(!value);
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            Expanded(
              // The switch carries the whole sentence and its state for
              // VoiceOver; reading the text too would say it twice.
              child: ExcludeSemantics(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      FeedbackService.consentTitle,
                      style: brandLabel(
                        size: 14.5,
                        weight: FontWeight.w500,
                        color: kPaper,
                        letterSpacing: 0.1,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      FeedbackService.consentDetail,
                      style: brandLabel(
                        size: 12,
                        weight: FontWeight.w400,
                        color: kPaper.withValues(alpha: 0.52),
                        letterSpacing: 0.1,
                      ).copyWith(height: 1.35),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 14),
            GildedSwitch(
              value: value,
              onChanged: onChanged,
              semanticLabel:
                  '${FeedbackService.consentTitle}. '
                  '${FeedbackService.consentDetail}',
            ),
          ],
        ),
      ),
    );
  }
}

/// "From the Phi Grid guide" — says which card sent the user here.
class _FromGuideTag extends StatelessWidget {
  final String mode;
  const _FromGuideTag({required this.mode});

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
    decoration: glassChipDecoration(radius: 10, active: true),
    child: Text(
      'FROM THE ${mode.toUpperCase()} GUIDE',
      style: brandLabel(
        size: 9,
        weight: FontWeight.w600,
        color: kGold.withValues(alpha: 0.9),
        letterSpacing: 1.6,
      ),
    ),
  );
}

/// A failed send, said plainly, in the palette rather than alarm red.
class _ErrorLine extends StatelessWidget {
  final String text;
  const _ErrorLine(this.text);

  @override
  Widget build(BuildContext context) => Semantics(
    liveRegion: true,
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 1),
          child: Icon(
            Icons.error_outline_rounded,
            size: 16,
            color: kGold.withValues(alpha: 0.9),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            text,
            style: brandLabel(
              size: 13,
              weight: FontWeight.w400,
              color: kPaper.withValues(alpha: 0.82),
              letterSpacing: 0.1,
            ).copyWith(height: 1.35),
          ),
        ),
      ],
    ),
  );
}
