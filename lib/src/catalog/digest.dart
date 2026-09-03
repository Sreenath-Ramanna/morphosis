// lib/src/catalog/digest.dart
//
// What identifies a photograph.
//
// A SHA-256 digest identifies the file after it has been copied elsewhere,
// because a copy is byte-identical and hashing is deterministic. Copy a NEF to
// a NAS, open it from there, and the catalogue finds the same entry with the
// same keywords. That is the whole point of the feature.
//
// It is worth being precise about the edges, because the failure mode is
// silent — a frame that quietly appears uncatalogued. It matches copies,
// moves, renames and restores from backup. It does not match a file converted
// to DNG, a file another program has written XMP into, or two exposures of the
// same scene, which are different photographs and should not match.
//
// Cost, measured on this machine (PLAN.md section 4): about 89 MB/s, so 336 ms
// for a 30 MB NEF against a 1.9 s decode. Free in wall-clock terms when the
// two run together, and far too slow to do to a whole folder — three hundred
// frames would be ninety seconds. Hence: never on a folder listing, once per
// frame actually opened, never on a slider move.

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';

/// The digest of a file's contents, as 64 lowercase hex characters.
///
/// Streamed rather than read whole. PLAN.md section 4 measured the two at
/// about the same speed, and streaming does not hold 30 MB in memory while it
/// works.
///
/// Throws a [FileSystemException] if the file cannot be read. It does not
/// return the digest of nothing: a frame silently identified as the empty file
/// would collide with every other unreadable frame in the catalogue.
Future<String> digestOfFile(String path) async {
  Digest? result;
  // dart:convert's own callback sink, rather than package:convert's
  // AccumulatorSink — one fewer dependency for four lines of code.
  final output =
      ChunkedConversionSink<Digest>.withCallback((all) => result = all.single);
  final input = sha256.startChunkedConversion(output);
  await for (final chunk in File(path).openRead()) {
    input.add(chunk);
  }
  input.close();
  return result!.toString();
}

/// The same, on a short-lived isolate.
///
/// Started alongside the decode rather than after it. The decode already owns
/// a worker isolate holding 100–200 MB of pixels; hashing there would stall
/// the canvas for a third of a second on every frame, so it gets its own.
Future<String> digestOfFileOnIsolate(String path) =>
    Isolate.run(() => digestOfFile(path));
