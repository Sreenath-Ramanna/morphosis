// tool/catalog_dump.dart
//
// Print the catalogue.
//
//   dart run tool/catalog_dump.dart [path]
//
// Read through the store rather than with a SQL client, and deliberately so:
// it goes through the same migrations and the same decoding the application
// uses, so what it prints is what the application would see rather than what
// the file happens to hold. That is the difference that matters when checking
// whether a stored edit reads back as the edit that was made.

import 'dart:convert';
import 'dart:io';

import 'package:morphosis/src/catalog/catalog_paths.dart';
import 'package:morphosis/src/catalog/sqlite/sqlite_catalog.dart';

void main(List<String> args) async {
  final path = args.isNotEmpty ? args.first : catalogFile();
  if (!File(path).existsSync()) {
    stderr.writeln('No catalogue at $path');
    exit(1);
  }
  stdout.writeln('$path\n');

  final store = SqliteCatalogStore(path);
  await store.open();
  try {
    final all = await store.search(limit: 1000);
    stdout.writeln('${all.length} image(s)');
    for (final e in all) {
      stdout.writeln('');
      stdout.writeln('  ${e.displayName}   ${e.sha256.substring(0, 16)}…');
      stdout.writeln('    size       ${e.sizeBytes}');
      stdout.writeln('    captured   ${e.capturedAt ?? "unknown"}');
      stdout.writeln('    camera     ${e.camera ?? "unknown"}');
      stdout.writeln(
          '    keywords   ${e.keywords.isEmpty ? "—" : e.keywords.toStorage()}');
      // "none" here is the decision from PLAN.md section 11: a frame that was
      // opened and looked at is recorded, but is not claimed to be edited.
      // The edit is printed as the document it is stored as, because that is
      // the thing whose round trip matters.
      final edit = e.edit;
      stdout.writeln(edit == null
          ? '    edit       none — seen, not worked on'
          : '    edit       ${const JsonEncoder().convert(edit.toJson())}');
      stdout.writeln('    first seen ${e.firstSeen}');
      stdout.writeln('    last edit  ${e.lastEdited}');
      for (final at in await store.locationsOf(e.sha256)) {
        stdout.writeln('    seen at    ${at.path}');
      }
    }

    final words = await store.keywords();
    stdout.writeln('\n${words.length} keyword(s)');
    for (final w in words) {
      stdout.writeln('  ${w.keyword}  ${w.images}');
    }
  } finally {
    await store.close();
  }
}
