// ignore_for_file: avoid_print
// tool/pipeline_check.dart
//
// End-to-end check against real camera files, outside the UI. Decodes, reads
// the colour temperature, renders the preview, exports both formats, and
// verifies that the source RAW is byte-identical afterwards.
//
//   dart run tool/pipeline_check.dart <out-dir> <file.NEF> [more files…]
//
// Loads the release bundle's library, so `flutter build linux --release` has
// to have run at least once.

import 'dart:convert';
import 'dart:math' as math;
import 'dart:io';
import 'dart:typed_data';

import 'package:morphosis/src/model/edit.dart';
import 'package:morphosis/src/model/geometry.dart';
import 'package:morphosis/src/pipeline/colour_temp.dart';
import 'package:morphosis/src/pipeline/export.dart';
import 'package:morphosis/src/pipeline/processor.dart';
import 'package:morphosis/src/pipeline/render.dart';
import 'package:morphosis/src/pipeline/tone.dart';
import 'package:morphosis/src/ria/ria.dart';
import 'package:path/path.dart' as p;

/// Where to load the library from. The release bundle by default, because
/// that is the build whose timings mean anything — the Flutter debug build
/// compiles the C at -O0, which makes the filters roughly five times slower
/// than they are in a shipped app. Override with MORPHOSIS_SO.
String get _so =>
    Platform.environment['MORPHOSIS_SO'] ??
    'build/linux/x64/release/bundle/lib/libraw_images_api.so';

Future<void> main(List<String> args) async {
  if (args.length < 2) {
    stderr.writeln('usage: dart run tool/pipeline_check.dart <out-dir> '
        '<file.NEF> [more…]');
    exit(2);
  }
  final outDir = args[0];
  Ria.libraryPathOverride = File(_so).absolute.path;
  await Directory(outDir).create(recursive: true);

  print('raw_images_api ${Ria.lib().version}\n');

  var failures = 0;
  for (final path in args.skip(1)) {
    try {
      failures += await _check(path, outDir);
    } catch (e, st) {
      print('  FAIL $path: $e\n$st');
      failures++;
    }
    print('');
  }
  failures += await _checkWorker(args.skip(1).toList());

  print(failures == 0 ? 'all checks passed' : '$failures FAILURES');
  exit(failures == 0 ? 0 : 1);
}

Future<int> _check(String path, String outDir) async {
  var failures = 0;
  void check(bool ok, String what) {
    print('  ${ok ? 'ok  ' : 'FAIL'} $what');
    if (!ok) failures++;
  }

  print(p.basename(path));
  final before = await _digest(path);
  final sizeBefore = await File(path).length();

  final sw = Stopwatch()..start();
  final f = RawFile.open(path);
  final meta = f.metadata();
  final wb = WhiteBalance.from(f.colorData());
  final openMs = sw.elapsedMilliseconds;

  sw.reset();
  final preview = f.decodeSceneLinear(maxEdge: previewMaxEdge);
  final decodeMs = sw.elapsedMilliseconds;
  f.close();

  print('  ${meta.camera} · ${meta.sizeText} · ${meta.isoText} · '
      '${meta.shutterText} · ${meta.apertureText}');
  print('  as shot ${wb.asShot.kelvin.round()} K ${wb.asShot.tintLabel} '
      '(${wb.asShot.sourceLabel}, '
      'Duv ${wb.asShot.duv.toStringAsFixed(4)}, '
      'reliable ${wb.asShot.reliable})');
  print('  open $openMs ms, decode $decodeMs ms → '
      '${preview.width}×${preview.height}');

  final zones = ZoneHistogram.compute(preview.data, preview.width,
      preview.height);
  final autoGrey = zones.autoGreyPoint();
  print('  scene median ${zones.medianEv.toStringAsFixed(2)} EV, '
      'auto grey ${autoGrey.toStringAsFixed(4)} '
      '(${(_log2(middleGrey / autoGrey)).toStringAsFixed(2)} EV lift)');

  check(zones.medianEv > -8 && zones.medianEv < -0.5,
      'scene median is in the range a linear decode should give');
  check(autoGrey > 0.001 && autoGrey < 0.3, 'auto grey point is plausible');

  // A realistic edit, exercising every control at once.
  final edit = Edit(
    temperatureK: wb.asShot.kelvin + 600,
    blackEv: -0.6,
    shadowEv: 1.4,
    highlightEv: -0.9,
    whiteEv: 0.4,
    brightnessEv: 0.3,
    contrastEv: 0.7,
    sharpness: 0.6,
    saturation: 18.0,
    vibrance: 12.0,
    highlightRolloff: true,
  );

  final tone = Tone(
    greyPoint: edit.greyPointFrom(autoGrey),
    shoulder: edit.highlightRolloff,
    contrastEv: edit.contrastEv,
    blackEv: edit.blackEv,
    shadowEv: edit.shadowEv,
    highlightEv: edit.highlightEv,
    whiteEv: edit.whiteEv,
  );
  check(tone.softLimitFactor() == 1.0,
      'a realistic edit is not scaled back by the soft limit');

  final gain = tone.buildGainLut();
  final disp =
      tone.buildDisplayLut(outMax: 255, entries: DisplayLut.previewEntries);
  final matrix = _matrix(wb, edit.temperatureK!);
  final buf = DisplayBuffer.allocate(preview.width, preview.height);

  sw.reset();
  renderRgb8(preview.data, preview.width, preview.height, matrix, gain, disp,
      buf.pixels, saturation: edit.saturation, vibrance: edit.vibrance);
  final renderMs = sw.elapsedMicroseconds / 1000;

  sw.reset();
  buf.unsharpMask(0.9, edit.sharpness, 0.004);
  final sharpenMs = sw.elapsedMicroseconds / 1000;

  sw.reset();
  final hist = buf.histogram();
  final histMs = sw.elapsedMicroseconds / 1000;

  print('  render ${renderMs.toStringAsFixed(1)} ms, '
      'sharpen ${sharpenMs.toStringAsFixed(1)} ms, '
      'histogram ${histMs.toStringAsFixed(1)} ms  '
      '(${(preview.width * preview.height / 1e6).toStringAsFixed(1)} MP)');
  print('  clipped: black ${(hist.clippedBlack * 100).toStringAsFixed(3)}%, '
      'white ${(hist.clippedWhite * 100).toStringAsFixed(3)}%');

  check(hist.pixels > 0, 'the histogram counted pixels');
  check(hist.clippedWhite < 0.05,
      'the shoulder kept highlight clipping under 5%');
  check(renderMs < 2000, 'the preview render is interactive');

  // Every render must produce something other than flat black or flat white.
  var min = 255, max = 0;
  for (var i = 0; i < buf.pixels.length; i += 3) {
    final v = buf.pixels[i + 1];
    if (v < min) min = v;
    if (v > max) max = v;
  }
  check(max - min > 100, 'the rendered frame has real tonal range '
      '($min…$max)');
  buf.dispose();

  // Exports, at full resolution.
  final base = p.basenameWithoutExtension(path);
  for (final format in ExportFormat.values) {
    sw.reset();
    final target = p.join(outDir, '$base.${format.extension}');
    await runExport(ExportRequest(
      soPath: Ria.libraryPathOverride!,
      sourcePath: path,
      targetPath: target,
      edit: edit,
      format: format,
      jpegQuality: defaultJpegQuality,
      previewMaxEdge: previewMaxEdge,
    ));
    final size = await File(target).length();
    print('  ${format.label} ${sw.elapsedMilliseconds} ms → '
        '${(size / 1024 / 1024).toStringAsFixed(1)} MB');
    check(size > 10000, '${format.label} export is not empty');
  }

  // Geometry has to survive the jump to full resolution. The crop is stored
  // as fractions of the frame precisely so that it means the same thing on a
  // 1600 px preview and on a 33 MP export; this is the check that it does.
  {
    const geometry = Geometry(
      quarterTurns: 1,
      straightenDegrees: 4,
      crop: CropRect(0.15, 0.1, 0.85, 0.7),
    );
    final target = p.join(outDir, '$base-cropped.jpg');
    sw.reset();
    await runExport(ExportRequest(
      soPath: Ria.libraryPathOverride!,
      sourcePath: path,
      targetPath: target,
      edit: edit.copyWith(geometry: geometry),
      format: ExportFormat.jpeg,
      jpegQuality: defaultJpegQuality,
      previewMaxEdge: previewMaxEdge,
    ));
    final (ew, eh) = geometry.outputSize(meta.width, meta.height);
    final (aw, ah) = _jpegSize(await File(target).readAsBytes());
    print('  cropped JPEG ${sw.elapsedMilliseconds} ms → '
        '${aw}x$ah, expected ${ew}x$eh');
    check(aw == ew && ah == eh,
        'the export is cropped and turned to the size the geometry implies');
    check(ew < meta.width && eh < meta.height,
        'and is smaller than the frame it came from');
  }

  // The point of the whole exercise.
  check(await _digest(path) == before && await File(path).length() == sizeBefore,
      'the RAW file is byte-identical after all of that');

  return failures;
}

/// The worker isolate, end to end: open a frame, render it, switch to
/// another, render that. This is the path the UI actually uses, and none of
/// the checks above touch it — they call the pipeline directly.
Future<int> _checkWorker(List<String> paths) async {
  var failures = 0;
  void check(bool ok, String what) {
    print('  ${ok ? 'ok  ' : 'FAIL'} $what');
    if (!ok) failures++;
  }

  print('worker isolate');
  final proc = await Processor.start(Ria.libraryPathOverride!);
  try {
    for (final path in paths) {
      final info = await proc.open(path);
      check(info.previewWidth > 0 && info.previewHeight > 0,
          '${p.basename(path)}: opened ${info.previewWidth}×'
          '${info.previewHeight}');

      final neutral = await proc.render(Edit.neutral);
      check(neutral.rgba.length == info.previewWidth * info.previewHeight * 4,
          'a neutral render came back the right size');
      check(neutral.histogram.pixels > 0, 'with a histogram');

      final edited = await proc.render(Edit(
        temperatureK: info.asShot.kelvin + 1200,
        shadowEv: 1.5,
        highlightEv: -1.0,
        brightnessEv: 0.5,
        contrastEv: 1.0,
        sharpness: 0.8,
        saturation: -22.0,
        vibrance: 15.0,
        highlightRolloff: true,
      ));
      check(!_same(neutral.rgba, edited.rgba),
          'and an edited render differs from it');
      check(edited.softLimitFactor == 1.0,
          'without the soft limit intervening');

      final thumb = await proc.thumbnail(path);
      check(thumb != null && thumb.length > 1000,
          'the embedded preview came back (${thumb?.length ?? 0} bytes)');
    }

    // Renders queued back to back must all be answered, in order.
    final results = await Future.wait([
      for (var i = 0; i < 6; i++)
        proc.render(Edit(brightnessEv: i * 0.25)),
    ]);
    check(results.length == 6, 'six queued renders all completed');
    check(!_same(results.first.rgba, results.last.rgba),
        'and were not all the same frame');
  } finally {
    await proc.dispose();
  }
  return failures;
}

bool _same(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i += 997) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

Float64List _matrix(WhiteBalance wb, double kelvin) {
  final m = wb.matrixFor(kelvin);
  return Float64List.fromList([
    m[0][0], m[0][1], m[0][2],
    m[1][0], m[1][1], m[1][2],
    m[2][0], m[2][1], m[2][2],
  ]);
}

double _log2(double v) => v > 0 ? math.log(v) / math.ln2 : 0;

/// Width and height from a JPEG's SOF marker, so the export can be measured
/// without decoding it.
(int, int) _jpegSize(Uint8List b) {
  var i = 2;
  while (i + 9 < b.length) {
    if (b[i] != 0xFF) {
      i++;
      continue;
    }
    final marker = b[i + 1];
    // SOF0..SOF15, excluding the four that are not frame headers.
    if (marker >= 0xC0 &&
        marker <= 0xCF &&
        marker != 0xC4 &&
        marker != 0xC8 &&
        marker != 0xCC) {
      return ((b[i + 7] << 8) | b[i + 8], (b[i + 5] << 8) | b[i + 6]);
    }
    i += 2 + ((b[i + 2] << 8) | b[i + 3]);
  }
  return (0, 0);
}

Future<String> _digest(String path) async {
  // A plain content hash; the check is "unchanged", not "authentic".
  final bytes = await File(path).readAsBytes();
  var h = 0xcbf29ce484222325;
  for (final b in bytes) {
    h ^= b;
    h = (h * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF;
  }
  return base64.encode(
      Uint8List.view(Uint64List.fromList([h]).buffer));
}
