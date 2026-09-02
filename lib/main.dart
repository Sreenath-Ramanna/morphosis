// lib/main.dart

import 'package:flutter/material.dart';

import 'src/ui/app.dart';

/// An optional folder on the command line, so the app can be pointed straight
/// at a shoot:
///
///     morphosis ~/photos/2026-09-02
///
/// Without one it opens empty and waits for the Browse button.
void main(List<String> args) {
  final folder = args.isNotEmpty && !args.first.startsWith('-')
      ? args.first
      : null;
  runApp(MorphosisApp(initialFolder: folder));
}
