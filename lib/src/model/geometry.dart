// lib/src/model/geometry.dart
//
// Rotation and crop, as a value.
//
// Kept apart from `Edit` because it is a different kind of thing: the tonal
// controls change what a pixel is, this changes which pixels there are. The
// pipeline treats it that way too — geometry is applied once, to the
// scene-referred buffer, and the tone pass then runs over the result. That
// ordering is what makes the histogram and the automatic grey point describe
// the crop the viewer is looking at rather than the whole frame.

import 'dart:math' as math;

/// The largest straighten angle offered, in degrees.
///
/// Beyond about fifteen degrees the largest rectangle that still fits inside
/// the rotated frame has lost more than a third of its area, and what the tool
/// is for — levelling a horizon — never needs it.
const double maxStraightenDegrees = 15.0;

/// A crop, in fractions of the rotated frame. (0,0)-(1,1) is the whole thing.
class CropRect {
  final double left;
  final double top;
  final double right;
  final double bottom;

  const CropRect(this.left, this.top, this.right, this.bottom);

  static const CropRect full = CropRect(0, 0, 1, 1);

  double get width => right - left;
  double get height => bottom - top;
  bool get isFull =>
      left <= 0 && top <= 0 && right >= 1 && bottom >= 1;

  CropRect clampedToUnit() => CropRect(
        left.clamp(0.0, 1.0),
        top.clamp(0.0, 1.0),
        right.clamp(0.0, 1.0),
        bottom.clamp(0.0, 1.0),
      );

  /// Shrink toward the centre until the rect fits inside `bounds`.
  CropRect fittedInside(CropRect bounds) {
    var l = left.clamp(bounds.left, bounds.right);
    var t = top.clamp(bounds.top, bounds.bottom);
    var r = right.clamp(bounds.left, bounds.right);
    var b = bottom.clamp(bounds.top, bounds.bottom);
    // A rect clamped to nothing is not a crop; fall back to the bounds.
    if (r - l < 0.02 || b - t < 0.02) {
      l = bounds.left;
      t = bounds.top;
      r = bounds.right;
      b = bounds.bottom;
    }
    return CropRect(l, t, r, b);
  }

  @override
  bool operator ==(Object other) =>
      other is CropRect &&
      other.left == left &&
      other.top == top &&
      other.right == right &&
      other.bottom == bottom;

  @override
  int get hashCode => Object.hash(left, top, right, bottom);

  @override
  String toString() => 'CropRect($left, $top, $right, $bottom)';
}

/// A crop aspect constraint. `null` ratio means the crop is unconstrained.
class AspectOption {
  final String label;

  /// Width divided by height. Null for free, and for "original" the frame's
  /// own ratio is substituted at use.
  final double? ratio;

  /// True for the entry that means "whatever this frame already is".
  final bool useSourceRatio;

  const AspectOption(this.label, this.ratio, {this.useSourceRatio = false});

  static const AspectOption free = AspectOption('Free', null);
  static const AspectOption original =
      AspectOption('Original', null, useSourceRatio: true);

  static const List<AspectOption> all = [
    free,
    original,
    AspectOption('1:1', 1.0),
    AspectOption('3:2', 3 / 2),
    AspectOption('2:3', 2 / 3),
    AspectOption('4:3', 4 / 3),
    AspectOption('3:4', 3 / 4),
    AspectOption('16:9', 16 / 9),
  ];

  /// The ratio to enforce for a frame whose own aspect is `sourceRatio`.
  double? resolve(double sourceRatio) =>
      useSourceRatio ? sourceRatio : ratio;

  @override
  bool operator ==(Object other) =>
      other is AspectOption &&
      other.label == label &&
      other.ratio == ratio &&
      other.useSourceRatio == useSourceRatio;

  @override
  int get hashCode => Object.hash(label, ratio, useSourceRatio);
}

class Geometry {
  /// Quarter turns clockwise, 0–3, applied before the crop.
  final int quarterTurns;

  /// Fine rotation in degrees, positive clockwise. Applied before the quarter
  /// turns, about the centre of the frame.
  final double straightenDegrees;

  /// The crop, in fractions of the rotated frame.
  final CropRect crop;

  /// The constraint the crop rectangle is dragged under. Not applied to
  /// `crop` here — the UI enforces it as the user drags, so that switching
  /// the constraint does not silently rewrite a crop they already placed.
  final AspectOption aspect;

  const Geometry({
    this.quarterTurns = 0,
    this.straightenDegrees = 0,
    this.crop = CropRect.full,
    this.aspect = AspectOption.free,
  });

  static const Geometry identity = Geometry();

  /// True when the geometry does not change a pixel, so the pipeline can skip
  /// a resample and hand the decoded buffer straight through.
  bool get isIdentity =>
      quarterTurns == 0 && straightenDegrees == 0 && crop.isFull;

  /// The same geometry showing the whole frame — what the crop tool displays
  /// while the rectangle is being dragged.
  Geometry get withoutCrop => Geometry(
        quarterTurns: quarterTurns,
        straightenDegrees: straightenDegrees,
        crop: CropRect.full,
        aspect: aspect,
      );

  Geometry copyWith({
    int? quarterTurns,
    double? straightenDegrees,
    CropRect? crop,
    AspectOption? aspect,
  }) =>
      Geometry(
        quarterTurns: quarterTurns ?? this.quarterTurns,
        straightenDegrees: straightenDegrees ?? this.straightenDegrees,
        crop: crop ?? this.crop,
        aspect: aspect ?? this.aspect,
      );

  /// Turn clockwise, keeping the crop where it is on screen by rotating it
  /// with the frame.
  Geometry rotatedClockwise() => copyWith(
        quarterTurns: (quarterTurns + 1) % 4,
        crop: CropRect(1 - crop.bottom, crop.left, 1 - crop.top, crop.right),
      );

  Geometry rotatedAnticlockwise() => copyWith(
        quarterTurns: (quarterTurns + 3) % 4,
        crop: CropRect(crop.top, 1 - crop.right, crop.bottom, 1 - crop.left),
      );

  /// Dimensions of the frame the crop is expressed against, given a source.
  (int, int) rotatedSize(int width, int height) =>
      quarterTurns.isOdd ? (height, width) : (width, height);

  /// Dimensions of the finished result.
  (int, int) outputSize(int width, int height) {
    final (rw, rh) = rotatedSize(width, height);
    final w = (crop.width * rw).round().clamp(1, rw);
    final h = (crop.height * rh).round().clamp(1, rh);
    return (w, h);
  }

  /// The largest centred rectangle that contains no blank corner after
  /// straightening, in fractions of the rotated frame.
  ///
  /// A rotation by anything but a quarter turn leaves wedges of nothing at
  /// the corners. Editors do not show them; they shrink the crop until the
  /// rectangle is entirely inside the rotated image, and so does this. The
  /// crop the user has placed is then fitted inside the result, which is why
  /// dragging the straighten slider pulls an existing crop inward rather than
  /// revealing black.
  CropRect straightenBounds(int width, int height) {
    if (straightenDegrees == 0) return CropRect.full;
    final (rw, rh) = rotatedSize(width, height);
    final (iw, ih) = _largestInsideRotated(
        rw.toDouble(), rh.toDouble(), straightenDegrees * math.pi / 180.0);
    final fw = (iw / rw).clamp(0.05, 1.0);
    final fh = (ih / rh).clamp(0.05, 1.0);
    return CropRect(
      (1 - fw) / 2,
      (1 - fh) / 2,
      1 - (1 - fw) / 2,
      1 - (1 - fh) / 2,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is Geometry &&
      other.quarterTurns == quarterTurns &&
      other.straightenDegrees == straightenDegrees &&
      other.crop == crop &&
      other.aspect == aspect;

  @override
  int get hashCode =>
      Object.hash(quarterTurns, straightenDegrees, crop, aspect);
}

/// Largest axis-aligned rectangle that fits inside a `w` x `h` rectangle
/// rotated by `angle` radians. The standard construction; the degenerate
/// branch covers the case where the inscribed rectangle is pinned by the
/// short side rather than by both.
(double, double) _largestInsideRotated(double w, double h, double angle) {
  if (w <= 0 || h <= 0) return (0, 0);

  final sinA = math.sin(angle).abs();
  final cosA = math.cos(angle).abs();
  final widthIsLonger = w >= h;
  final sideLong = widthIsLonger ? w : h;
  final sideShort = widthIsLonger ? h : w;

  if (sideShort <= 2.0 * sinA * cosA * sideLong || (sinA - cosA).abs() < 1e-10) {
    final x = 0.5 * sideShort;
    return widthIsLonger ? (x / sinA, x / cosA) : (x / cosA, x / sinA);
  }

  final cos2A = cosA * cosA - sinA * sinA;
  return ((w * cosA - h * sinA) / cos2A, (h * cosA - w * sinA) / cos2A);
}
