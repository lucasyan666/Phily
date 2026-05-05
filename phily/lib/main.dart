import 'package:flutter/material.dart';
import 'package:phily/camera_page.dart';
import 'package:phily/screens/splash_screen.dart';

void main() {
  runApp( MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Phily',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        useMaterial3: true,
      ),
      home: const SplashScreen(),
      routes: {
        '/home': (context) => const CameraPage(),
      },
    );
  }
}