// ignore_for_file: avoid_print
// tool/pipeline_check.dart
//
// End-to-end check against real camera files, outside the UI. Decodes, reads
// the colour temperature, renders the preview, exports both formats, and
// verifies that the source RAW is byte-identical afterwards.
//
//   dart run tool/pipeline_check.dart [--camera-look] <out-dir> <file.NEF> […]
//
// With `--camera-look` it also runs C1–C5, the camera-look preset's real-frame
// acceptance (`.feature-work/camera-look-preset/plan.md` §1.5). Those need a
// real decode and the camera's own embedded JPEG, so they can live nowhere but
// here: CI has no RAW files.
//
// Loads the release bundle's library, so `flutter build linux --release` has
// to have run at least once.

import 'dart:convert';
import 'dart:math' as math;
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:image/image.dart' as img;
import 'package:morphosis/src/model/edit.dart';
import 'package:morphosis/src/model/geometry.dart';
import 'package:morphosis/src/pipeline/colour_temp.dart';
import 'package:morphosis/src/pipeline/export.dart';
import 'package:morphosis/src/pipeline/icc.dart';
import 'package:morphosis/src/pipeline/processor.dart';
import 'package:morphosis/src/pipeline/render.dart';
import 'package:morphosis/src/pipeline/tone.dart';
import 'package:morphosis/src/pipeline/working_space.dart';
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
  var rest = args;
  var cameraLook = false;
  if (rest.isNotEmpty && rest.first == '--camera-look') {
    cameraLook = true;
    rest = rest.skip(1).toList();
  }
  if (rest.length < 2) {
    stderr.writeln('usage: dart run tool/pipeline_check.dart [--camera-look] '
        '<out-dir> <file.NEF> [more…]');
    exit(2);
  }
  args = rest;
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
  if (cameraLook) {
    failures += await _checkCameraLook(args.skip(1).toList());
    print('');
  }
  failures += await _checkWorker(args.skip(1).toList(), cameraLook);

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
  final cd = f.colorData();
  final wb = WhiteBalance.from(cd, space: workingSpace);
  final openMs = sw.elapsedMilliseconds;

  sw.reset();
  final preview = f.decodeSceneLinear(
      maxEdge: previewMaxEdge, outputColor: workingSpace);
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

  final zones = ZoneHistogram.compute(
    preview.data,
    preview.width,
    preview.height,
    lumaRow: lumaRowFor(preview.colorspace),
    saturationScale: preview.saturationScale,
  );
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
  final matrix = composedMatrix(
    inputSpace: preview.colorspace,
    outputSpace: previewSpace,
    wbMatrix: wb.matrixFor(edit.temperatureK!),
    saturationScale: preview.saturationScale,
  );
  final buf = DisplayBuffer.allocate(preview.width, preview.height);

  sw.reset();
  renderRgb8(preview.data, preview.width, preview.height, matrix, gain, disp,
      buf.pixels,
      saturation: edit.saturation,
      vibrance: edit.vibrance,
      lumaRow: lumaRowFor(previewSpace));
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

  // Each of these reports through `check`, so it adds to the count above.
  _checkSrgbIdentity(path, check);
  _checkAnchor(path, check);
  _checkGamut(path, check);
  _checkProfiles(outDir, base, check);

  // The point of the whole exercise.
  check(await _digest(path) == before && await File(path).length() == sizeBefore,
      'the RAW file is byte-identical after all of that');

  return failures;
}

/// P0: with the working space forced to sRGB and recovery off, the preview is
/// byte-identical to what the pipeline produced before any of this landed.
///
/// The cheapest guard against the failure most likely to ship. `srgbFromWorking`
/// and its inverse both have rows summing to 1, so a neutral grey survives
/// either direction and the render stays plausible — just systematically over-
/// or under-saturated. P6 discriminates the direction on real pixels; this
/// discriminates whether the refactor moved anything at all.
///
/// The "before" arm is the old code path written out: an sRGB decode, the
/// white-balance matrix straight from `matrixFor`, Rec.709, and no anchor.
void _checkSrgbIdentity(String path, void Function(bool, String) check) {
  final f = RawFile.open(path);
  final SceneImage img;
  final WhiteBalance wb;
  try {
    img = f.decodeSceneLinear(maxEdge: previewMaxEdge);
    wb = WhiteBalance.from(f.colorData());
  } finally {
    f.close();
  }
  const kelvinOffset = 700.0;
  final k = wb.asShot.kelvin + kelvinOffset;
  final m = wb.matrixFor(k);

  Uint8List render(Float64List? matrix, List<double> lumaRow, double scale) {
    final zones = ZoneHistogram.compute(img.data, img.width, img.height,
        lumaRow: lumaRow, saturationScale: scale);
    final tone = Tone(greyPoint: zones.autoGreyPoint(), shoulder: true);
    final disp =
        tone.buildDisplayLut(outMax: 255, entries: DisplayLut.previewEntries);
    final buf = DisplayBuffer.allocate(img.width, img.height);
    try {
      renderRgb8(img.data, img.width, img.height, matrix, tone.buildGainLut(),
          disp, buf.pixels,
          saturation: 14, vibrance: 9, lumaRow: lumaRow);
      return Uint8List.fromList(buf.pixels);
    } finally {
      buf.dispose();
    }
  }

  final before = render(
      Float64List.fromList([
        m[0][0], m[0][1], m[0][2], //
        m[1][0], m[1][1], m[1][2], //
        m[2][0], m[2][1], m[2][2],
      ]),
      rec709Luma,
      1.0);
  final after = render(
      composedMatrix(
        inputSpace: RiaColorspace.srgb,
        outputSpace: RiaColorspace.srgb,
        wbMatrix: m,
        saturationScale: img.saturationScale,
      ),
      lumaRowFor(RiaColorspace.srgb),
      img.saturationScale);

  check(img.saturationScale == 1.0 && img.colorspace == RiaColorspace.srgb,
      'P0a a plain decode still reports sRGB and a scale of 1.0');
  check(_identical(before, after),
      'P0 an sRGB working space with recovery off is byte-identical to the '
      'render before this change');
}

/// P1–P5: the anchor. The headline property is P3.
///
/// Local only, and it can be nowhere else: `test-images/` is hundreds of
/// megabytes and is not in version control, so `flutter test` has no frame to
/// run this on. `render_test.dart`'s R8 is the synthetic form.
void _checkAnchor(String path, void Function(bool, String) check) {
  SceneImage decode(int mode) {
    final f = RawFile.open(path);
    try {
      return f.decodeSceneLinear(
        maxEdge: previewMaxEdge,
        outputColor: workingSpace,
        highlightMode: mode,
      );
    } finally {
      f.close();
    }
  }

  final off = decode(0);
  final on = decode(highlightRecoveryMode);

  final scale = on.saturationScale;
  final ratio = _medianGreen(on.data) / _medianGreen(off.data);
  print('  anchor: reported ${scale.toStringAsFixed(5)}, '
      'median ratio ${ratio.toStringAsFixed(5)} '
      '(${_medianGreen(off.data).round()} → ${_medianGreen(on.data).round()})');

  // P1
  check(off.saturationScale == 1.0,
      'P1 recovery off reports a scale of exactly 1.0 '
      '(${off.saturationScale})');
  check(scale > 0.2 && scale < 1.0,
      'P2a recovery on reports a real rescale ($scale)');
  // P2
  check((ratio - scale).abs() / scale < 0.01,
      'P2 the reported scale is the median ratio, within 1%');

  ZoneHistogram zones(SceneImage img) => ZoneHistogram.compute(
        img.data,
        img.width,
        img.height,
        lumaRow: lumaRowFor(img.colorspace),
        saturationScale: img.saturationScale,
      );

  final zOff = zones(off);
  final zOn = zones(on);
  final greyOff = zOff.autoGreyPoint(), greyOn = zOn.autoGreyPoint();
  print('  median EV: off ${zOff.medianEv.toStringAsFixed(3)}, '
      'on ${zOn.medianEv.toStringAsFixed(3)} '
      '(unanchored would read '
      '${(zOn.medianEv + _log2(scale)).toStringAsFixed(3)})');
  print('  auto grey: off ${greyOff.toStringAsFixed(5)}, '
      'on ${greyOn.toStringAsFixed(5)}');

  // P3 — the proof the brief asks for.
  check((zOn.medianEv - zOff.medianEv).abs() < 0.02,
      'P3 the median EV does not move when the toggle flips '
      '(${(zOn.medianEv - zOff.medianEv).abs().toStringAsFixed(4)} EV)');
  // P4
  check((greyOn / greyOff - 1.0).abs() < 0.02,
      'P4 the auto grey point does not move '
      '(${((greyOn / greyOff - 1) * 100).toStringAsFixed(2)}%)');

  // P5 is measured on the scene buffer, not on the display histogram.
  //
  // The plan states it as the display figure requirements section 2 recorded
  // (0.126 % → 0.000 %), but that number was measured on the sRGB pipeline.
  // With a wide working space delivered to sRGB, the display's clipped-white
  // fraction is dominated by the gamut conversion rather than by the sensor
  // clip, and it moves by a code value in either direction. The sample count
  // at full scale is what highlight reconstruction actually changes, it is the
  // Dart twin of the library's own C14, and on the Canon frame it goes 10325
  // samples to 0.
  double saturatedFraction(int mode) {
    // Half size, not resized: `ria_fit_within` averages neighbours, and an
    // average of a saturated pixel and its neighbour is not saturated — the
    // count would read zero on every frame and prove nothing.
    final f = RawFile.open(path);
    final SceneImage img;
    try {
      img = f.decodeSceneLinear(halfSize: true, outputColor: workingSpace,
          highlightMode: mode);
    } finally {
      f.close();
    }
    var n = 0;
    for (final v in img.data) {
      if (v == 65535) n++;
    }
    return n / img.data.length;
  }

  final sOff = saturatedFraction(0), sOn = saturatedFraction(highlightRecoveryMode);
  print('  samples at full scale: off ${(sOff * 100).toStringAsFixed(4)}%, '
      'on ${(sOn * 100).toStringAsFixed(4)}%');
  check(sOn <= sOff,
      'P5 recovery does not leave more samples at full scale');
  if (sOff > 0) {
    check(sOn < sOff,
        'P5b and strictly fewer on a frame that clipped');
  }

  double clipped(SceneImage img, ZoneHistogram z) {
    final tone = Tone(greyPoint: z.autoGreyPoint());
    final disp =
        tone.buildDisplayLut(outMax: 255, entries: DisplayLut.previewEntries);
    final buf = DisplayBuffer.allocate(img.width, img.height);
    try {
      renderRgb8(
          img.data,
          img.width,
          img.height,
          composedMatrix(
            inputSpace: img.colorspace,
            outputSpace: previewSpace,
            wbMatrix: null,
            saturationScale: img.saturationScale,
          ),
          tone.buildGainLut(),
          disp,
          buf.pixels,
          lumaRow: lumaRowFor(previewSpace));
      return buf.histogram().clippedWhite;
    } finally {
      buf.dispose();
    }
  }

  final cOff = clipped(off, zOff), cOn = clipped(on, zOn);
  print('  display clipped white: off ${(cOff * 100).toStringAsFixed(4)}%, '
      'on ${(cOn * 100).toStringAsFixed(4)}%  (informational — the display '
      'figure follows the gamut conversion, not the sensor clip)');
}

/// P6: the wide decode keeps colour the sRGB decode threw away.
void _checkGamut(String path, void Function(bool, String) check) {
  SceneImage decode(int space) {
    final f = RawFile.open(path);
    try {
      // Half size rather than resized: `ria_fit_within` averages neighbours,
      // which invents intermediate values across the flat clipped patch this
      // check is looking for.
      return f.decodeSceneLinear(halfSize: true, outputColor: space);
    } finally {
      f.close();
    }
  }

  final srgb = decode(RiaColorspace.srgb);
  final wide = decode(workingSpace);
  if (srgb.width != wide.width || srgb.height != wide.height) {
    check(false, 'P6 the two decodes are the same size');
    return;
  }

  final toSrgb = srgbFromWorking(wide.colorspace);
  final n = srgb.pixels;

  var worst = 0.0;
  var compared = 0;
  final sat = Float64List(n);
  for (var i = 0; i < n; i++) {
    final o = i * 3;
    final r = srgb.data[o], g = srgb.data[o + 1], b = srgb.data[o + 2];
    final mx = r > g ? (r > b ? r : b) : (g > b ? g : b);
    final mn = r < g ? (r < b ? r : b) : (g < b ? g : b);
    sat[i] = mx > 0 ? (mx - mn) / mx : 0.0;

    // In gamut: nothing resting on a boundary, in either decode.
    if (mn == 0 || mx >= 65535) continue;
    final conv = apply3(toSrgb, [
      wide.data[o].toDouble(),
      wide.data[o + 1].toDouble(),
      wide.data[o + 2].toDouble(),
    ]);
    compared++;
    for (var c = 0; c < 3; c++) {
      final d = (conv[c] - srgb.data[o + c]).abs();
      if (d > worst) worst = d;
    }
  }
  print('  gamut: $compared in-gamut pixels compared, worst channel '
      'difference ${worst.round()} of 65535');
  check(worst < 400,
      'P6a the wide decode converted back to sRGB reproduces the sRGB decode');

  // The most saturated 0.1%, by the sRGB decode's own reckoning.
  final order = List<int>.generate(n, (i) => i)
    ..sort((a, b) => sat[b].compareTo(sat[a]));
  final take = (n * 0.001).round().clamp(64, n);

  // Counting distinct *triples* is not sensitive enough: a pixel with one
  // channel pinned to the gamut boundary still has two that vary, so the
  // triples stay distinct and the flat patch hides. The gradation is lost in
  // one channel at a time, so look at one channel — the one the sRGB decode
  // pins most often — and count the values it can still tell apart.
  final pinned = List<int>.filled(3, 0);
  final converted = List<List<double>>.generate(take, (k) {
    final o = order[k] * 3;
    for (var c = 0; c < 3; c++) {
      final v = srgb.data[o + c];
      if (v == 0 || v == 65535) pinned[c]++;
    }
    return apply3(toSrgb, [
      wide.data[o].toDouble(),
      wide.data[o + 1].toDouble(),
      wide.data[o + 2].toDouble(),
    ]);
  });
  var ch = 0;
  for (var c = 1; c < 3; c++) {
    if (pinned[c] > pinned[ch]) ch = c;
  }

  final sVals = <int>{}, wVals = <int>{};
  for (var k = 0; k < take; k++) {
    sVals.add(srgb.data[order[k] * 3 + ch]);
    wVals.add(converted[k][ch].round());
  }

  print('  gamut: in the most saturated $take pixels, channel $ch is pinned to '
      'the sRGB gamut boundary ${pinned[ch]} times; distinct values — '
      'sRGB ${sVals.length}, ${_spaceName(wide.colorspace)} ${wVals.length}');
  check(wVals.length >= sVals.length,
      'P6 the wide decode never has less gradation than the sRGB one');
  if (pinned[ch] > take ~/ 100) {
    // Frame-dependent, and honestly so: a frame whose colour is all inside
    // sRGB has nothing for the wide decode to keep.
    check(wVals.length > sVals.length,
        'P6b and strictly more where the sRGB decode hit the gamut edge');
  }

  // P7 — the one place the C table and the Dart reference meet.
  const prophotoFromSrgb = <double>[
    0.529317, 0.330092, 0.140588, //
    0.098368, 0.873465, 0.028169, //
    0.016879, 0.117663, 0.865457,
  ];
  final fromC = Ria.colorspaceFromSrgb(RiaColorspace.prophoto);
  var mismatch = 0.0;
  for (var i = 0; i < 9; i++) {
    final d = (fromC[i] - prophotoFromSrgb[i]).abs();
    if (d > mismatch) mismatch = d;
  }
  check(mismatch < 1e-6,
      'P7 the library matrix and the Dart reference agree (worst $mismatch)');
}

/// P8: the exported files carry the right profiles.
void _checkProfiles(
    String outDir, String base, void Function(bool, String) check) {
  final tiff = File(p.join(outDir, '$base.tif')).readAsBytesSync();
  final bd = ByteData.view(tiff.buffer);
  final ifd = bd.getUint32(4, Endian.little);
  final count = bd.getUint16(ifd, Endian.little);
  var iccOffset = 0, iccLength = 0;
  for (var i = 0; i < count; i++) {
    final at = ifd + 2 + i * 12;
    if (bd.getUint16(at, Endian.little) == 34675) {
      iccLength = bd.getUint32(at + 4, Endian.little);
      iccOffset = bd.getUint32(at + 8, Endian.little);
    }
  }
  final tiffProfile = iccProfileFor(exportTiffSpace);
  check(iccLength == tiffProfile.length && iccOffset > 0,
      'P8a the TIFF has tag 34675 with the working-space profile');
  check(
      iccLength == tiffProfile.length &&
          _identical(
              tiff.sublist(iccOffset, iccOffset + iccLength), tiffProfile),
      'P8b and the bytes are that profile');

  final jpeg = File(p.join(outDir, '$base.jpg')).readAsBytesSync();
  final jpegProfile = iccProfileFor(exportJpegSpace);
  var at = 2, found = -1;
  while (at + 3 < jpeg.length && jpeg[at] == 0xFF) {
    final marker = jpeg[at + 1];
    if (marker == 0xDA) break;
    if (marker == 0xE2) {
      found = at;
      break;
    }
    at += 2 + ((jpeg[at + 2] << 8) | jpeg[at + 3]);
  }
  final ok = found > 0 &&
      ((jpeg[found + 2] << 8) | jpeg[found + 3]) ==
          2 + 12 + 2 + jpegProfile.length &&
      String.fromCharCodes(jpeg.sublist(found + 4, found + 15)) ==
          'ICC_PROFILE' &&
      jpeg[found + 15] == 0 &&
      jpeg[found + 16] == 1 &&
      jpeg[found + 17] == 1 &&
      _identical(jpeg.sublist(found + 18, found + 18 + jpegProfile.length),
          jpegProfile);
  check(ok, 'P8c the JPEG carries a conformant APP2 with the sRGB profile');
}

String _spaceName(int space) =>
    space == RiaColorspace.prophoto ? 'ProPhoto' : 'space $space';

/// The exact median of the green channel, by counting. 65536 bins is cheaper
/// than a sort and exact for uint16.
double _medianGreen(Uint16List rgb) {
  final counts = Uint32List(65536);
  final n = rgb.length ~/ 3;
  for (var i = 0; i < n; i++) {
    counts[rgb[i * 3 + 1]]++;
  }
  final target = n ~/ 2;
  var acc = 0;
  for (var v = 0; v < 65536; v++) {
    acc += counts[v];
    if (acc > target) return v.toDouble();
  }
  return 0;
}

/// The worker isolate, end to end: open a frame, render it, switch to
/// another, render that. This is the path the UI actually uses, and none of
/// the checks above touch it — they call the pipeline directly.
Future<int> _checkWorker(List<String> paths, [bool cameraLook = false]) async {
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

      if (cameraLook) {
        // C4, second half. "Identical to the pre-change build" is not something
        // one binary can assert about itself, so the digest is printed and
        // compared against the run recorded in
        // `.feature-work/camera-look-preset/log.md` on unmodified HEAD.
        print('    neutral ${neutral.width}x${neutral.height} '
            'medianEv ${neutral.medianEv.toStringAsFixed(6)} '
            'sha256 ${crypto.sha256.convert(neutral.rgba)}');

        // C5. The look is composed after the histogram, so the scene anchor
        // cannot move — exactly, not approximately.
        final look = await proc.render(const Edit(
            cameraLook: CameraLook.camera));
        check(look.medianEv == neutral.medianEv,
            'C5 the scene median EV does not move when the preset flips');
        // The real-frame twin of L8: if the gain table's all-ones fast path
        // swallows the preset, C5 passes trivially and this is what catches it.
        check(!_identical(neutral.rgba, look.rgba),
            'C5b and the preset actually changed the frame');
      }

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

// ── C1–C5: the camera-look preset's real-frame acceptance ─────────────────
//
// `.feature-work/camera-look-preset/plan.md` §1.5. Nothing here can run in CI:
// C1–C3 need the camera's own embedded JPEG to compare against, and all five
// need a real decode.

/// The eight frames the set-level means in C1 and C2 are defined over.
///
/// A one-file run must not report the acceptance criteria as met, so a run that
/// does not cover all eight prints a NOTE and skips C1, C2 and C3 rather than
/// passing them on a subset.
const _canonicalFrames = <String>{
  '20260905_A0A5081',
  '20260905_A0A5093',
  '20260905_A0A5111',
  '20260905_A0A5124',
  '20260905_A0A5141',
  '20250803_A0A8111',
  'DSC_1436',
  'DSC_1440',
};

/// The frames that regress, pinned by name rather than merely counted.
///
/// requirements.md §F.6: these three are the ones whose *neutral* contrast is
/// already at or above their own camera JPEG's (0.940, 1.099, 1.069), so every
/// fixed curve that helps the other five overshoots them — at every strength
/// down to a quarter. Naming them is what makes C3a a real check: it forbids a
/// curve that hits the average by overshooting frames that were already close.
const _acceptedRegressions = <String>{
  '20260905_A0A5124',
  'DSC_1436',
  'DSC_1440',
};

/// The bound on how far a named frame may be pushed away from its camera.
///
/// §E proposed 0.15 on `|ratio − 1|`. The measured worst at k = 1.431 is 0.210
/// and the second worst 0.177, so **0.15 is not met, and this records that it
/// is accepted rather than met**. The bound sits at the measured worst plus
/// headroom rather than at 0.211 because `package:image`'s resampler is not the
/// harness's NumPy one; a bound at the exact measured value would be a golden
/// number that fails on a package bump.
const double _regressionBound = 0.25;

/// Contrast and saturation of one 1200×800 display-referred frame.
class _LookStats {
  /// `p95(luma) − p5(luma)`, in 8-bit code values.
  final double contrast;

  /// Mean of `(max − min) / max` over every pixel, as a fraction.
  final double saturation;

  const _LookStats(this.contrast, this.saturation);
}

/// The two statistics, on the display-encoded values.
///
/// Luma is the Rec.709 row applied to the encoded values — the same row and the
/// same domain `render.dart` uses for saturation. `(max − min) / max` is the
/// definition `_gamutLimit`'s neighbour and `saturate()` in `ria_adjust.c` both
/// use. Both definitions are load-bearing: the expected numbers are only
/// reproducible with them.
_LookStats _lookStats(img.Image im) {
  final bytes = im.getBytes(order: img.ChannelOrder.rgb);
  final n = im.width * im.height;
  final luma = Float64List(n);
  var satSum = 0.0;
  for (var i = 0; i < n; i++) {
    final r = bytes[i * 3], g = bytes[i * 3 + 1], b = bytes[i * 3 + 2];
    luma[i] = r * rec709Luma[0] + g * rec709Luma[1] + b * rec709Luma[2];
    var hi = r > g ? r : g;
    if (b > hi) hi = b;
    var lo = r < g ? r : g;
    if (b < lo) lo = b;
    if (hi != 0) satSum += (hi - lo) / hi;
  }
  luma.sort();
  return _LookStats(
      _percentileOf(luma, 0.95) - _percentileOf(luma, 0.05), satSum / n);
}

/// Linear-interpolated percentile of a sorted list, the way NumPy defines it.
double _percentileOf(Float64List sorted, double f) {
  final pos = f * (sorted.length - 1);
  final lo = pos.floor();
  final hi = pos.ceil();
  if (lo == hi) return sorted[lo];
  final t = pos - lo;
  return sorted[lo] * (1 - t) + sorted[hi] * t;
}

/// Area averaging to a common size, the analogue of the measurement harness's
/// block downsample.
img.Image _lookResize(img.Image src) => img.copyResize(src,
    width: 1200, height: 800, interpolation: img.Interpolation.average);

img.Image _fromRgb8(Uint8List rgb, int width, int height) => img.Image.fromBytes(
      width: width,
      height: height,
      bytes: rgb.buffer,
      order: img.ChannelOrder.rgb,
      numChannels: 3,
    );

/// `processor.dart`'s preview path, reproduced: the tone tables, the composed
/// matrix and the fused loop, for one edit.
Uint8List _lookRender(SceneImage preview, double autoGrey, Edit edit) {
  final tone = Tone(
    greyPoint: edit.greyPointFrom(autoGrey),
    shoulder: edit.highlightRolloff,
    contrastEv: edit.contrastEv,
    blackEv: edit.blackEv,
    shadowEv: edit.shadowEv,
    highlightEv: edit.highlightEv,
    whiteEv: edit.whiteEv,
    cameraLook: edit.cameraLook,
  );
  final disp =
      tone.buildDisplayLut(outMax: 255, entries: DisplayLut.previewEntries);
  final matrix = composedMatrix(
    inputSpace: preview.colorspace,
    outputSpace: previewSpace,
    // Edit.neutral is "as shot", so there is no white-balance matrix and both
    // arms of the comparison get exactly the same one.
    wbMatrix: null,
    saturationScale: preview.saturationScale,
  );
  final buf = DisplayBuffer.allocate(preview.width, preview.height);
  try {
    renderRgb8(preview.data, preview.width, preview.height, matrix,
        tone.buildGainLut(), disp, buf.pixels,
        saturation: edit.saturation,
        vibrance: edit.vibrance,
        lookSaturation: edit.cameraLook.saturationBoost,
        lumaRow: lumaRowFor(previewSpace));
    return Uint8List.fromList(buf.pixels);
  } finally {
    buf.dispose();
  }
}

/// The same render written without ever mentioning the look — C4's in-run half.
///
/// Same shape as P0: the "before" arm is the old code path written out, so the
/// comparison is against code that could not have been affected rather than
/// against the same code called with a zero.
Uint8List _lookRenderWithoutIt(SceneImage preview, double autoGrey) {
  final tone = Tone(greyPoint: Edit.neutral.greyPointFrom(autoGrey));
  final disp =
      tone.buildDisplayLut(outMax: 255, entries: DisplayLut.previewEntries);
  final matrix = composedMatrix(
    inputSpace: preview.colorspace,
    outputSpace: previewSpace,
    wbMatrix: null,
    saturationScale: preview.saturationScale,
  );
  final buf = DisplayBuffer.allocate(preview.width, preview.height);
  try {
    renderRgb8(preview.data, preview.width, preview.height, matrix,
        tone.buildGainLut(), disp, buf.pixels,
        lumaRow: lumaRowFor(previewSpace));
    return Uint8List.fromList(buf.pixels);
  } finally {
    buf.dispose();
  }
}

Future<int> _checkCameraLook(List<String> paths) async {
  var failures = 0;
  void check(bool ok, String what) {
    print('  ${ok ? 'ok  ' : 'FAIL'} $what');
    if (!ok) failures++;
  }

  print('camera look — C1 to C5');

  final names = <String>[];
  final rOffC = <double>[], rOnC = <double>[];
  final rOffS = <double>[], rOnS = <double>[];

  for (final path in paths) {
    final base = p.basenameWithoutExtension(path);
    final f = RawFile.open(path);
    final SceneImage preview;
    final EmbeddedPreview? embedded;
    try {
      preview = f.decodeSceneLinear(
          maxEdge: previewMaxEdge, outputColor: workingSpace);
      embedded = f.preview();
    } finally {
      f.close();
    }
    if (embedded == null) {
      check(false, '$base: the camera JPEG could not be read');
      continue;
    }

    final zones = ZoneHistogram.compute(
      preview.data,
      preview.width,
      preview.height,
      lumaRow: lumaRowFor(preview.colorspace),
      saturationScale: preview.saturationScale,
    );
    final autoGrey = zones.autoGreyPoint();

    final off = _lookRender(preview, autoGrey, Edit.neutral);
    final on = _lookRender(
        preview, autoGrey, const Edit(cameraLook: CameraLook.camera));

    // C4, first half.
    check(_identical(off, _lookRenderWithoutIt(preview, autoGrey)),
        'C4 $base: with the preset off the render is byte-identical to one '
        'written without the look at all');

    var camera = img.decodeJpg(embedded.bytes)!;
    // The embedded JPEG comes out of LibRaw unrotated; the decode does not.
    if (embedded.flip == 6) {
      camera = img.copyRotate(camera, angle: 90);
    } else if (embedded.flip == 5) {
      camera = img.copyRotate(camera, angle: 270);
    }

    final sOff =
        _lookStats(_lookResize(_fromRgb8(off, preview.width, preview.height)));
    final sOn =
        _lookStats(_lookResize(_fromRgb8(on, preview.width, preview.height)));
    final sCam = _lookStats(_lookResize(camera));

    names.add(base);
    rOffC.add(sOff.contrast / sCam.contrast);
    rOnC.add(sOn.contrast / sCam.contrast);
    rOffS.add(sOff.saturation / sCam.saturation);
    rOnS.add(sOn.saturation / sCam.saturation);

    print('  $base  contrast off ${sOff.contrast.toStringAsFixed(1)} '
        'on ${sOn.contrast.toStringAsFixed(1)} '
        'camera ${sCam.contrast.toStringAsFixed(1)}   '
        'sat off ${sOff.saturation.toStringAsFixed(3)} '
        'on ${sOn.saturation.toStringAsFixed(3)} '
        'camera ${sCam.saturation.toStringAsFixed(3)}');
  }

  // C3c — the table, on every run, pass or fail. A criterion that is only
  // satisfied by naming its exceptions has to show its working every time.
  print('');
  print('  C3c per-frame regression table');
  print('  ${'frame'.padRight(20)} ${'stat'.padRight(10)} '
      '${'r_off'.padLeft(7)} ${'r_on'.padLeft(7)} '
      '${'d_off'.padLeft(7)} ${'d_on'.padLeft(7)} ${'delta'.padLeft(8)}  note');
  final regressed = <String, List<String>>{};
  for (var i = 0; i < names.length; i++) {
    for (final row in [
      ('contrast', rOffC[i], rOnC[i]),
      ('saturation', rOffS[i], rOnS[i]),
    ]) {
      final (stat, off, on) = row;
      final dOff = (off - 1).abs();
      final dOn = (on - 1).abs();
      final worse = dOn > dOff;
      if (worse) (regressed[names[i]] ??= []).add(stat);
      final note = !worse
          ? ''
          : (_acceptedRegressions.contains(names[i])
              ? 'REGRESSED (accepted, §F.6)'
              : 'REGRESSED — not in the accepted set');
      print('  ${names[i].padRight(20)} ${stat.padRight(10)} '
          '${off.toStringAsFixed(3).padLeft(7)} '
          '${on.toStringAsFixed(3).padLeft(7)} '
          '${dOff.toStringAsFixed(3).padLeft(7)} '
          '${dOn.toStringAsFixed(3).padLeft(7)} '
          '${(dOn - dOff).toStringAsFixed(3).padLeft(8)}  $note');
    }
  }
  print('');

  final covered = names.toSet();
  if (!covered.containsAll(_canonicalFrames)) {
    final missing = _canonicalFrames.difference(covered).toList()..sort();
    print('  NOTE this run does not cover the canonical eight frames '
        '(missing ${missing.join(', ')}), so C1, C2 and C3 are skipped rather '
        'than reported as met. The set-level means are only meaningful over '
        'all eight.');
    return failures;
  }

  double mean(List<double> v) => v.reduce((a, b) => a + b) / v.length;
  double lo(List<double> v) => v.reduce(math.min);
  double hi(List<double> v) => v.reduce(math.max);

  final mC = mean(rOnC), loC = lo(rOnC), hiC = hi(rOnC);
  print('  C1 contrast  mean ${mC.toStringAsFixed(3)}  '
      'range ${loC.toStringAsFixed(3)} … ${hiC.toStringAsFixed(3)}');
  check(mC >= 0.90 && mC <= 1.15,
      'C1 the mean contrast ratio is in [0.90, 1.15]');
  check(loC >= 0.75 && hiC <= 1.30, 'C1b no frame is outside [0.75, 1.30]');

  final mS = mean(rOnS), loS = lo(rOnS), hiS = hi(rOnS);
  print('  C2 saturation  mean ${mS.toStringAsFixed(3)}  '
      'range ${loS.toStringAsFixed(3)} … ${hiS.toStringAsFixed(3)}');
  check(mS >= 0.90 && mS <= 1.10,
      'C2 the mean saturation ratio is in [0.90, 1.10]');
  check(loS >= 0.85 && hiS <= 1.15, 'C2b no frame is outside [0.85, 1.15]');

  final unexpected = regressed.keys
      .where((n) => !_acceptedRegressions.contains(n))
      .toList()
    ..sort();
  check(unexpected.isEmpty,
      'C3a only the three frames §F.6 named may regress'
      '${unexpected.isEmpty ? '' : ' — but ${unexpected.join(', ')} did'}');

  var worst = 0.0;
  var worstWhat = '';
  for (var i = 0; i < names.length; i++) {
    if (!_acceptedRegressions.contains(names[i])) continue;
    for (final row in [('contrast', rOnC[i]), ('saturation', rOnS[i])]) {
      final d = (row.$2 - 1).abs();
      if (d > worst) {
        worst = d;
        worstWhat = '${names[i]} ${row.$1}';
      }
    }
  }
  print('  C3b worst accepted regression ${worst.toStringAsFixed(3)} '
      '($worstWhat); §E proposed 0.15 and it is NOT met — accepted at '
      '$_regressionBound, see plan.md §6.');
  check(worst <= _regressionBound,
      'C3b the three named frames stay within $_regressionBound of their '
      'camera');

  return failures;
}

/// Exact equality, for bytes that must match to the last one.
bool _identical(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// Sampled equality, for "these two renders are not the same frame".
bool _same(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i += 997) {
    if (a[i] != b[i]) return false;
  }
  return true;
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
