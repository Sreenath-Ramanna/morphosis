// lib/src/pipeline/working_space.dart
//
// Which primaries the pipeline works in, which it delivers in, and the 3×3s
// that move between them.
//
// The decode used to happen in sRGB, which meant LibRaw clipped every colour
// outside that gamut inside `dcraw_process` — before the app ever saw the
// pixels, and irreversibly. Decoding wide and converting at the display
// boundary moves that clip to the end of the pipeline, where the tone engine
// has already had its say.
//
// Naming follows the convention `_xyzFromSrgb` in colour_temp.dart sets:
// `aFromB` is the matrix that takes a value in B and returns it in A. So
// `workingFromSrgb(space)` is LibRaw's own `out_rgb[space - 1]`, exactly as
// `ria_colorspace_from_srgb` returns it, and `srgbFromWorking(space)` is its
// inverse.

import 'dart:typed_data';

import '../ria/ria.dart';

/// The working space, fixed in code.
///
/// ProPhoto: the only entry in LibRaw's table that actually contains a modern
/// camera's gamut. Not a preference — the catalogue stores an `Edit` against a
/// content digest so an edit follows the photograph, and a preference would
/// make the same `Edit` render differently on another machine.
const int workingSpace = RiaColorspace.prophoto;

/// What the preview is encoded in. Flutter composites the canvas as sRGB.
const int previewSpace = RiaColorspace.srgb;

/// A 16-bit TIFF is delivered in the working space and tagged with it.
const int exportTiffSpace = workingSpace;

/// An 8-bit JPEG is not: 8 bits across ProPhoto's gamut posterises visibly in
/// smooth gradients, so it is converted to sRGB and tagged sRGB.
const int exportJpegSpace = RiaColorspace.srgb;

/// LibRaw's blend. `highlight_mode` 1 unclips, 2 blends, 3+ rebuilds; all
/// three carry the same normalisation scale and differ only in what they
/// reconstruct above it. 2 is the mode approach.md §0 measured.
const int highlightRecoveryMode = 2;

/// Rec.709 luma coefficients — the luminance row of sRGB primaries, and
/// therefore `lumaRowFor(RiaColorspace.srgb)` exactly.
const List<double> rec709Luma = [0.2126, 0.7152, 0.0722];

/// Where the colourspace matrices come from.
///
/// `Ria.colorspaceFromSrgb` in production, so there is one copy of LibRaw's
/// table and it lives in the repository that builds against LibRaw. A test
/// substitutes the same constants read out of LibRaw directly, because
/// `flutter test` runs with no built `.so` — and `pipeline_check.dart`'s P7
/// is what checks the two against each other.
List<double> Function(int space) colorspaceMatrixSource =
    Ria.colorspaceFromSrgb;

final Map<int, List<List<double>>> _fromSrgb = {};
final Map<int, List<List<double>>> _toSrgb = {};
final Map<int, List<double>> _lumaRows = {};

/// Drop the per-isolate cache. Only tests need this — after changing
/// [colorspaceMatrixSource].
void resetWorkingSpaceCache() {
  _fromSrgb.clear();
  _toSrgb.clear();
  _lumaRows.clear();
}

/// linear sRGB → `space`. LibRaw's `out_rgb[space - 1]`, which is the table
/// the decode applied.
List<List<double>> workingFromSrgb(int space) => _fromSrgb.putIfAbsent(space, () {
      if (space == RiaColorspace.srgb) return _identity3();
      final m = colorspaceMatrixSource(space);
      return [
        [m[0], m[1], m[2]],
        [m[3], m[4], m[5]],
        [m[6], m[7], m[8]],
      ];
    });

/// `space` → linear sRGB. The inverse of [workingFromSrgb], and exact rather
/// than fitted: it is the same table, inverted.
List<List<double>> srgbFromWorking(int space) => _toSrgb.putIfAbsent(
    space,
    () => space == RiaColorspace.srgb
        ? _identity3()
        : invert3(workingFromSrgb(space)));

/// The luminance row to weight `outputSpace` values with: `rec709 ·
/// srgbFromWorking(outputSpace)`.
///
/// Not the space's own Y row out of XYZ(D50). Both are "a luminance", but the
/// preview ships sRGB and the TIFF ships ProPhoto, and the tone engine has to
/// give the two the same answer for "how bright is this pixel". This row is
/// the *same* linear functional of the source that Rec.709 is of the sRGB
/// render, by construction, so preview and export cannot disagree; the D50 row
/// measures against a different white and puts the TIFF's tone response 1–2 %
/// off the preview's on saturated blues.
///
/// For sRGB it is exactly [rec709Luma]; for ProPhoto it is
/// (0.268206, 0.715217, 0.016577).
List<double> lumaRowFor(int outputSpace) => _lumaRows.putIfAbsent(
    outputSpace,
    () => outputSpace == RiaColorspace.srgb
        ? rec709Luma
        : rowTimes3(rec709Luma, srgbFromWorking(outputSpace)));

/// The one matrix the render loop applies: gamut conversion, white balance and
/// the saturation anchor, collapsed into nine multiplies.
///
/// `outputFromWorking · wbMatrix · (1 / saturationScale)`, row-major.
///
/// Folding `1 / saturationScale` in is the whole trick. It puts the render
/// into anchor units for free, so `Tone`, `greyPoint`, `buildGainLut` and
/// `buildDisplayLut` need no change at all, and the highlights a
/// reconstruction recovered — which live above 1.0 in anchor units — stay in
/// float registers right up to the shoulder, exactly where approach.md §3
/// requires them.
///
/// Null only when all three factors are the identity, so the existing
/// no-matrix fast path in both render loops survives where it can. With a wide
/// working space and an sRGB output it never is.
///
/// `inputSpace` is what `src` is expressed in. It defaults to [workingSpace];
/// a test overrides it to check the sRGB case against what the code did
/// before.
Float64List? composedMatrix({
  required int outputSpace,
  required List<List<double>>? wbMatrix,
  required double saturationScale,
  int inputSpace = workingSpace,
}) {
  final gamut = outputSpace != inputSpace;
  final scaled = saturationScale != 1.0;
  if (!gamut && wbMatrix == null && !scaled) return null;

  var m = wbMatrix ?? _identity3();
  if (gamut) {
    m = mul3(mul3(workingFromSrgb(outputSpace), srgbFromWorking(inputSpace)), m);
  }
  final k = scaled ? 1.0 / saturationScale : 1.0;

  return Float64List.fromList([
    m[0][0] * k, m[0][1] * k, m[0][2] * k,
    m[1][0] * k, m[1][1] * k, m[1][2] * k,
    m[2][0] * k, m[2][1] * k, m[2][2] * k,
  ]);
}

// ── 3×3 helpers ───────────────────────────────────────────────────────────
//
// colour_temp.dart carries its own private copies. They are not shared,
// deliberately: that file is the reference implementation the existing
// colour_temp_test suite pins, and reaching into it from here would put a
// second caller on code that is checked as a whole.

List<List<double>> _identity3() => [
      [1.0, 0.0, 0.0],
      [0.0, 1.0, 0.0],
      [0.0, 0.0, 1.0],
    ];

List<List<double>> mul3(List<List<double>> a, List<List<double>> b) => [
      for (var i = 0; i < 3; i++)
        [
          for (var j = 0; j < 3; j++)
            a[i][0] * b[0][j] + a[i][1] * b[1][j] + a[i][2] * b[2][j],
        ],
    ];

/// A row vector times a matrix — `v · m`, which is how a luminance row
/// composes with a colour transform.
List<double> rowTimes3(List<double> v, List<List<double>> m) => [
      for (var j = 0; j < 3; j++)
        v[0] * m[0][j] + v[1] * m[1][j] + v[2] * m[2][j],
    ];

List<double> apply3(List<List<double>> m, List<double> v) => [
      for (var i = 0; i < 3; i++)
        m[i][0] * v[0] + m[i][1] * v[1] + m[i][2] * v[2],
    ];

List<List<double>> invert3(List<List<double>> m) {
  final a = m[0][0], b = m[0][1], c = m[0][2];
  final d = m[1][0], e = m[1][1], f = m[1][2];
  final g = m[2][0], h = m[2][1], i = m[2][2];

  final det = a * (e * i - f * h) - b * (d * i - f * g) + c * (d * h - e * g);
  if (det.abs() < 1e-12) {
    throw StateError('a colourspace matrix is singular');
  }
  final inv = 1.0 / det;
  return [
    [(e * i - f * h) * inv, (c * h - b * i) * inv, (b * f - c * e) * inv],
    [(f * g - d * i) * inv, (a * i - c * g) * inv, (c * d - a * f) * inv],
    [(d * h - e * g) * inv, (b * g - a * h) * inv, (a * e - b * d) * inv],
  ];
}
