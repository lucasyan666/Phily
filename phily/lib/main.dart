import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:phily/camera_page.dart';
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
      home: const CameraPage(),
    );
  }
}
