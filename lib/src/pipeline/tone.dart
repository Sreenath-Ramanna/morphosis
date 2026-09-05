// lib/src/pipeline/tone.dart
//
// The EV tone engine and the display transform — approach.md §6 to §9.
//
// Both are one-dimensional functions, so both are tables, and the render loop
// in render.dart applies them together without materialising anything in
// between. That fusion is a correctness requirement rather than an
// optimisation: a 16-bit buffer between the two would clamp at 1.0, and the
// highlight shoulder exists precisely to compress what sits above it.

import 'dart:math' as math;
import 'dart:typed_data';

import '../model/edit.dart' show CameraLook;

/// Photographic middle grey, and the anchor `ria_display_transform` uses.
const double middleGrey = 0.18;

/// Log-luminance of a pixel too dark to say anything about. Below this the
/// data is sensor noise, and the gain is held constant rather than being
/// extrapolated off the bottom of the curve.
const double evFloor = -14.0;

/// Zone centres, in EV **relative to display white** rather than to sensor
/// saturation.
///
/// approach.md §6 specifies them against saturation, starting from
/// (−8, −4, −1.5, 0). The numbers are right and the anchor is not: a
/// scene-linear decode leaves the 99.5th percentile around −1.8 EV, so
/// anchored to saturation the top zone would sit above anything the display
/// ever shows and a "white level" control would appear dead. Anchored to
/// display white the same numbers land where Lightroom's regions land —
/// roughly 12%, 30%, 75% and 95% of the output range — which is what the
/// labels lead a photographer to expect.
///
/// So the centres travel with the display anchor: `Tone.centres` adds
/// `log2(greyPoint / 0.18)` to each.
const List<double> defaultZoneCentresEv = [-8.0, -4.5, -2.0, -0.3];

/// Width of each zone's basis function.
///
/// approach.md §6 specifies smoothstep ramps between knots, so that exactly
/// two weights are non-zero anywhere. §7 then shows why that cannot stand:
/// smoothstep's derivative peaks at `1.5 / span`, so over a 2.5 EV gap two
/// adjacent controls pulled 2.5 EV apart already drive the tone curve slope
/// negative and solarise the image. Measured on that basis, "shadows +1.5,
/// highlights −1.0" — an ordinary edit — was scaled back to 76% of what the
/// sliders said.
///
/// §7's third remedy is taken instead: basis functions wider than the centre
/// spacing, so three or four weights are non-zero at once. Each zone is a
/// Gaussian normalised against the others, which
///
///   * is a partition of unity by construction, exactly as the smoothstep
///     scheme was, and for the same reason — the analysis and the adjustment
///     cannot disagree about what a shadow is;
///   * is C-infinity rather than C-one, so no setting leaves a crease;
///   * spreads each transition over about twice the centre spacing, dropping
///     the peak derivative by roughly a factor of three and moving the first
///     fold-over out past 4 EV of opposition.
///
/// The cost, which §7 names: the controls are less independent. At its own
/// centre a zone carries about 70% of the weight rather than all of it, so
/// each slider does a little less than its label claims and a little of what
/// its neighbours claim. That is also how every editor with these four
/// controls behaves, and it is why they stay usable at their extremes.
const double zoneSigmaEv = 2.4;

/// Below this the tone curve has folded over and local contrast inverts.
/// approach.md §7 suggests 0.05.
const double minSlopeFloor = 0.05;

/// Everything the renderer needs to know about one frame's tonal state, in
/// the two domains it spans.
class Tone {
  /// Scene-linear value placed at display middle grey. This is the brightness
  /// control (approach.md §8: brightness is a midtone placement with the
  /// endpoints anchored, which is exactly what a grey point is — it is not
  /// exposure, and offering it as a second EV slider would be two controls
  /// doing one job).
  final double greyPoint;

  /// Scene-linear value placed at display white. 1.0 is sensor saturation.
  final double whitePoint;

  /// Roll the top off with extended Reinhard instead of clipping it.
  final bool shoulder;

  final double contrastEv;
  final double blackEv;
  final double shadowEv;
  final double highlightEv;
  final double whiteEv;

  /// The opt-in look, composed into the gain table after everything above.
  final CameraLook cameraLook;

  Tone({
    required this.greyPoint,
    this.whitePoint = 1.0,
    this.shoulder = false,
    this.contrastEv = 0,
    this.blackEv = 0,
    this.shadowEv = 0,
    this.highlightEv = 0,
    this.whiteEv = 0,
    this.cameraLook = CameraLook.none,
  });

  /// How far display white sits below sensor saturation, in EV. Everything
  /// anchored to the rendered image rather than to the sensor uses this.
  double get displayOffsetEv => _log2(greyPoint / middleGrey);

  /// The four zone centres for this frame, in scene EV.
  List<double> get centres =>
      [for (final c in defaultZoneCentresEv) c + displayOffsetEv];

  /// The contrast pivot, in scene-linear luminance.
  ///
  /// approach.md §8 defaults it to 0.18 and notes that a scene whose median
  /// sits at −3.1 EV may want it lower. The grey point *is* that number: it
  /// is the scene value the display renders as middle grey, so pivoting there
  /// means contrast rotates the curve about what the viewer sees as midtone.
  double get pivot => greyPoint;

  double get contrastSlope => math.pow(2.0, contrastEv / 3.0).toDouble();

  List<double> get zoneEv => [blackEv, shadowEv, highlightEv, whiteEv];

  /// The factor that turns scene-linear luminance into display-referred
  /// luminance, where 1.0 is display white.
  ///
  /// One getter, used by both tables: the base curve is defined against display
  /// white and so is [buildDisplayLut]'s shoulder, and if the two ever
  /// disagreed about where white is, the preset would target a different white
  /// from the transform that follows it.
  double get displayScale => middleGrey / greyPoint;

  bool get isIdentityTone =>
      cameraLook.isNone &&
      contrastEv == 0 &&
      blackEv == 0 &&
      shadowEv == 0 &&
      highlightEv == 0 &&
      whiteEv == 0;

  // ── The zone basis ──────────────────────────────────────────────────────

  /// Four smooth weights over EV that sum to exactly 1 everywhere.
  ///
  /// `wₖ(e) = bₖ(e) / Σⱼ bⱼ(e)` with `bₖ(e) = exp(−((e − cₖ)/σ)²)`. The
  /// normalisation is what makes them a partition of unity — the property the
  /// whole scheme rests on, because it is what lets the analysis ("how much of
  /// this frame is shadow") and the adjustment share one definition of a
  /// shadow and be unable to disagree about it.
  ///
  /// Evaluated through the log-sum-exp trick. Ten stops below the lowest
  /// centre every exponential underflows to zero and the ratio becomes 0/0;
  /// subtracting the largest exponent first holds the largest term at exactly
  /// 1 and keeps the answer right out to the ends of the range.
  static void weights(double e, List<double> c, Float64List out) {
    var best = double.negativeInfinity;
    for (var i = 0; i < 4; i++) {
      final d = (e - c[i]) / zoneSigmaEv;
      final l = -d * d;
      out[i] = l;
      if (l > best) best = l;
    }
    var sum = 0.0;
    for (var i = 0; i < 4; i++) {
      final v = math.exp(out[i] - best);
      out[i] = v;
      sum += v;
    }
    final inv = 1.0 / sum;
    for (var i = 0; i < 4; i++) {
      out[i] *= inv;
    }
  }

  /// d/de of the four weights.
  ///
  /// For a normalised exponential family, `wᵢ′ = wᵢ · (gᵢ − Σⱼ wⱼ gⱼ)` where
  /// `gᵢ = d/de log bᵢ = −2(e − cᵢ)/σ²`. Analytic rather than a finite
  /// difference: `minSlope` evaluates it a few hundred times per render, and a
  /// difference would need a step small enough to be noisy.
  static void weightSlopes(double e, List<double> c, Float64List out) {
    final w = Float64List(4);
    weights(e, c, w);
    var mean = 0.0;
    final g = Float64List(4);
    for (var i = 0; i < 4; i++) {
      g[i] = -2 * (e - c[i]) / (zoneSigmaEv * zoneSigmaEv);
      mean += w[i] * g[i];
    }
    for (var i = 0; i < 4; i++) {
      out[i] = w[i] * (g[i] - mean);
    }
  }

  /// The worst slope of the input-EV → output-EV mapping.
  ///
  /// `d e_out / d e_in = slope · (1 + Σ wₖ′(e) · zoneₖ)`. When this goes
  /// negative the curve has folded over: local contrast inverts and the image
  /// solarises, which is reachable well inside the ±3 EV the sliders offer.
  double minSlope([List<double>? zones]) {
    final z = zones ?? zoneEv;
    final k = centres;
    final w = Float64List(4);
    var worst = double.infinity;
    // Sampled well past the outermost centres. A Gaussian basis has no hard
    // support, so the steepest part of a transition can sit outside the span
    // the centres bracket.
    const samples = 400;
    final lo = k[0] - 2 * zoneSigmaEv, hi = k[3] + 2 * zoneSigmaEv;
    for (var i = 0; i <= samples; i++) {
      final e = lo + (hi - lo) * i / samples;
      weightSlopes(e, k, w);
      var s = 1.0;
      for (var j = 0; j < 4; j++) {
        s += w[j] * z[j];
      }
      s *= contrastSlope;
      if (s < worst) worst = s;
    }
    return worst.isFinite ? worst : 1.0;
  }

  /// Scale all four zone deltas by one common factor until the curve is
  /// monotonic again.
  ///
  /// A common factor rather than per-zone clamping: it preserves the *shape*
  /// the user asked for — the relative pull between zones — while making it
  /// realisable. Clamping one zone would change the shape into something they
  /// did not ask for and cannot predict.
  ///
  /// Returns 1.0 when nothing had to be scaled back.
  double softLimitFactor() {
    if (minSlope() >= minSlopeFloor) return 1.0;
    var lo = 0.0, hi = 1.0;
    for (var i = 0; i < 40; i++) {
      final mid = (lo + hi) / 2;
      final scaled = [for (final z in zoneEv) z * mid];
      if (minSlope(scaled) >= minSlopeFloor) {
        lo = mid;
      } else {
        hi = mid;
      }
    }
    return lo;
  }

  // ── The gain table ──────────────────────────────────────────────────────

  /// Number of entries in the luminance → gain table.
  static const int gainEntries = 1 << 14;

  /// Highest luminance the table covers. White balance can push a channel
  /// above sensor saturation, so the table has to reach past 1.0.
  static const double gainYMax = 4.0;

  /// Index a luminance into the gain table.
  ///
  /// Indexed by `sqrt(Y)`, not by Y: the interesting range spans ten stops and
  /// a linear index would spend half its entries in the top stop and leave the
  /// shadows — where the gain varies fastest — with a handful. Under a square
  /// root the resolution in EV is roughly constant, about 0.003 EV per step at
  /// midtone, which is well under one 8-bit code value.
  static int gainIndex(double y) {
    if (!(y > 0)) return 0;
    final i = (math.sqrt(y * (1.0 / gainYMax)) * gainEntries).toInt();
    return i >= gainEntries ? gainEntries - 1 : i;
  }

  /// Build the luminance → gain table.
  ///
  /// Evaluation order, on `e = log2(Y)`:
  ///
  ///     e₁ = e + Σₖ wₖ(e) · zoneₖ          exposure-like terms
  ///     e₂ = p + slope · (e₁ − p)           contrast, last
  ///     gain = 2^(e₂ − e)
  ///
  /// The zone weights are evaluated on the *input* EV `e`, not on `e₁`.
  /// Evaluating them on the shifted value would make the equation implicit and
  /// need per-pixel iteration for no visible benefit. Do not "fix" this.
  ///
  /// The gain is a single factor applied to all three channels. Scaling them
  /// independently would shift hue; a uniform scale moves luminance and leaves
  /// chromaticity exactly where it was, which is what "adjust the exposure of
  /// the shadows" means.
  Float32List buildGainLut() {
    final lut = Float32List(gainEntries);
    final k = centres;
    final f = softLimitFactor();
    final z = [for (final v in zoneEv) v * f];
    final slope = contrastSlope;
    final p = _log2(pivot);
    final w = Float64List(4);
    final scale = displayScale;

    final anyZone = z.any((v) => v != 0);
    final hasLook = !cameraLook.isNone;
    // The fast path has to know about the look. `!anyZone && slope == 1.0` is
    // *exactly* the state of a neutral edit with the preset on, so without this
    // clause the table comes back all ones, the preset does nothing at all, and
    // every test that checks the table's shape still passes. tone_test's L8 is
    // the test that fails if this is ever undone.
    if (!anyZone && slope == 1.0 && !hasLook) {
      for (var i = 0; i < gainEntries; i++) {
        lut[i] = 1.0;
      }
      return lut;
    }

    for (var i = 0; i < gainEntries; i++) {
      // Invert gainIndex: entry i is the midpoint of the luminance range it
      // covers.
      final t = (i + 0.5) / gainEntries;
      final y = t * t * gainYMax;
      var e = _log2(y);
      if (e < evFloor) e = evFloor;

      var e1 = e;
      if (anyZone) {
        weights(e, k, w);
        for (var j = 0; j < 4; j++) {
          e1 += w[j] * z[j];
        }
      }
      final e2 = p + slope * (e1 - p);
      var gain = math.pow(2.0, e2 - e).toDouble();
      if (hasLook) {
        // Last in the chain — zones, then contrast, then the base curve — so
        // the user's own settings compose on top of the preset rather than
        // being reinterpreted by it. That is what "the sliders still act
        // relative to the preset" means in code.
        //
        // In linear rather than in EV: multiplying the gain by base(v)/v is
        // exact and costs no log/exp, and it is the same answer as adding a
        // term to e2.
        final vIn = y * gain * scale;
        if (vIn > 0) gain *= cameraLookCurve(vIn, cameraLook.gain) / vIn;
      }
      // With the look off this is the same `double` the expression above
      // produced on its own, so the neutral table is bit-for-bit what it was.
      lut[i] = gain;
    }
    return lut;
  }

  // ── The display table ───────────────────────────────────────────────────

  /// Scene-linear → display code value, tabulated.
  ///
  /// `outMax` is 255 for the screen and JPEG, 65535 for a 16-bit TIFF; the
  /// table is finer in the second case because the same relative step is
  /// 257 times more visible there.
  ///
  /// Indexed by `sqrt(v)` for the same reason the gain table is.
  DisplayLut buildDisplayLut({required int outMax, required int entries}) {
    final wide = outMax > 255;
    final bytes = wide ? null : Uint8List(entries + 1);
    final words = wide ? Uint16List(entries + 1) : null;

    final scale = displayScale;
    final w = whitePoint * scale;

    for (var i = 0; i <= entries; i++) {
      final t = i / entries;
      final v = t * t * DisplayLut.vMax;
      var y = v * scale;
      if (shoulder) y = _reinhard(y, w);
      y = y < 0 ? 0 : (y > 1 ? 1 : y);
      final code = (srgbEncode(y) * outMax + 0.5).toInt();
      if (wide) {
        words![i] = code;
      } else {
        bytes![i] = code;
      }
    }
    return DisplayLut(wide ? words! : bytes!, entries, outMax);
  }
}

/// A sqrt-indexed scene-linear → display table.
class DisplayLut {
  /// The largest scene-linear value the table represents. Anything above it
  /// is display white several times over, so clamping there costs nothing.
  static const double vMax = 8.0;

  /// Entries for the on-screen preview. At this size the quantisation is
  /// about a tenth of an 8-bit code value at midtone.
  static const int previewEntries = 1 << 14;

  /// Entries for a 16-bit export, where one part in 65535 has to survive.
  static const int exportEntries = 1 << 18;

  final TypedData table;
  final int entries;
  final int outMax;

  const DisplayLut(this.table, this.entries, this.outMax);

  Uint8List get asBytes => table as Uint8List;
  Uint16List get asWords => table as Uint16List;

  /// The multiplier that turns `sqrt(v)` into a table index, precomputed so
  /// the render loop is a multiply rather than a divide.
  double get indexScale => entries / math.sqrt(vMax);
}

/// Extended Reinhard, `y(1 + y/W²)/(1 + y)`, mapping W to exactly 1.
///
/// Monotonic, `f(y) → y` as `y → 0` so shadows pass through untouched, and no
/// magic constants. At W = 1 it is the identity, which is why the shoulder
/// does nothing until something is pushed above display white — brightening
/// via the grey point is what gives it work to do.
double _reinhard(double y, double w) {
  if (w <= 0) return y;
  return y * (1.0 + y / (w * w)) / (1.0 + y);
}

/// The sRGB transfer function.
///
/// `ria_display_transform` defaults to LibRaw's own curve — a power of 2.222
/// with a 4.5 toe, which is Rec.709-shaped — and reproducing it exactly is
/// what makes RIA_DISPLAY_CLIP match a plain decode. This app encodes sRGB
/// instead, deliberately: Flutter composites the canvas as sRGB and every
/// viewer that opens an exported file assumes sRGB, so encoding anything else
/// leaves the preview and the export each slightly wrong in the same
/// direction with nothing to say so. The two curves differ only in the toe.
double srgbEncode(double v) {
  if (v <= 0) return 0;
  if (v >= 1) return 1;
  return v <= 0.0031308 ? 12.92 * v : 1.055 * math.pow(v, 1 / 2.4) - 0.055;
}

/// Its exact inverse: display code value → scene-linear.
///
/// Public for one reason — the generated ICC profile's tone reproduction curve
/// is sampled from it. A TRC maps device value to linear, which is this
/// direction, and sampling the pipeline's own function means the profile
/// cannot drift from the curve the pipeline actually applies.
double srgbDecode(double v) {
  if (v <= 0) return 0;
  if (v >= 1) return 1;
  return v <= 0.04045
      ? v / 12.92
      : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
}

/// LibRaw's output curve — dcraw's `gamma_curve`, a power function with a
/// linear toe whose breakpoint is solved by bisection so that the two segments
/// meet with a continuous slope.
///
/// A port of `gamma_curve_init` / `gamma_curve_encode` in
/// `raw_images_api/src/ria_display.c:32`, bisection count and all, rather than
/// an approximation. That file gives the reason and it is the same one here:
/// the whole provenance of the camera look is "it reproduces a plain LibRaw
/// decode", and a close-but-not-equal curve would show up as a systematic
/// few-code-value drift that looks like a bug in whatever is being compared.
///
/// It is *not* bound over FFI. `ria_apply_display_transform` exists in C but is
/// on no Morphosis code path and is not among the symbols `bindings.dart` looks
/// up; binding it would mean mirroring the curve by hand across a repository
/// boundary for a code path nothing executes. `tone_test.dart`'s L2 is what
/// keeps the port honest instead — it checks the solved constants against
/// Rec.709's published ones.
class DcrawCurve {
  /// dcraw's six coefficients, under their own names.
  ///
  /// `_g0` is the **reciprocal** power — the C does `g[0] = 1.0 / power`, so
  /// 2.222 is held as 0.45 — `_g1` is the toe slope, `_g2` the solved
  /// bisection value, `_g3` the breakpoint in linear and `_g4` the offset that
  /// makes the power segment meet the toe.
  final double _g0, _g1, _g2, _g3, _g4;

  const DcrawCurve._(this._g0, this._g1, this._g2, this._g3, this._g4);

  /// Solve the curve. Takes the power the way LibRaw states it — 2.222, not
  /// 0.45 — and takes the reciprocal internally, exactly as the C does.
  factory DcrawCurve(double power, double slope) {
    final g0 = power > 0.0 ? 1.0 / power : 0.0;
    final g1 = slope;
    var g2 = 0.0, g3 = 0.0, g4 = 0.0;
    final bnd = <double>[0.0, 0.0];
    bnd[g1 >= 1.0 ? 1 : 0] = 1.0;
    if (g1 != 0.0 && (g1 - 1.0) * (g0 - 1.0) <= 0.0) {
      // 48 iterations is dcraw's own count, and takes the breakpoint well past
      // double precision. Iterating to a tolerance instead would converge
      // somewhere else in the last few bits, which is exactly the drift the
      // class comment is about.
      for (var i = 0; i < 48; i++) {
        g2 = (bnd[0] + bnd[1]) / 2.0;
        if (g0 != 0.0) {
          bnd[(math.pow(g2 / g1, -g0) - 1.0) / g0 - 1.0 / g2 > -1.0 ? 1 : 0] =
              g2;
        } else {
          bnd[g2 / math.exp(1.0 - 1.0 / g2) < g1 ? 1 : 0] = g2;
        }
      }
      g3 = g2 / g1;
      if (g0 != 0.0) g4 = g2 * (1.0 / g0 - 1.0);
    }
    return DcrawCurve._(g0, g1, g2, g3, g4);
  }

  /// Linear → encoded.
  double encode(double r) {
    if (r <= 0.0) return 0.0;
    if (r >= 1.0) return 1.0;
    if (r < _g3) return r * _g1;
    if (_g0 != 0.0) return math.pow(r, _g0).toDouble() * (1.0 + _g4) - _g4;
    return math.log(r) * _g2 + 1.0;
  }

  /// The linear value where the toe ends. 0.018050 for (2.222, 4.5).
  double get breakpoint => _g3;

  /// The reciprocal power the power segment is raised to. 0.45 for 2.222.
  double get power => _g0;

  /// The toe slope, as passed in.
  double get toeSlope => _g1;

  /// The offset that makes the power segment meet the toe: the solved
  /// analogue of Rec.709's published 0.099.
  double get offset => _g4;
}

/// The one instance, solved once. LibRaw's default, and the curve
/// `ria_display.c` initialises.
final DcrawCurve dcrawCurve = DcrawCurve(2.222, 4.5);

/// The camera look's base curve, on display-referred linear luminance —
/// `v = 1.0` is display white.
///
/// `base(v) = srgbDecode(dcrawEncode(k * v))`: re-express LibRaw's own output
/// curve as a remap of linear light, so it composes into the gain table and
/// [srgbEncode] is left exactly as it is. That is what keeps the shipped ICC
/// profiles honest — `icc.dart` samples [srgbDecode] directly, and
/// `icc_test.dart`'s I4 asserts the profiles' TRC *is* that curve.
///
/// Bounded above by 1 for every `v >= 1 / k`, which is the design and not an
/// accident: a plain LibRaw decode clips there, and reproducing a clipping
/// decode is what the look is for.
double cameraLookCurve(double v, double gain) =>
    srgbDecode(dcrawCurve.encode(v * gain));

const double _ln2 = 0.6931471805599453;

double _log2(double v) => v > 0 ? math.log(v) / _ln2 : evFloor;
