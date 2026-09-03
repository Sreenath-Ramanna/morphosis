// tool/catalog_check.dart
//
// What CI cannot check.
//
// The pipeline has no RAW files, so the capture date arriving from a real
// file, and the digest of a real file, are verified here or not at all. Run it
// against a few frames after touching RawMetadata or the digest:
//
//   RIA_SO=../raw_images_api/build/libraw_images_api.so \
//     dart run tool/catalog_check.dart ../raw_viewer/test-images/*.NEF
//
// The digests it prints are checkable against sha256sum, which is the point:
// an independent implementation agreeing is what makes the identity credible.

import 'dart:io';

import 'package:morphosis/src/catalog/digest.dart';
import 'package:morphosis/src/ria/ria.dart';

void main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln('usage: dart run tool/catalog_check.dart <raw files…>');
    exit(2);
  }

  final so = Platform.environment['RIA_SO'];
  if (so != null) Ria.libraryPathOverride = so;

  for (final path in args) {
    final raw = RawFile.open(path);
    try {
      final metadata = raw.metadata();
      final size = await File(path).length();

      final started = DateTime.now();
      final digest = await digestOfFile(path);
      final millis = DateTime.now().difference(started).inMilliseconds;
      final mb = size / (1024 * 1024);

      stdout.writeln(path.split(Platform.pathSeparator).last);
      stdout.writeln('  camera      ${metadata.camera}');
      // Null here means the file said nothing, not 1970. A whole folder of
      // 1970s would sort to the top of every date search.
      stdout.writeln('  capturedAt  ${metadata.capturedAt ?? "unknown"}'
          '${metadata.capturedAt == null ? "" : "  (local "
              "${metadata.capturedAt!.toLocal()})"}');
      stdout.writeln('  sha256      $digest');
      stdout.writeln('  hashed      ${mb.toStringAsFixed(1)} MB in $millis ms'
          '${millis == 0 ? "" : "  (${(mb / (millis / 1000)).round()} MB/s)"}');
    } finally {
      raw.close();
    }
  }
}
