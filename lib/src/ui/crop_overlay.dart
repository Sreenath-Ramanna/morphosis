// lib/src/ui/crop_overlay.dart
//
// The crop rectangle, dragged directly on the image.
//
// Pan and zoom are switched off while this is up. A crop tool that also
// scrolls under the cursor makes both gestures ambiguous, and the whole frame
// has to stay visible anyway — you cannot choose what to cut away while
// looking at part of it.

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../model/geometry.dart';
import 'theme.dart';

/// How close the pointer has to be to a handle, in logical pixels.
const double _handleSlop = 22.0;

/// Smallest crop, as a fraction of the frame. Below this the handles overlap
/// each other and the rectangle can no longer be grabbed to make it bigger.
const double _minCropFraction = 0.05;

/// Margin between the image and the edge of the canvas, matching the one the
/// normal viewer uses so the picture does not jump when the tab changes.
const double cropCanvasInset = 24.0;

/// Where an image of the given aspect lands inside `available` under
/// BoxFit.contain, which is what the overlay has to align with.
///
/// Public because the overlay's hit testing is meaningless without it: a test
/// that wants to drag a corner has to know where the corner is, and computing
/// it a second time in the test would be asserting against a copy of the rule
/// rather than against the rule.
Rect fittedImageRect(Size available, double imageAspect) {
  final box = Size(
    math.max(1.0, available.width - cropCanvasInset * 2),
    math.max(1.0, available.height - cropCanvasInset * 2),
  );
  var w = box.width;
  var h = w / imageAspect;
  if (h > box.height) {
    h = box.height;
    w = h * imageAspect;
  }
  return Rect.fromLTWH(
    cropCanvasInset + (box.width - w) / 2,
    cropCanvasInset + (box.height - h) / 2,
    w,
    h,
  );
}

enum _Grip { none, move, left, right, top, bottom, tl, tr, bl, br }

class CropCanvas extends StatefulWidget {
  final ui.Image image;
  final Geometry geometry;
  final ValueChanged<Geometry> onChanged;

  const CropCanvas({
    super.key,
    required this.image,
    required this.geometry,
    required this.onChanged,
  });

  @override
  State<CropCanvas> createState() => _CropCanvasState();
}

class _CropCanvasState extends State<CropCanvas> {
  _Grip _grip = _Grip.none;

  /// The crop as it was when the drag began, so each update is computed from
  /// a fixed origin rather than accumulating rounding from the previous frame.
  CropRect? _startCrop;
  Offset? _startPointer;

  CropRect get _crop => widget.geometry.crop;

  /// The bounds the crop must stay inside: the whole frame, or the largest
  /// rectangle with no blank corner once straightening is applied.
  CropRect get _bounds => widget.geometry
      .straightenBounds(widget.image.width, widget.image.height);

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final rect = _fittedRect(constraints.biggest);

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onPanStart: (d) => _onPanStart(d.localPosition, rect),
          onPanUpdate: (d) => _onPanUpdate(d.localPosition, rect),
          onPanEnd: (_) => setState(() => _grip = _Grip.none),
          child: MouseRegion(
            cursor: _grip == _Grip.none
                ? SystemMouseCursors.precise
                : SystemMouseCursors.grabbing,
            child: Stack(
              children: [
                Positioned.fromRect(
                  rect: rect,
                  child: RawImage(
                    image: widget.image,
                    fit: BoxFit.fill,
                    filterQuality: FilterQuality.medium,
                  ),
                ),
                Positioned.fill(
                  child: CustomPaint(
                    painter: _CropPainter(
                      imageRect: rect,
                      crop: _crop,
                      bounds: _bounds,
                      dragging: _grip != _Grip.none,
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Rect _fittedRect(Size available) => fittedImageRect(
      available, widget.image.width / widget.image.height);

  void _onPanStart(Offset p, Rect rect) {
    setState(() {
      _grip = _gripAt(p, rect);
      _startCrop = _crop;
      _startPointer = p;
    });
  }

  _Grip _gripAt(Offset p, Rect rect) {
    final r = _screenRect(rect, _crop);
    final nearL = (p.dx - r.left).abs() < _handleSlop;
    final nearR = (p.dx - r.right).abs() < _handleSlop;
    final nearT = (p.dy - r.top).abs() < _handleSlop;
    final nearB = (p.dy - r.bottom).abs() < _handleSlop;
    final insideY = p.dy > r.top - _handleSlop && p.dy < r.bottom + _handleSlop;
    final insideX = p.dx > r.left - _handleSlop && p.dx < r.right + _handleSlop;

    if (nearL && nearT) return _Grip.tl;
    if (nearR && nearT) return _Grip.tr;
    if (nearL && nearB) return _Grip.bl;
    if (nearR && nearB) return _Grip.br;
    if (nearL && insideY) return _Grip.left;
    if (nearR && insideY) return _Grip.right;
    if (nearT && insideX) return _Grip.top;
    if (nearB && insideX) return _Grip.bottom;
    if (r.contains(p)) return _Grip.move;
    return _Grip.none;
  }

  void _onPanUpdate(Offset p, Rect rect) {
    final grip = _grip;
    final start = _startCrop;
    final from = _startPointer;
    if (grip == _Grip.none || start == null || from == null) return;

    // Pointer travel, in fractions of the frame.
    final dx = (p.dx - from.dx) / rect.width;
    final dy = (p.dy - from.dy) / rect.height;

    final bounds = _bounds;
    var next = grip == _Grip.move
        ? _moved(start, dx, dy, bounds)
        : _resized(start, grip, dx, dy, bounds);

    next = _applyAspect(next, grip, bounds);
    if (next != _crop) {
      widget.onChanged(widget.geometry.copyWith(crop: next));
    }
  }

  CropRect _moved(CropRect start, double dx, double dy, CropRect bounds) {
    // Slide, then stop at the bounds rather than shrinking: a drag that hits
    // the edge should park there, not resize the rectangle.
    final w = start.width, h = start.height;
    var l = (start.left + dx).clamp(bounds.left, bounds.right - w);
    var t = (start.top + dy).clamp(bounds.top, bounds.bottom - h);
    return CropRect(l, t, l + w, t + h);
  }

  CropRect _resized(
      CropRect s, _Grip grip, double dx, double dy, CropRect bounds) {
    var l = s.left, t = s.top, r = s.right, b = s.bottom;

    if (grip == _Grip.left || grip == _Grip.tl || grip == _Grip.bl) {
      l = (s.left + dx).clamp(bounds.left, r - _minCropFraction);
    }
    if (grip == _Grip.right || grip == _Grip.tr || grip == _Grip.br) {
      r = (s.right + dx).clamp(l + _minCropFraction, bounds.right);
    }
    if (grip == _Grip.top || grip == _Grip.tl || grip == _Grip.tr) {
      t = (s.top + dy).clamp(bounds.top, b - _minCropFraction);
    }
    if (grip == _Grip.bottom || grip == _Grip.bl || grip == _Grip.br) {
      b = (s.bottom + dy).clamp(t + _minCropFraction, bounds.bottom);
    }
    return CropRect(l, t, r, b);
  }

  /// Force the constrained shape, holding whichever corner is not being
  /// dragged. Ratios are in output *pixels*, so the frame's own dimensions
  /// have to come into it — a 1:1 crop of a 3:2 frame is not a square in
  /// normalised coordinates.
  CropRect _applyAspect(CropRect c, _Grip grip, CropRect bounds) {
    final sourceRatio = widget.image.width / widget.image.height;
    final ratio = widget.geometry.aspect.resolve(sourceRatio);
    if (ratio == null) return c.fittedInside(bounds);

    // width/height in normalised units for the requested pixel ratio.
    final normRatio = ratio / sourceRatio;

    var w = c.width;
    var h = w / normRatio;

    // Drive from whichever dimension the user actually moved.
    final drivenByHeight = grip == _Grip.top || grip == _Grip.bottom;
    if (drivenByHeight) {
      h = c.height;
      w = h * normRatio;
    }

    // Anchor the edge opposite the one being dragged.
    final anchorRight =
        grip == _Grip.left || grip == _Grip.tl || grip == _Grip.bl;
    final anchorBottom =
        grip == _Grip.top || grip == _Grip.tl || grip == _Grip.tr;

    var l = anchorRight ? c.right - w : c.left;
    var t = anchorBottom ? c.bottom - h : c.top;

    // Shrink to fit rather than distort, so the shape is never broken by the
    // bounds.
    final maxW = bounds.width, maxH = bounds.height;
    if (w > maxW) {
      w = maxW;
      h = w / normRatio;
    }
    if (h > maxH) {
      h = maxH;
      w = h * normRatio;
    }
    l = l.clamp(bounds.left, bounds.right - w);
    t = t.clamp(bounds.top, bounds.bottom - h);

    return CropRect(l, t, l + w, t + h);
  }

  Rect _screenRect(Rect image, CropRect c) => Rect.fromLTRB(
        image.left + c.left * image.width,
        image.top + c.top * image.height,
        image.left + c.right * image.width,
        image.top + c.bottom * image.height,
      );
}

class _CropPainter extends CustomPainter {
  final Rect imageRect;
  final CropRect crop;
  final CropRect bounds;
  final bool dragging;

  _CropPainter({
    required this.imageRect,
    required this.crop,
    required this.bounds,
    required this.dragging,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final r = Rect.fromLTRB(
      imageRect.left + crop.left * imageRect.width,
      imageRect.top + crop.top * imageRect.height,
      imageRect.left + crop.right * imageRect.width,
      imageRect.top + crop.bottom * imageRect.height,
    );

    // Everything outside the crop, dimmed. Even-odd so the rectangle is a
    // hole rather than a second filled shape.
    canvas.drawPath(
      Path()
        ..fillType = PathFillType.evenOdd
        ..addRect(Offset.zero & size)
        ..addRect(r),
      Paint()..color = const Color(0xB0000000),
    );

    // The part of the frame that straightening has put out of reach, marked
    // so it is clear the rectangle is being stopped by something real.
    if (!bounds.isFull) {
      final b = Rect.fromLTRB(
        imageRect.left + bounds.left * imageRect.width,
        imageRect.top + bounds.top * imageRect.height,
        imageRect.left + bounds.right * imageRect.width,
        imageRect.top + bounds.bottom * imageRect.height,
      );
      canvas.drawRect(
        b,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1
          ..color = Chrome.warn.withValues(alpha: 0.55),
      );
    }

    // Thirds, which is what the guides are for.
    final guide = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = Colors.white.withValues(alpha: dragging ? 0.42 : 0.20);
    for (var i = 1; i < 3; i++) {
      final x = r.left + r.width * i / 3;
      final y = r.top + r.height * i / 3;
      canvas.drawLine(Offset(x, r.top), Offset(x, r.bottom), guide);
      canvas.drawLine(Offset(r.left, y), Offset(r.right, y), guide);
    }

    canvas.drawRect(
      r,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4
        ..color = Colors.white.withValues(alpha: 0.92),
    );

    // Corner brackets and edge ticks: they show where to grab without the
    // eight filled squares that would cover the picture underneath.
    final grip = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.square
      ..color = Colors.white;
    const arm = 18.0;
    void bracket(Offset corner, double sx, double sy) {
      canvas.drawLine(corner, corner.translate(arm * sx, 0), grip);
      canvas.drawLine(corner, corner.translate(0, arm * sy), grip);
    }

    bracket(r.topLeft, 1, 1);
    bracket(r.topRight, -1, 1);
    bracket(r.bottomLeft, 1, -1);
    bracket(r.bottomRight, -1, -1);

    const tick = 14.0;
    canvas.drawLine(Offset(r.center.dx - tick / 2, r.top),
        Offset(r.center.dx + tick / 2, r.top), grip);
    canvas.drawLine(Offset(r.center.dx - tick / 2, r.bottom),
        Offset(r.center.dx + tick / 2, r.bottom), grip);
    canvas.drawLine(Offset(r.left, r.center.dy - tick / 2),
        Offset(r.left, r.center.dy + tick / 2), grip);
    canvas.drawLine(Offset(r.right, r.center.dy - tick / 2),
        Offset(r.right, r.center.dy + tick / 2), grip);
  }

  @override
  bool shouldRepaint(_CropPainter old) =>
      old.imageRect != imageRect ||
      old.crop != crop ||
      old.bounds != bounds ||
      old.dragging != dragging;
}
