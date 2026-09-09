import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:phily/camera_page.dart';
import 'package:phily/screens/welcome.dart';
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

  @override
  void initState() {
    super.initState();
    SharedPreferences.getInstance().then((p) {
      if (mounted) setState(() => _onboarded = p.getBool(_kOnboarded) ?? false);
    });
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
