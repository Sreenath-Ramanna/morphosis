// lib/src/ui/app.dart

import 'package:flutter/material.dart';

import 'editor_screen.dart';
import 'theme.dart';

class MorphosisApp extends StatelessWidget {
  /// Folder to open at startup, from the command line. Null opens empty.
  final String? initialFolder;

  /// A file within that folder to select rather than the first one.
  final String? initialSelection;

  const MorphosisApp({
    super.key,
    this.initialFolder,
    this.initialSelection,
  });

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Morphosis',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(),
      home: EditorScreen(
        initialFolder: initialFolder,
        initialSelection: initialSelection,
      ),
    );
  }
}
