import 'package:flutter/material.dart';

import 'ui/game_screen.dart';

void main() {
  runApp(const TetrisRoyaleApp());
}

class TetrisRoyaleApp extends StatelessWidget {
  const TetrisRoyaleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Tetris Royale',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xff00d2ff),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: const GameScreen(),
    );
  }
}
