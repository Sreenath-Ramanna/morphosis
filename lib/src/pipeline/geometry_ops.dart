// lib/src/pipeline/geometry_ops.dart
//
// Applying a Geometry to a scene-referred buffer.
//
// This runs on the linear 16-bit data, before the tone engine — which is the
// only correct place for it. Resampling is an average of neighbouring pixels,
// and an average is only meaningful where the values are proportional to
// light: averaging gamma-encoded values darkens every edge it touches, by an
// amount that depends on the local contrast. The same reasoning that puts
// exposure in the scene-referred domain puts rotation there.
//
// It also means the crop happens before the histogram and before the
// automatic grey point is measured, so both describe what the viewer is
// looking at rather than the frame it was cut from.

import 'dart:math' as math;
import 'dart:typed_data';

import '../model/geometry.dart';
import '../ria/ria.dart';

/// Apply `geometry` to a scene-linear RGB16 image.
///
/// Returns the source unchanged when the geometry is the identity, so the
/// common path costs nothing — not even a copy. Callers must therefore treat
/// the result as read-only, which every caller here does.
SceneImage applyGeometry(SceneImage src, Geometry geometry) {
  if (geometry.isIdentity) return src;

  final (outW, outH) = geometry.outputSize(src.width, src.height);
  final dst = Uint16List(outW * outH * 3);

  final map = _InverseMap(src, geometry, outW, outH);

  if (geometry.straightenDegrees == 0) {
    _resampleExact(src, dst, outW, outH, map);
  } else {
    _resampleBilinear(src, dst, outW, outH, map);
  }
  // Both labels travel with the pixels. A crop that forgot the anchor would
  // give the cropped frame a different EV scale from the uncropped one.
  return SceneImage(
    dst,
    outW,
    outH,
    saturationScale: src.saturationScale,
    colorspace: src.colorspace,
  );
}

/// Destination-to-source mapping, as a 2x3 affine.
///
/// Built by composing the inverse of each stage in reverse order — crop, then
/// the quarter turns, then the straighten rotation about the centre. Doing it
/// as one matrix rather than three passes means one resample instead of
/// three, and three resamples of the same pixels is three times the softening
/// for no additional information.
class _InverseMap {
  final double a, b, c; // sourceX = a*dx + b*dy + c
  final double d, e, f; // sourceY = d*dx + e*dy + f

  factory _InverseMap(
      SceneImage src, Geometry geometry, int outW, int outH) {
    final (rw, rh) = geometry.rotatedSize(src.width, src.height);

    // Destination pixel -> position in the rotated frame, in pixels.
    final sx = geometry.crop.width * rw / outW;
    final sy = geometry.crop.height * rh / outH;
    final ox = geometry.crop.left * rw;
    final oy = geometry.crop.top * rh;

    // Rotated frame -> straightened frame. The quarter turn is clockwise, so
    // the inverse is anticlockwise.
    late double m00, m01, m02, m10, m11, m12;
    switch (geometry.quarterTurns & 3) {
      case 1: // 90 clockwise: (x, y) <- (y, rw - x) in the straightened frame
        m00 = 0;
        m01 = 1;
        m02 = 0;
        m10 = -1;
        m11 = 0;
        m12 = rw.toDouble();
        break;
      case 2:
        m00 = -1;
        m01 = 0;
        m02 = rw.toDouble();
        m10 = 0;
        m11 = -1;
        m12 = rh.toDouble();
        break;
      case 3:
        m00 = 0;
        m01 = -1;
        m02 = rh.toDouble();
        m10 = 1;
        m11 = 0;
        m12 = 0;
        break;
      default:
        m00 = 1;
        m01 = 0;
        m02 = 0;
        m10 = 0;
        m11 = 1;
        m12 = 0;
    }

    // Straightened frame -> source. Rotating the image clockwise by θ means
    // sampling the source at a point rotated anticlockwise by θ about the
    // centre, so the inverse rotation is by −θ.
    final theta = -geometry.straightenDegrees * math.pi / 180.0;
    final cosT = math.cos(theta);
    final sinT = math.sin(theta);
    final cx = src.width / 2.0;
    final cy = src.height / 2.0;

    // Compose: p_src = R(-θ) · (M · (S · p_dst + O) − centre) + centre.
    final u00 = m00 * sx, u01 = m01 * sy, u02 = m00 * ox + m01 * oy + m02;
    final u10 = m10 * sx, u11 = m11 * sy, u12 = m10 * ox + m11 * oy + m12;

    double rx(double x, double y) => cosT * (x - cx) - sinT * (y - cy) + cx;
    double ry(double x, double y) => sinT * (x - cx) + cosT * (y - cy) + cy;

    return _InverseMap._(
      cosT * u00 - sinT * u10,
      cosT * u01 - sinT * u11,
      rx(u02, u12),
      sinT * u00 + cosT * u10,
      sinT * u01 + cosT * u11,
      ry(u02, u12),
    );
  }

  const _InverseMap._(this.a, this.b, this.c, this.d, this.e, this.f);
}

/// Quarter turns and crops only: every destination pixel lands on exactly one
/// source pixel, so this copies rather than resamples and loses nothing.
void _resampleExact(SceneImage src, Uint16List dst, int outW, int outH,
    _InverseMap m) {
  final sw = src.width, sh = src.height;
  final s = src.data;
  var di = 0;
  for (var y = 0; y < outH; y++) {
    final fy = y + 0.5;
    for (var x = 0; x < outW; x++) {
      final fx = x + 0.5;
      var sxi = (m.a * fx + m.b * fy + m.c).floor();
      var syi = (m.d * fx + m.e * fy + m.f).floor();
      if (sxi < 0) sxi = 0;
      if (syi < 0) syi = 0;
      if (sxi >= sw) sxi = sw - 1;
      if (syi >= sh) syi = sh - 1;
      final si = (syi * sw + sxi) * 3;
      dst[di] = s[si];
      dst[di + 1] = s[si + 1];
      dst[di + 2] = s[si + 2];
      di += 3;
    }
  }
}

/// Straightened: bilinear, on linear light.
///
/// Edges clamp to the last real pixel. Any wedge of nothing left by the
/// rotation is excluded by `Geometry.straightenBounds` before this runs, so
/// the clamp only ever affects a sub-pixel sliver at the border.
void _resampleBilinear(SceneImage src, Uint16List dst, int outW, int outH,
    _InverseMap m) {
  final sw = src.width, sh = src.height;
  final s = src.data;
  final maxX = sw - 1, maxY = sh - 1;
  var di = 0;

  for (var y = 0; y < outH; y++) {
    final fy = y + 0.5;
    for (var x = 0; x < outW; x++) {
      final fx = x + 0.5;
      final px = m.a * fx + m.b * fy + m.c - 0.5;
      final py = m.d * fx + m.e * fy + m.f - 0.5;

      var x0 = px.floor();
      var y0 = py.floor();
      final tx = px - x0;
      final ty = py - y0;
      var x1 = x0 + 1;
      var y1 = y0 + 1;

      if (x0 < 0) x0 = 0;
      if (y0 < 0) y0 = 0;
      if (x1 < 0) x1 = 0;
      if (y1 < 0) y1 = 0;
      if (x0 > maxX) x0 = maxX;
      if (y0 > maxY) y0 = maxY;
      if (x1 > maxX) x1 = maxX;
      if (y1 > maxY) y1 = maxY;

      final i00 = (y0 * sw + x0) * 3;
      final i10 = (y0 * sw + x1) * 3;
      final i01 = (y1 * sw + x0) * 3;
      final i11 = (y1 * sw + x1) * 3;

      final w00 = (1 - tx) * (1 - ty);
      final w10 = tx * (1 - ty);
      final w01 = (1 - tx) * ty;
      final w11 = tx * ty;

      for (var ch = 0; ch < 3; ch++) {
        final v = s[i00 + ch] * w00 +
            s[i10 + ch] * w10 +
            s[i01 + ch] * w01 +
            s[i11 + ch] * w11;
        dst[di + ch] = v < 0 ? 0 : (v > 65535 ? 65535 : v.round());
      }
      di += 3;
    }
  }
}
