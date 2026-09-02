// test/tabs_test.dart
//
// The three-tab right-hand panel, and the crop rectangle's behaviour on the
// canvas.

import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:morphosis/src/model/edit.dart';
import 'package:morphosis/src/model/geometry.dart';
import 'package:morphosis/src/ui/crop_overlay.dart';
import 'package:morphosis/src/ui/editor_layout.dart';
import 'package:morphosis/src/ui/right_panel.dart';
import 'package:morphosis/src/ui/theme.dart';

import 'layout_golden_test.dart' as fixtures;

const _size = Size(1440, 900);

Future<ui.Image> squareImage(int w, int h) {
  final pixels = Uint8List(w * h * 4);
  for (var i = 0; i < w * h; i++) {
    pixels[i * 4] = 120;
    pixels[i * 4 + 1] = 130;
    pixels[i * 4 + 2] = 140;
    pixels[i * 4 + 3] = 255;
  }
  final done = Completer<ui.Image>();
  ui.decodeImageFromPixels(pixels, w, h, ui.PixelFormat.rgba8888,
      done.complete);
  return done.future;
}

void main() {
  late EditorTab tab;
  late Geometry geometry;
  ui.Image? image;

  Widget harness({EditorTab? active, Geometry? g}) => MediaQuery(
        data: const MediaQueryData(size: _size),
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: buildTheme(),
          home: EditorLayout(
            state: EditorViewState(
              photos: fixtures.syntheticPhotos(),
              thumbnails: {
                for (final p in fixtures.syntheticPhotos()) p.path: null
              },
              selected: 0,
              frame: fixtures.syntheticFrameInfo(),
              histogram: fixtures.syntheticHistogram(),
              image: image,
              edit: Edit(geometry: g ?? geometry),
              tab: active ?? tab,
            ),
            onBrowse: () {},
            onExport: () {},
            onSelect: (_) {},
            onEditChanged: (_) {},
            onTabChanged: (t) => tab = t,
            onGeometryChanged: (g) => geometry = g,
          ),
        ),
      );

  setUp(() {
    tab = EditorTab.colour;
    geometry = Geometry.identity;
  });

  group('the tab strip', () {
    testWidgets('shows all three tabs, with masks disabled', (tester) async {
      tester.view.physicalSize = _size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(harness());
      await tester.pumpAndSettle();

      expect(find.text('Colour'), findsOneWidget);
      expect(find.text('Crop'), findsOneWidget);
      expect(find.text('Masks'), findsOneWidget);

      await tester.tap(find.text('Masks'));
      await tester.pumpAndSettle();
      expect(tab, EditorTab.colour, reason: 'masks must not be selectable');

      await tester.tap(find.text('Crop'));
      await tester.pumpAndSettle();
      expect(tab, EditorTab.crop);
    });

    testWidgets('the colour tab still holds every tonal control',
        (tester) async {
      tester.view.physicalSize = _size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(harness(active: EditorTab.colour));
      await tester.pumpAndSettle();

      final panel = find.byType(Scrollable).last;
      for (final label in [
        'Colour temperature',
        'Black level',
        'Shadow',
        'Highlight',
        'White level',
        'Brightness',
        'Contrast',
        'Sharpness',
      ]) {
        await tester.scrollUntilVisible(find.text(label), 120,
            scrollable: panel);
        expect(find.text(label), findsOneWidget, reason: 'missing $label');
      }
    });

    testWidgets('the crop tab holds rotate, straighten and aspect',
        (tester) async {
      tester.view.physicalSize = _size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(harness(active: EditorTab.crop));
      await tester.pumpAndSettle();

      expect(find.text('Left'), findsOneWidget);
      expect(find.text('Right'), findsOneWidget);
      expect(find.text('Straighten'), findsOneWidget);
      for (final label in ['Free', 'Original', '1:1', '3:2', '16:9']) {
        expect(find.text(label), findsOneWidget, reason: 'missing $label');
      }
    });

    testWidgets('the masks tab says it is not implemented', (tester) async {
      tester.view.physicalSize = _size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(harness(active: EditorTab.masks));
      await tester.pumpAndSettle();
      expect(find.text('Not implemented yet.'), findsOneWidget);
    });
  });

  group('rotate buttons', () {
    testWidgets('turn the frame each way', (tester) async {
      tester.view.physicalSize = _size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(harness(active: EditorTab.crop));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Right'));
      await tester.pumpAndSettle();
      expect(geometry.quarterTurns, 1);

      await tester.pumpWidget(harness(active: EditorTab.crop, g: geometry));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Left'));
      await tester.pumpAndSettle();
      expect(geometry.quarterTurns, 0);
    });
  });

  group('the crop rectangle', () {
    testWidgets('replaces the pan-and-zoom viewer in crop mode',
        (tester) async {
      tester.view.physicalSize = _size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      image = await tester.runAsync(() => squareImage(600, 400));
      addTearDown(() {
        image?.dispose();
        image = null;
      });

      await tester.pumpWidget(harness(active: EditorTab.colour));
      await tester.pumpAndSettle();
      expect(find.byType(InteractiveViewer), findsOneWidget);
      expect(find.byType(CropCanvas), findsNothing);

      await tester.pumpWidget(harness(active: EditorTab.crop));
      await tester.pumpAndSettle();
      expect(find.byType(CropCanvas), findsOneWidget);
      expect(find.byType(InteractiveViewer), findsNothing,
          reason: 'pan and zoom must be off while cropping');
    });

    testWidgets('dragging a corner shrinks it, and it stays inside the frame',
        (tester) async {
      tester.view.physicalSize = _size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      image = await tester.runAsync(() => squareImage(600, 400));
      addTearDown(() {
        image?.dispose();
        image = null;
      });

      await tester.pumpWidget(harness(active: EditorTab.crop));
      await tester.pumpAndSettle();

      // The crop starts full, so its top-left corner is the image's.
      final canvas = tester.getRect(find.byType(CropCanvas));
      final fitted = fittedImageRect(canvas.size, 600 / 400);
      final start = canvas.topLeft + fitted.topLeft;
      await tester.dragFrom(start, const Offset(120, 90));
      await tester.pumpAndSettle();

      expect(geometry.crop.left, greaterThan(0.0));
      expect(geometry.crop.top, greaterThan(0.0));
      expect(geometry.crop.right, lessThanOrEqualTo(1.0));
      expect(geometry.crop.bottom, lessThanOrEqualTo(1.0));
      expect(geometry.crop.width, greaterThan(0.0));
      expect(geometry.crop.height, greaterThan(0.0));
      expect(canvas.width, greaterThan(0));
    });

    testWidgets('a constrained crop keeps its shape', (tester) async {
      tester.view.physicalSize = _size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      image = await tester.runAsync(() => squareImage(600, 400));
      addTearDown(() {
        image?.dispose();
        image = null;
      });

      geometry = const Geometry(aspect: AspectOption('1:1', 1.0));
      await tester.pumpWidget(harness(active: EditorTab.crop));
      await tester.pumpAndSettle();

      final canvas = tester.getRect(find.byType(CropCanvas));
      final fitted = fittedImageRect(canvas.size, 600 / 400);
      final start = canvas.topLeft + fitted.topLeft;
      await tester.dragFrom(start, const Offset(150, 40));
      await tester.pumpAndSettle();

      // The ratio is in output pixels, so a square crop of a 3:2 frame is
      // 1.5x wider than it is tall in normalised units.
      final pixelRatio =
          (geometry.crop.width * 600) / (geometry.crop.height * 400);
      expect(pixelRatio, closeTo(1.0, 0.02));
    });
  });
}
