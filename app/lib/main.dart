import 'package:flutter/material.dart';

import 'bridge.dart';
import 'controller.dart';
import 'home_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  Bridge.init();
  final Controller controller = Controller(await openStore());
  await controller.init();
  runApp(CallNoteApp(controller: controller));
}

class CallNoteApp extends StatelessWidget {
  const CallNoteApp({super.key, required this.controller});

  final Controller controller;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'CallNote',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: Colors.black,
        canvasColor: Colors.black,
        colorScheme: const ColorScheme.dark(
          primary: Colors.white,
          onPrimary: Colors.black,
          secondary: Colors.white,
          surface: Colors.black,
          onSurface: Colors.white,
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.black,
          foregroundColor: Colors.white,
          elevation: 0,
          centerTitle: false,
        ),
        dividerColor: const Color(0xFF222222),
        inputDecorationTheme: const InputDecorationTheme(
          border: OutlineInputBorder(
            borderRadius: BorderRadius.all(Radius.circular(12)),
            borderSide: BorderSide(color: Color(0xFF333333)),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.all(Radius.circular(12)),
            borderSide: BorderSide(color: Color(0xFF333333)),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.all(Radius.circular(12)),
            borderSide: BorderSide(color: Colors.white),
          ),
        ),
      ),
      home: HomeScreen(controller: controller),
    );
  }
}
