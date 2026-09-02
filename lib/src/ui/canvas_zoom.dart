// lib/src/ui/canvas_zoom.dart
//
// The canvas's zoom and pan state, as something the keyboard can drive.
//
// InteractiveViewer owns this by default and only exposes it to gestures.
// Handing it an explicit TransformationController is what lets a keypress do
// the same thing a pinch does, and lets the view reset when a new frame is
// opened rather than inheriting the previous one's magnification.

import 'package:flutter/widgets.dart';

class CanvasZoom {
  /// Matches the bounds InteractiveViewer enforces for gestures, so the
  /// keyboard cannot reach a magnification a pinch could not.
  static const double minScale = 0.5;
  static const double maxScale = 8.0;

  /// One keypress. A quarter is small enough to aim with and large enough
  /// that crossing the whole range does not take twenty presses — 0.5 to 8.0
  /// is thirteen steps.
  static const double step = 1.25;

  final TransformationController transform = TransformationController();

  /// The size of the area the image is displayed in, so zoom can be centred
  /// on what the viewer is looking at rather than on the image's own origin.
  /// Set from the canvas's LayoutBuilder.
  Size viewport = Size.zero;

  double get scale => transform.value.getMaxScaleOnAxis();

  bool get canZoomIn => scale < maxScale - 1e-9;
  bool get canZoomOut => scale > minScale + 1e-9;

  void zoomIn() => _zoomBy(step);

  void zoomOut() => _zoomBy(1 / step);

  /// Back to fit-the-window, which is where a newly opened frame starts.
  void reset() => transform.value = Matrix4.identity();

  void dispose() => transform.dispose();

  /// Scale about the centre of the viewport.
  ///
  /// The controller's matrix maps child coordinates to viewport coordinates,
  /// so a zoom that leaves the viewport centre `c` fixed is
  /// `T(c) · S(k) · T(−c)` applied *after* it — pre-multiplied, not appended.
  /// Appending would scale about the image's top-left corner and send whatever
  /// the viewer was looking at off the edge.
  void _zoomBy(double factor) {
    final current = scale;
    final target = (current * factor).clamp(minScale, maxScale);
    if ((target - current).abs() < 1e-9) return;

    final k = target / current;
    final c = viewport.isEmpty
        ? Offset.zero
        : Offset(viewport.width / 2, viewport.height / 2);

    // Scale z along with x and y. Nothing here is three-dimensional, but
    // `getMaxScaleOnAxis` takes the largest of the three column norms, so
    // leaving z at 1 makes every zoom below 1.0 report as exactly 1.0 — and
    // the minimum-scale clamp then never engages.
    final zoom = Matrix4.identity()
      ..translateByDouble(c.dx, c.dy, 0, 1)
      ..scaleByDouble(k, k, k, 1)
      ..translateByDouble(-c.dx, -c.dy, 0, 1);

    transform.value = zoom * transform.value;
  }
}
