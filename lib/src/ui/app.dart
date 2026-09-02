// lib/src/ui/app.dart

import 'package:flutter/material.dart';

import 'editor_screen.dart';
import 'theme.dart';

class MorphosisApp extends StatelessWidget {
  /// Folder to open at startup, from the command line. Null opens empty.
  final String? initialFolder;

  const MorphosisApp({super.key, this.initialFolder});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Morphosis',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(),
      home: EditorScreen(initialFolder: initialFolder),
    );
  }
}
