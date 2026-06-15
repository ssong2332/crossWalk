import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'screens/camera_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  runApp(const CrosswalkApp());
}

class CrosswalkApp extends StatelessWidget {
  const CrosswalkApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '횡단보도 이탈 감지',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(),
      home: const CameraScreen(),
    );
  }
}
