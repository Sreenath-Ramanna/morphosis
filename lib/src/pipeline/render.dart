// lib/src/pipeline/render.dart
//
// The fused render: scene-referred 16-bit linear in, display-referred pixels
// out, in one pass.
//
// The stages are not materialised separately, and that is a correctness
// requirement rather than a speed trick (approach.md §3). A pixel the tone
// engine pushes to 4.0 is held in a local, rolled off by the shoulder, and
// lands inside [0,1] before anything is stored. Written to a 16-bit buffer in
// between it would clamp at 1.0 first, and the shoulder would then have
// nothing left to compress — producing a plausible-looking image with flat
// highlights and no error anywhere.

import 'dart:math' as math;
import 'dart:typed_data';

import '../model/edit.dart';
import 'tone.dart';

/// Rec.709 luma coefficients, applied to *linear* RGB — which is the only
/// place they mean luminance. Saturation is the one deliberate exception: it
/// applies them to the encoded display values, because that is the domain the
/// operation is defined in, and there they weight a grey axis rather than
/// measure light.
const double _lumaR = 0.2126;
const double _lumaG = 0.7152;
const double _lumaB = 0.0722;

const double _inv16 = 1.0 / 65535.0;

/// A luminance distribution of the scene-referred frame, binned in EV.
///
/// This is the analysis half of approach.md §6: 0.25 EV bins over −14…+2 EV
/// relative to sensor saturation. It is computed on linear data and would be
/// meaningless on anything else — the same frame reads a median of −3.1 EV
/// linear and −0.7 EV gamma-encoded.
class ZoneHistogram {
  static const int bins = 64;
  static const double evMin = -14.0;
  static const double evMax = 2.0;

  final Uint32List counts;
  final int pixels;

  const ZoneHistogram(this.counts, this.pixels);

  static ZoneHistogram compute(Uint16List src, int width, int height) {
    final counts = Uint32List(bins);
    final n = width * height;
    // Every pixel is unnecessary for a percentile; a stride keeps the load
    // path snappy on a 60 MP frame without moving the answer.
    final step = n > 4000000 ? 4 : 1;
    var counted = 0;
    const span = evMax - evMin;
    for (var p = 0; p < n; p += step) {
      final i = p * 3;
      final y = (src[i] * _lumaR + src[i + 1] * _lumaG + src[i + 2] * _lumaB) *
          _inv16;
      if (!(y > 0)) {
        counts[0]++;
        counted++;
        continue;
      }
      final e = math.log(y) / math.ln2;
      var b = ((e - evMin) / span * bins).floor();
      if (b < 0) b = 0;
      if (b >= bins) b = bins - 1;
      counts[b]++;
      counted++;
    }
    return ZoneHistogram(counts, counted);
  }

  /// Luminance below which `fraction` of the frame sits, in linear units.
  double percentile(double fraction) {
    if (pixels == 0) return middleGrey;
    final target = pixels * fraction;
    var acc = 0;
    for (var b = 0; b < bins; b++) {
      acc += counts[b];
      if (acc >= target) {
        // Interpolate inside the bin so the answer moves smoothly between
        // frames instead of stepping by a quarter stop.
        final before = acc - counts[b];
        final t = counts[b] == 0 ? 0.0 : (target - before) / counts[b];
        final ev = evMin + (evMax - evMin) * (b + t) / bins;
        return math.pow(2.0, ev).toDouble();
      }
    }
    return 1.0;
  }

  double get medianEv => math.log(percentile(0.5)) / math.ln2;

  /// A starting grey point: the value that places the top of the frame at
  /// display white.
  ///
  /// This is the job LibRaw's `no_auto_bright = 0` normally does, and the
  /// scene-linear preset switches it off precisely so it can be done here,
  /// visibly and in one place, instead of as a scene-dependent gain of
  /// unknown size folded into the decode. The 99.5th percentile rather than
  /// the maximum, so a specular highlight or a hot pixel does not decide the
  /// exposure of the whole frame.
  ///
  /// `greyPoint = 0.18 × p` maps `p` to display white, because the transform
  /// scales by `0.18 / greyPoint`.
  double autoGreyPoint() {
    final p = percentile(0.995);
    final g = middleGrey * p;
    return g.clamp(0.0008, 0.5);
  }
}

/// The largest saturation factor at or below `f` that keeps all three
/// channels inside `[0, outMax]`, given the pixel's luma `y` and the three
/// distances from it.
///
/// Reducing one factor for the whole pixel is what keeps hue where it is: the
/// three distances stay in proportion, so the colour moves along its own ray
/// out of grey and stops when it reaches the edge. Clamping each channel
/// separately instead — which is what `saturate()` in
/// `raw_images_api/src/ria_adjust.c` does — changes those proportions, and a
/// blue sky boosted past the edge comes back purple.
///
/// Shared by both loops rather than written out twice, because the preview and
/// the export disagreeing about the gamut edge is exactly the failure that
/// would show up only on an exported file.
double _gamutLimit(
    double f, double y, double dr, double dg, double db, double outMax) {
  var limited = f;
  // A channel above the luma rises toward outMax and one below falls toward
  // zero; a channel *on* the luma does not move at all and constrains nothing.
  // Its bound would be 0/0 — NaN, which then propagates through every
  // comparison and destroys the pixel — so it is skipped rather than computed.
  if (dr > 0) {
    final bound = (outMax - y) / dr;
    if (bound < limited) limited = bound;
  } else if (dr < 0) {
    final bound = y / -dr;
    if (bound < limited) limited = bound;
  }
  if (dg > 0) {
    final bound = (outMax - y) / dg;
    if (bound < limited) limited = bound;
  } else if (dg < 0) {
    final bound = y / -dg;
    if (bound < limited) limited = bound;
  }
  if (db > 0) {
    final bound = (outMax - y) / db;
    if (bound < limited) limited = bound;
  } else if (db < 0) {
    final bound = y / -db;
    if (bound < limited) limited = bound;
  }
  // Every bound is mathematically at least 1, because the channel it describes
  // is already in range. The floor absorbs the rounding error in that exactly,
  // which is what makes "a boost never narrows the spread" true rather than
  // true to within 1e-15. It cannot push anything out of range: at 1 the
  // result is the channel it started from.
  return limited < 1 ? 1 : limited;
}

/// The fused pass, writing RGB8 for the screen.
///
/// Three bytes rather than four: the unsharp mask and the histogram both run
/// over whatever channels the buffer has, and an alpha channel that is 255
/// everywhere is a quarter of their work spent on nothing. `expandToRgba`
/// widens the result at the end, which is one cheap pass and replaces the
/// copy out of native memory that had to happen anyway.
///
/// `matrix` is the 3×3 white-balance correction in row-major order, or null
/// when the temperature is unchanged — nine multiplies per pixel is worth
/// skipping on the common path.
void renderRgb8(
  Uint16List src,
  int width,
  int height,
  Float64List? matrix,
  Float32List gainLut,
  DisplayLut disp,
  Uint8List dst, {
  double saturation = 0,
}) {
  final table = disp.asBytes;
  final idxScale = disp.indexScale;
  final maxIdx = disp.entries;
  final outMax = disp.outMax.toDouble();
  final outMaxInt = disp.outMax;

  final m0 = matrix?[0] ?? 1, m1 = matrix?[1] ?? 0, m2 = matrix?[2] ?? 0;
  final m3 = matrix?[3] ?? 0, m4 = matrix?[4] ?? 1, m5 = matrix?[5] ?? 0;
  final m6 = matrix?[6] ?? 0, m7 = matrix?[7] ?? 0, m8 = matrix?[8] ?? 1;
  final hasMatrix = matrix != null;

  // Hoisted for correctness, not for speed: `y + (c − y) × 1.0` is not
  // bit-exactly `c`, so at zero the arithmetic has to be skipped rather than
  // passed through, or the neutral render moves by a code value.
  final hasSaturation = saturation != 0;
  final factor = 1 + saturation / saturationRange;

  final n = width * height;
  var s = 0;
  var d = 0;
  for (var p = 0; p < n; p++) {
    var r = src[s] * _inv16;
    var g = src[s + 1] * _inv16;
    var b = src[s + 2] * _inv16;
    s += 3;

    if (hasMatrix) {
      final nr = m0 * r + m1 * g + m2 * b;
      final ng = m3 * r + m4 * g + m5 * b;
      final nb = m6 * r + m7 * g + m8 * b;
      // A chromatic adaptation can send a saturated channel slightly
      // negative; the display has nowhere to put that.
      r = nr < 0 ? 0 : nr;
      g = ng < 0 ? 0 : ng;
      b = nb < 0 ? 0 : nb;
    }

    final y = r * _lumaR + g * _lumaG + b * _lumaB;
    final gain = gainLut[Tone.gainIndex(y)];
    r *= gain;
    g *= gain;
    b *= gain;

    if (hasSaturation) {
      var i = (math.sqrt(r) * idxScale).toInt();
      final rv = table[i > maxIdx ? maxIdx : i].toDouble();
      i = (math.sqrt(g) * idxScale).toInt();
      final gv = table[i > maxIdx ? maxIdx : i].toDouble();
      i = (math.sqrt(b) * idxScale).toInt();
      final bv = table[i > maxIdx ? maxIdx : i].toDouble();

      final y = rv * _lumaR + gv * _lumaG + bv * _lumaB;
      final dr = rv - y, dg = gv - y, db = bv - y;
      // Below 1 every channel moves toward the luma, which is itself a convex
      // combination of the three, so nothing can leave the range and no limit
      // is needed.
      // The limiter is consulted only when the boost would actually reach an
      // edge. The two extreme distances cost four comparisons to find; the
      // bounds themselves cost three divisions, and on most pixels every one
      // of them comes back looser than the factor anyway.
      var f = factor;
      if (factor > 1) {
        var hi = dr > dg ? dr : dg;
        if (db > hi) hi = db;
        var lo = dr < dg ? dr : dg;
        if (db < lo) lo = db;
        if (y + hi * factor > outMax || y + lo * factor < 0) {
          f = _gamutLimit(factor, y, dr, dg, db, outMax);
        }
      }

      var o = (y + dr * f + 0.5).toInt();
      dst[d] = o < 0 ? 0 : (o > outMaxInt ? outMaxInt : o);
      o = (y + dg * f + 0.5).toInt();
      dst[d + 1] = o < 0 ? 0 : (o > outMaxInt ? outMaxInt : o);
      o = (y + db * f + 0.5).toInt();
      dst[d + 2] = o < 0 ? 0 : (o > outMaxInt ? outMaxInt : o);
    } else {
      var i = (math.sqrt(r) * idxScale).toInt();
      dst[d] = table[i > maxIdx ? maxIdx : i];
      i = (math.sqrt(g) * idxScale).toInt();
      dst[d + 1] = table[i > maxIdx ? maxIdx : i];
      i = (math.sqrt(b) * idxScale).toInt();
      dst[d + 2] = table[i > maxIdx ? maxIdx : i];
    }
    d += 3;
  }
}

/// Widen packed RGB8 to the RGBA8 that `ui.decodeImageFromPixels` wants.
///
/// Also the copy out of native memory: the source buffer is reused by the
/// next render, so the UI isolate must never be handed a view onto it.
Uint8List expandToRgba(Uint8List rgb, int pixels) {
  final out = Uint8List(pixels * 4);
  var s = 0, d = 0;
  for (var i = 0; i < pixels; i++) {
    out[d] = rgb[s];
    out[d + 1] = rgb[s + 1];
    out[d + 2] = rgb[s + 2];
    out[d + 3] = 255;
    s += 3;
    d += 4;
  }
  return out;
}

/// The same pass, writing 16-bit RGB for a TIFF export.
///
/// Worth having as its own loop rather than a parameterised one: the display
/// table is a different width, and the branch would sit in the innermost part
/// of a hundred-million-iteration loop.
void renderRgb16(
  Uint16List src,
  int width,
  int height,
  Float64List? matrix,
  Float32List gainLut,
  DisplayLut disp,
  Uint16List dst, {
  double saturation = 0,
}) {
  final table = disp.asWords;
  final idxScale = disp.indexScale;
  final maxIdx = disp.entries;
  final outMax = disp.outMax.toDouble();
  final outMaxInt = disp.outMax;

  final m0 = matrix?[0] ?? 1, m1 = matrix?[1] ?? 0, m2 = matrix?[2] ?? 0;
  final m3 = matrix?[3] ?? 0, m4 = matrix?[4] ?? 1, m5 = matrix?[5] ?? 0;
  final m6 = matrix?[6] ?? 0, m7 = matrix?[7] ?? 0, m8 = matrix?[8] ?? 1;
  final hasMatrix = matrix != null;

  final hasSaturation = saturation != 0;
  final factor = 1 + saturation / saturationRange;

  final n = width * height;
  var s = 0;
  for (var p = 0; p < n; p++) {
    var r = src[s] * _inv16;
    var g = src[s + 1] * _inv16;
    var b = src[s + 2] * _inv16;

    if (hasMatrix) {
      final nr = m0 * r + m1 * g + m2 * b;
      final ng = m3 * r + m4 * g + m5 * b;
      final nb = m6 * r + m7 * g + m8 * b;
      r = nr < 0 ? 0 : nr;
      g = ng < 0 ? 0 : ng;
      b = nb < 0 ? 0 : nb;
    }

    final y = r * _lumaR + g * _lumaG + b * _lumaB;
    final gain = gainLut[Tone.gainIndex(y)];
    r *= gain;
    g *= gain;
    b *= gain;

    if (hasSaturation) {
      var i = (math.sqrt(r) * idxScale).toInt();
      final rv = table[i > maxIdx ? maxIdx : i].toDouble();
      i = (math.sqrt(g) * idxScale).toInt();
      final gv = table[i > maxIdx ? maxIdx : i].toDouble();
      i = (math.sqrt(b) * idxScale).toInt();
      final bv = table[i > maxIdx ? maxIdx : i].toDouble();

      final y = rv * _lumaR + gv * _lumaG + bv * _lumaB;
      final dr = rv - y, dg = gv - y, db = bv - y;
      // The limiter is consulted only when the boost would actually reach an
      // edge. The two extreme distances cost four comparisons to find; the
      // bounds themselves cost three divisions, and on most pixels every one
      // of them comes back looser than the factor anyway.
      var f = factor;
      if (factor > 1) {
        var hi = dr > dg ? dr : dg;
        if (db > hi) hi = db;
        var lo = dr < dg ? dr : dg;
        if (db < lo) lo = db;
        if (y + hi * factor > outMax || y + lo * factor < 0) {
          f = _gamutLimit(factor, y, dr, dg, db, outMax);
        }
      }

      var o = (y + dr * f + 0.5).toInt();
      dst[s] = o < 0 ? 0 : (o > outMaxInt ? outMaxInt : o);
      o = (y + dg * f + 0.5).toInt();
      dst[s + 1] = o < 0 ? 0 : (o > outMaxInt ? outMaxInt : o);
      o = (y + db * f + 0.5).toInt();
      dst[s + 2] = o < 0 ? 0 : (o > outMaxInt ? outMaxInt : o);
    } else {
      var i = (math.sqrt(r) * idxScale).toInt();
      dst[s] = table[i > maxIdx ? maxIdx : i];
      i = (math.sqrt(g) * idxScale).toInt();
      dst[s + 1] = table[i > maxIdx ? maxIdx : i];
      i = (math.sqrt(b) * idxScale).toInt();
      dst[s + 2] = table[i > maxIdx ? maxIdx : i];
    }
    s += 3;
  }
}
