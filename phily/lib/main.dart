import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:phily/camera_page.dart';
import 'package:phily/screens/account_sheet.dart';
import 'package:phily/screens/welcome.dart';
import 'package:phily/services/account.dart';
import 'package:phily/services/backend.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:phily/theme.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    final base = ThemeData(
      colorScheme: ColorScheme.fromSeed(
        seedColor: kGold,
        brightness: Brightness.dark,
      ),
      scaffoldBackgroundColor: Colors.black,
      useMaterial3: true,
    );
    return MaterialApp(
      title: 'Phily',
      debugShowCheckedModeBanner: false,
      // Brand UI typeface, inherited by every Text in the app.
      theme: base.copyWith(textTheme: appTextTheme(base.textTheme)),
      home: const LaunchGate(),
    );
  }
}

/// Shows [WelcomeScreen] exactly once (first launch), then the camera forever
/// after. Resolves the flag before painting so there's never a flash of the
/// wrong screen; the camera itself starts warming as soon as it's shown.
class LaunchGate extends StatefulWidget {
  const LaunchGate({super.key});

  @override
  State<LaunchGate> createState() => _LaunchGateState();
}

class _LaunchGateState extends State<LaunchGate> {
  static const String _kOnboarded = 'phily_onboarded';
  bool? _onboarded;
  StreamSubscription<Uri>? _links;

  @override
  void initState() {
    super.initState();
    SharedPreferences.getInstance().then((p) {
      if (mounted) setState(() => _onboarded = p.getBool(_kOnboarded) ?? false);
    });
    _watchLinks();
  }

  @override
  void dispose() {
    _links?.cancel();
    super.dispose();
  }

  /// The email sign-in link can land at any moment, on any screen: the app
  /// launched by it, or brought forward mid-shot. It's handled here, at the
  /// root, so wherever the user is they get a toast saying they're in.
  Future<void> _watchLinks() async {
    _links = Backend.links.listen(_onLink);
    final Uri? initial = await Backend.listenForLinks();
    if (initial != null) _onLink(initial);
  }

  Future<void> _onLink(Uri uri) async {
    final acct = PhilyAccount.instance;
    try {
      final bool signedIn = await acct.handleLink(uri);
      if (!mounted) return;
      if (signedIn) {
        hapticReward();
        final String? name = acct.firstName;
        showPhilyToast(
          context,
          name == null ? 'You\'re signed in.' : 'Signed in. Hello, $name.',
        );
      } else if (acct.linkAwaitingEmail) {
        // Opened on a phone that didn't ask for it: the account sheet asks
        // which address it was sent to.
        openAccount(context);
      }
    } on AccountException catch (e) {
      if (mounted) {
        showPhilyToast(context, e.message, icon: Icons.error_outline_rounded);
      }
    }
  }

  Future<void> _finish() async {
    setState(() => _onboarded = true);
    final p = await SharedPreferences.getInstance();
    await p.setBool(_kOnboarded, true);
  }

  @override
  Widget build(BuildContext context) {
    return switch (_onboarded) {
      null => const ColoredBox(color: Colors.black),
      false => WelcomeScreen(onContinue: _finish),
      true => const CameraPage(),
    };
  }
}
