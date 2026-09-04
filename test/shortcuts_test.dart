// test/shortcuts_test.dart
//
// The keyboard bindings, and the zoom arithmetic behind two of them.

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:morphosis/src/model/edit.dart';
import 'package:morphosis/src/ui/canvas_zoom.dart';
import 'package:morphosis/src/ui/editor_layout.dart';
import 'package:morphosis/src/ui/theme.dart';

import 'layout_golden_test.dart' as fixtures;

void main() {
  group('zoom arithmetic', () {
    test('starts at one and steps geometrically', () {
      final z = CanvasZoom();
      addTearDown(z.dispose);
      z.viewport = const Size(800, 600);

      expect(z.scale, closeTo(1.0, 1e-9));
      z.zoomIn();
      expect(z.scale, closeTo(CanvasZoom.step, 1e-9));
      z.zoomIn();
      expect(z.scale, closeTo(CanvasZoom.step * CanvasZoom.step, 1e-9));
      z.zoomOut();
      expect(z.scale, closeTo(CanvasZoom.step, 1e-9));
    });

    test('in then out returns exactly where it started', () {
      final z = CanvasZoom();
      addTearDown(z.dispose);
      z.viewport = const Size(800, 600);

      final before = z.transform.value.clone();
      for (var i = 0; i < 5; i++) {
        z.zoomIn();
      }
      for (var i = 0; i < 5; i++) {
        z.zoomOut();
      }
      for (var i = 0; i < 16; i++) {
        expect(z.transform.value.storage[i], closeTo(before.storage[i], 1e-9),
            reason: 'matrix element $i drifted');
      }
    });

    test('clamps to the same bounds InteractiveViewer enforces', () {
      final z = CanvasZoom();
      addTearDown(z.dispose);
      z.viewport = const Size(800, 600);

      for (var i = 0; i < 60; i++) {
        z.zoomIn();
      }
      expect(z.scale, closeTo(CanvasZoom.maxScale, 1e-9));
      expect(z.canZoomIn, isFalse);

      for (var i = 0; i < 60; i++) {
        z.zoomOut();
      }
      expect(z.scale, closeTo(CanvasZoom.minScale, 1e-9));
      expect(z.canZoomOut, isFalse);
    });

    test('holds the viewport centre still', () {
      // The point of scaling about the centre: whatever the viewer was
      // looking at is still under the same pixel afterwards. Scaling about
      // the image origin instead would send it off the edge.
      final z = CanvasZoom();
      addTearDown(z.dispose);
      const viewport = Size(800, 600);
      z.viewport = viewport;

      const centre = Offset(400, 300);
      Offset sceneUnder(Offset viewportPoint) => MatrixUtils.transformPoint(
          Matrix4.inverted(z.transform.value), viewportPoint);

      final before = sceneUnder(centre);
      z.zoomIn();
      z.zoomIn();
      final after = sceneUnder(centre);
      expect(after.dx, closeTo(before.dx, 1e-6));
      expect(after.dy, closeTo(before.dy, 1e-6));
    });

    test('reset returns to fit-the-window', () {
      final z = CanvasZoom();
      addTearDown(z.dispose);
      z.viewport = const Size(800, 600);
      z.zoomIn();
      z.zoomIn();
      expect(z.scale, greaterThan(1.0));
      z.reset();
      expect(z.transform.value, Matrix4.identity());
    });
  });

  group('bindings', () {
    late List<String> fired;
    late CanvasZoom zoom;

    Widget harness({bool withImage = true}) => MediaQuery(
          data: const MediaQueryData(size: Size(1440, 900)),
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: buildTheme(),
            home: EditorLayout(
              state: EditorViewState(
                photos: fixtures.syntheticPhotos(),
                thumbnails: {
                  for (final p in fixtures.syntheticPhotos()) p.path: null
                },
                selected: 2,
                frame: withImage ? fixtures.syntheticFrameInfo() : null,
                histogram: withImage ? fixtures.syntheticHistogram() : null,
                edit: Edit.neutral,
              ),
              onBrowse: () {},
              onExport: () {},
              onSelect: (_) {},
              onEditChanged: (_) {},
              onPreviousImage: () => fired.add('previous'),
              onNextImage: () => fired.add('next'),
              zoom: zoom,
            ),
          ),
        );

    setUp(() {
      fired = [];
      zoom = CanvasZoom();
      zoom.viewport = const Size(800, 600);
    });

    tearDown(() => zoom.dispose());

    testWidgets('arrows step through the folder', (tester) async {
      await tester.pumpWidget(harness());
      await tester.pumpAndSettle();

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump();
      expect(fired, ['previous']);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(fired, ['previous', 'next']);
    });

    testWidgets('minus and equal zoom the canvas', (tester) async {
      await tester.pumpWidget(harness());
      await tester.pumpAndSettle();

      await tester.sendKeyEvent(LogicalKeyboardKey.equal);
      await tester.pump();
      expect(zoom.scale, closeTo(CanvasZoom.step, 1e-9));

      await tester.sendKeyEvent(LogicalKeyboardKey.minus);
      await tester.pump();
      expect(zoom.scale, closeTo(1.0, 1e-9));
    });

    testWidgets('the numpad and shifted variants do the same thing',
        (tester) async {
      await tester.pumpWidget(harness());
      await tester.pumpAndSettle();

      await tester.sendKeyEvent(LogicalKeyboardKey.numpadAdd);
      await tester.pump();
      expect(zoom.scale, closeTo(CanvasZoom.step, 1e-9));

      await tester.sendKeyEvent(LogicalKeyboardKey.numpadSubtract);
      await tester.pump();
      expect(zoom.scale, closeTo(1.0, 1e-9));
    });

    testWidgets('they work without clicking anything first', (tester) async {
      // The Focus is autofocused, so a freshly opened window answers the
      // keyboard. Regression guard: without that, every binding is dead until
      // the user happens to click the canvas.
      await tester.pumpWidget(harness());
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(fired, ['next']);
    });

    testWidgets('a slider never swallows the arrow keys', (tester) async {
      // A focused Slider handles left and right itself. If one could take
      // focus, navigation would work until the first slider was touched and
      // then quietly stop.
      await tester.pumpWidget(harness());
      await tester.pumpAndSettle();

      final slider = find.byType(Slider).first;
      await tester.tap(slider);
      await tester.pumpAndSettle();

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(fired, ['next'], reason: 'the slider took the key');
    });

    // The regression that shipped with the keyword panel.
    //
    // Shortcuts resolves a key event by walking UP the focus tree from the
    // primary focus node. The keyword field is the first widget in this app
    // that can take focus — sliders are ExcludeFocus — and on desktop a tap
    // outside a text field unfocuses it. Unfocusing hands primary focus to the
    // nearest enclosing scope, and if that scope is the route's, it sits ABOVE
    // the Shortcuts widget: every editor binding goes dead for the rest of the
    // session, with nothing on screen to say why.
    //
    // The platform override is load-bearing. Tests default to android, where
    // a tap outside does not unfocus, so without it this passes while the real
    // application is broken.
    group('after the keyword field has had focus', () {
      // Set and cleared inside each body, not in setUp/tearDown: the test
      // framework checks this variable when the body returns, which is before
      // tearDown runs.
      Future<void> onLinux(Future<void> Function() body) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.linux;
        try {
          await body();
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      }

      Widget catalogued() => MediaQuery(
            data: const MediaQueryData(size: Size(1440, 900)),
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: buildTheme(),
              home: EditorLayout(
                state: EditorViewState(
                  photos: fixtures.syntheticPhotos(),
                  thumbnails: {
                    for (final p in fixtures.syntheticPhotos()) p.path: null
                  },
                  selected: 2,
                  frame: fixtures.syntheticFrameInfo(),
                  histogram: fixtures.syntheticHistogram(),
                  edit: Edit.neutral,
                  // An entry is what enables the keyword field. Without one it
                  // is disabled and can never take focus, which is why the
                  // tests above never saw this.
                  entry: fixtures.syntheticEntry(),
                  knownKeywords: fixtures.syntheticKeywords,
                ),
                onBrowse: () {},
                onExport: () {},
                onSelect: (_) {},
                onEditChanged: (_) {},
                onKeywordsChanged: (_) {},
                onPreviousImage: () => fired.add('previous'),
                onNextImage: () => fired.add('next'),
                zoom: zoom,
              ),
            ),
          );

      testWidgets('the canvas still zooms once the field is left',
          (tester) async {
        await onLinux(() async {
          await tester.pumpWidget(catalogued());
          await tester.pumpAndSettle();

          await tester.tap(find.byType(TextField));
          await tester.pumpAndSettle();
          // Moving a slider is what a photographer does next, and it is what
          // takes the focus away again.
          await tester.tap(find.byType(Slider).first);
          await tester.pumpAndSettle();

          await tester.sendKeyEvent(LogicalKeyboardKey.equal);
          await tester.pump();
          expect(zoom.scale, closeTo(CanvasZoom.step, 1e-9));
        });
      });

      testWidgets('the arrows still step once the field is left',
          (tester) async {
        await onLinux(() async {
          await tester.pumpWidget(catalogued());
          await tester.pumpAndSettle();

          await tester.tap(find.byType(TextField));
          await tester.pumpAndSettle();
          await tester.tap(find.byType(Slider).first);
          await tester.pumpAndSettle();

          await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
          await tester.pump();
          expect(fired, ['next']);
        });
      });

      // The other half of the same problem. While the field has focus the
      // photographer is typing, and a hyphen belongs in "back-lit" rather than
      // zooming the canvas out from under them.
      testWidgets('the zoom keys are typing while the field has focus',
          (tester) async {
        await onLinux(() async {
          await tester.pumpWidget(catalogued());
          await tester.pumpAndSettle();

          await tester.tap(find.byType(TextField));
          await tester.pumpAndSettle();

          // Only the main-row keys: flutter_test has no Linux key code for
          // the numpad, and they are neutralised by the same map anyway.
          for (final key in [
            LogicalKeyboardKey.minus,
            LogicalKeyboardKey.equal,
          ]) {
            await tester.sendKeyEvent(key);
            await tester.pump();
          }
          expect(zoom.scale, closeTo(1.0, 1e-9),
              reason: 'a keypress meant for the field zoomed the canvas');
        });
      });

      testWidgets('tapping the canvas also leaves the bindings alive',
          (tester) async {
        await onLinux(() async {
          await tester.pumpWidget(catalogued());
          await tester.pumpAndSettle();

          await tester.tap(find.byType(TextField));
          await tester.pumpAndSettle();
          await tester.tapAt(const Offset(700, 400));
          await tester.pumpAndSettle();

          await tester.sendKeyEvent(LogicalKeyboardKey.equal);
          await tester.pump();
          expect(zoom.scale, closeTo(CanvasZoom.step, 1e-9));
        });
      });
    });

    testWidgets('the canvas still zooms after a slider is used',
        (tester) async {
      await tester.pumpWidget(harness());
      await tester.pumpAndSettle();
      await tester.tap(find.byType(Slider).first);
      await tester.pumpAndSettle();

      await tester.sendKeyEvent(LogicalKeyboardKey.equal);
      await tester.pump();
      expect(zoom.scale, closeTo(CanvasZoom.step, 1e-9));
    });
  });
}
