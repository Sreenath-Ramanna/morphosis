// test/layout_golden_test.dart
//
// Renders the editor's real arrangement against synthetic state, at window
// size, and checks it against a committed image.
//
// It catches the two things a widget test otherwise misses on a desktop
// layout: a panel that overflows at its fixed width — every control in the
// right column is text plus a slider inside 320 px — and a change that
// silently moves something. Regenerate deliberately with
//
//     flutter test --update-goldens test/layout_golden_test.dart
//
// and look at the result before committing it.

import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:morphosis/src/catalog/catalog.dart';
import 'package:morphosis/src/model/edit.dart';
import 'package:morphosis/src/pipeline/colour_temp.dart';
import 'package:morphosis/src/pipeline/processor.dart';
import 'package:morphosis/src/ria/ria.dart';
import 'package:morphosis/src/ui/editor_layout.dart';
import 'package:morphosis/src/ui/photo_list.dart';
import 'package:morphosis/src/ui/theme.dart';

const _size = Size(1440, 900);

/// Stands in for a decoded frame: a synthetic photograph, so the canvas has
/// something with real tonal range in it rather than a flat rectangle.
///
/// Must be awaited inside `tester.runAsync`: `decodeImageFromPixels` completes
/// on the engine's thread, and the fake clock a widget test installs never
/// lets that callback run.
Future<ui.Image> syntheticFrame(int w, int h) {
  final pixels = Uint8List(w * h * 4);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final i = (y * w + x) * 4;
      final sky = y / h;
      final band = ((x / w) * 6).floor().isEven ? 8 : 0;
      pixels[i] = (150 - 90 * sky).round().clamp(0, 255) + band;
      pixels[i + 1] = (170 - 100 * sky).round().clamp(0, 255) + band;
      pixels[i + 2] = (200 - 70 * sky).round().clamp(0, 255) + band;
      pixels[i + 3] = 255;
    }
  }
  final done = Completer<ui.Image>();
  ui.decodeImageFromPixels(pixels, w, h, ui.PixelFormat.rgba8888,
      done.complete);
  return done.future;
}

Histogram syntheticHistogram() {
  final r = Uint32List(256), g = Uint32List(256), b = Uint32List(256);
  final luma = Uint32List(256);
  for (var i = 0; i < 256; i++) {
    double bump(double centre, double width, double height) {
      final d = (i - centre) / width;
      return height * (1 / (1 + d * d * d * d));
    }

    r[i] = (bump(150, 40, 9000) + bump(60, 25, 2500)).round();
    g[i] = (bump(140, 45, 9500) + bump(70, 30, 2200)).round();
    b[i] = (bump(120, 55, 8000) + bump(90, 35, 3000)).round();
    luma[i] = ((r[i] + g[i] + b[i]) / 3).round();
  }
  return Histogram(
    red: r,
    green: g,
    blue: b,
    luma: luma,
    pixels: 1707008,
    clippedBlack: 0.0004,
    clippedWhite: 0.0021,
  );
}

FrameInfo syntheticFrameInfo() => FrameInfo(
      path: '/home/photos/2026-09-02/20250803_A0A8111.CR3',
      metadata: RawMetadata(
        make: 'Canon',
        model: 'EOS R7',
        lens: 'RF100-500mm F4.5-7.1 L IS USM',
        isoSpeed: 1000,
        shutter: 1 / 1600,
        aperture: 6.3,
        focalLen: 500,
        width: 6984,
        height: 4660,
        capturedAt: DateTime.utc(2025, 8, 2, 20, 6, 47),
      ),
      asShot: const ColourTemperature(
        kelvin: 5787,
        duv: 0.0090,
        fromCameraTable: true,
        reliable: true,
      ),
      minKelvin: 2400,
      maxKelvin: 12000,
      autoGreyPoint: 0.0721,
      medianEv: -3.09,
      fullWidth: 6984,
      fullHeight: 4660,
      previewWidth: 1600,
      previewHeight: 1068,
    );

/// A frame the catalogue already knows: keywords on it, and adjustments made
/// in an earlier session. That is what puts the keyword panel and the restored
/// banner into the golden, rather than only the widened column.
CatalogEntry syntheticEntry() => CatalogEntry(
      sha256: 'fa166f05a5b0f2669469a8aa382f93b0c28876324ebaebda091e732336a4d7d7',
      displayName: '20250803_A0A8111.CR3',
      sizeBytes: 22300000,
      capturedAt: DateTime.utc(2025, 8, 2, 20, 6, 47),
      camera: 'Canon EOS R7',
      keywords: KeywordSet.parse('gull, north coast, backlit'),
      firstSeen: DateTime.utc(2025, 8, 4, 9),
      lastEdited: DateTime.utc(2025, 9, 2, 18, 30),
    );

const List<KeywordCount> syntheticKeywords = [
  KeywordCount('north coast', 42),
  KeywordCount('gull', 18),
  KeywordCount('backlit', 7),
];

List<PhotoEntry> syntheticPhotos() => const [
      PhotoEntry('/p/20250803_A0A8111.CR3', '20250803_A0A8111.CR3'),
      PhotoEntry('/p/20250803_A0A8123.CR3', '20250803_A0A8123.CR3'),
      PhotoEntry('/p/20250803_A0A8129.CR3', '20250803_A0A8129.CR3'),
      PhotoEntry('/p/20250803_A0A8132.CR3', '20250803_A0A8132.CR3'),
      PhotoEntry('/p/20250803_A0A8138.CR3', '20250803_A0A8138.CR3'),
      PhotoEntry('/p/20250803_A0A8152.CR3', '20250803_A0A8152.CR3'),
      PhotoEntry('/p/DSC_1436.NEF', 'DSC_1436.NEF'),
      PhotoEntry('/p/DSC_1437.NEF', 'DSC_1437.NEF'),
      PhotoEntry('/p/DSC_1438.NEF', 'DSC_1438.NEF'),
      PhotoEntry('/p/DSC_1439.NEF', 'DSC_1439.NEF'),
    ];

Widget harness(EditorViewState state) => MediaQuery(
      data: const MediaQueryData(size: _size),
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildTheme(),
        home: EditorLayout(
          state: state,
          onBrowse: () {},
          onExport: () {},
          onSelect: (_) {},
          onEditChanged: (_) {},
        ),
      ),
    );

void main() {
  // Only the image comparison is tagged. The golden is engine-rendered and so
  // is tied to the exact Flutter version that produced it, which CI runs apart
  // from the blocking suite; the layout assertions below carry no such tie.
  testWidgets('the editor lays out at window size', tags: 'golden',
      (tester) async {
    tester.view.physicalSize = _size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final image = (await tester.runAsync(() => syntheticFrame(1600, 1068)))!;
    addTearDown(image.dispose);

    final state = EditorViewState(
      folder: '/home/photos/2026-09-02',
      photos: syntheticPhotos(),
      thumbnails: {for (final p in syntheticPhotos()) p.path: null},
      selected: 0,
      frame: syntheticFrameInfo(),
      image: image,
      histogram: syntheticHistogram(),
      edit: const Edit(
        temperatureK: 6400,
        blackEv: -0.6,
        shadowEv: 1.4,
        highlightEv: -0.9,
        whiteEv: 0.4,
        brightnessEv: 0.3,
        contrastEv: 0.7,
        sharpness: 0.6,
        saturation: 18,
        highlightRolloff: true,
      ),
      status: '10 RAW files',
      renderMillis: 64,
      entry: syntheticEntry(),
      knownKeywords: syntheticKeywords,
      restoredFrom: DateTime.utc(2025, 9, 2, 18, 30),
    );

    await tester.pumpWidget(harness(state));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    await expectLater(find.byType(EditorLayout),
        matchesGoldenFile('goldens/editor.png'));
  });

  testWidgets('the empty state lays out, and every control is reachable',
      (tester) async {
    tester.view.physicalSize = _size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(harness(const EditorViewState()));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('Browse folder'), findsOneWidget);
    expect(find.text('Export'), findsOneWidget);
    expect(find.text('Browse to a folder of RAW files to begin.'),
        findsOneWidget);
    expect(find.text('No RAW files.\nChoose a folder to begin.'),
        findsOneWidget);
  });

  testWidgets('every requested control is present and labelled',
      (tester) async {
    tester.view.physicalSize = _size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(harness(EditorViewState(
      frame: syntheticFrameInfo(),
      histogram: syntheticHistogram(),
      photos: syntheticPhotos(),
      // Present-but-null means "looked, and this file has no embedded JPEG".
      // Leaving the map empty would mean "not looked yet", and the tiles would
      // spin forever — which pumpAndSettle waits for.
      thumbnails: {for (final p in syntheticPhotos()) p.path: null},
      selected: 0,
    )));
    await tester.pumpAndSettle();

    // The file name of the current image.
    expect(find.text('20250803_A0A8111.CR3'), findsWidgets);
    // Its histogram.
    expect(find.textContaining('clipped black'), findsOneWidget);
    // And one slider per requested adjustment, plus the export button. The
    // panel scrolls, and a ListView does not build what is off screen, so the
    // later controls have to be scrolled to rather than merely looked for.
    final panel = find.byType(Scrollable).last;
    for (final label in [
      'Colour temperature',
      'Black level',
      'Shadow',
      'Highlight',
      'White level',
      'Brightness',
      'Contrast',
      'Saturation',
      'Sharpness',
    ]) {
      await tester.scrollUntilVisible(find.text(label), 120,
          scrollable: panel);
      expect(find.text(label), findsOneWidget, reason: 'missing $label');
    }
    expect(find.text('Export'), findsOneWidget);

    // As-shot temperature is shown, and the slider starts there. Back to the
    // top of the panel to see it: the stack is taller than the viewport, so
    // reaching the last control scrolls the first one off.
    await tester.scrollUntilVisible(find.text('Colour temperature'), -120,
        scrollable: panel);
    expect(find.text('5787 K'), findsOneWidget);
  });

  // The formatter is the one part of the control no golden can assert and no
  // render test reaches: an integer, a sign, and U+2212 rather than a hyphen.
  testWidgets('the saturation value reads as a signed integer', (tester) async {
    tester.view.physicalSize = _size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    Future<void> pumpAt(double saturation) async {
      await tester.pumpWidget(harness(EditorViewState(
        frame: syntheticFrameInfo(),
        histogram: syntheticHistogram(),
        photos: syntheticPhotos(),
        thumbnails: {for (final p in syntheticPhotos()) p.path: null},
        selected: 0,
        edit: Edit(saturation: saturation),
      )));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.text('Saturation'), 120,
          scrollable: find.byType(Scrollable).last);
    }

    await pumpAt(18);
    expect(find.text('+18'), findsOneWidget);

    await pumpAt(-7.4);
    expect(find.text('−7'), findsOneWidget, reason: 'U+2212, not a hyphen');

    await pumpAt(0);
    expect(find.text('0'), findsOneWidget);
  });

  testWidgets('a temperature the camera cannot express disables the control',
      (tester) async {
    tester.view.physicalSize = _size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final info = syntheticFrameInfo();
    await tester.pumpWidget(harness(EditorViewState(
      frame: FrameInfo(
        path: info.path,
        metadata: info.metadata,
        asShot: const ColourTemperature(
            kelvin: 5500, duv: 0.09, fromCameraTable: false, reliable: false),
        minKelvin: 2000,
        maxKelvin: 12000,
        autoGreyPoint: info.autoGreyPoint,
        medianEv: info.medianEv,
        fullWidth: info.fullWidth,
        fullHeight: info.fullHeight,
        previewWidth: info.previewWidth,
        previewHeight: info.previewHeight,
      ),
      histogram: syntheticHistogram(),
    )));
    await tester.pumpAndSettle();

    final slider = tester.widgetList<Slider>(find.byType(Slider)).first;
    expect(slider.onChanged, isNull);
    expect(find.textContaining('too far off the Planckian locus'),
        findsOneWidget);
  });
}
