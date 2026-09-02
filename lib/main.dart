// lib/main.dart

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import 'src/ui/app.dart';

/// An optional folder or RAW file on the command line:
///
///     morphosis ~/photos/2026-09-02
///     morphosis ~/photos/2026-09-02/DSC_1436.NEF
///
/// The second form is what the desktop entry's MimeType promises — a file
/// manager passes the file that was opened, not its directory — so a file is
/// resolved to the folder that holds it, with that frame selected. Without
/// one the app opens empty and waits for the Browse button.
void main(List<String> args) {
  String? folder;
  String? select;

  final arg = args.isNotEmpty && !args.first.startsWith('-') ? args.first : null;
  if (arg != null) {
    if (FileSystemEntity.isDirectorySync(arg)) {
      folder = arg;
    } else if (FileSystemEntity.isFileSync(arg)) {
      folder = p.dirname(arg);
      select = arg;
    }
  }

  runApp(MorphosisApp(initialFolder: folder, initialSelection: select));
}
