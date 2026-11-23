import 'package:flutter/material.dart';
import 'shelf_screen.dart';
import 'storage.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Storage.init();
  runApp(const WereadLiteApp());
}

class WereadLiteApp extends StatelessWidget {
  const WereadLiteApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Weread Lite (Local)',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blueGrey),
        scaffoldBackgroundColor: const Color(0xFFFAF9F6), // 米白色纸质护眼底色
      ),
      home: const ShelfScreen(),
    );
  }
}
