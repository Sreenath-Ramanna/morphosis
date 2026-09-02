// lib/src/pipeline/colour_temp.dart
//
// Colour temperature: reading the one the camera recorded, and re-balancing to
// a different one. Implements approach.md §4 and §5.
//
// LibRaw hands back the raw materials and stops there, deliberately — a
// Kelvin number is a matter of judgement, and which judgement depends on the
// camera. Two routes, and which one is used is reported rather than hidden:
//
//   camera table — the body's own Kelvin → multiplier curve, when it wrote
//     one. Canon does (15 rows, 2400–10900 K on the EOS R7); Nikon does not.
//     Reparameterised in *mired* before interpolating, because the tables are
//     near-uniform in mired and wildly non-uniform in Kelvin: interpolating in
//     Kelvin biases every result warm.
//
//   colorimetric — always available. Camera neutral (1/mul) → cam_xyz⁻¹ → XYZ
//     → xy → the nearest point on the Planckian locus.
//
// Checked against the EOS R7's own table: the colorimetric route puts the
// as-shot CCT at 5591 K where the camera's table says 5786 K, and reproduces
// the table's red multipliers to within 2.5% across 2400–10900 K.

import 'dart:math' as math;

import '../ria/ria.dart';

/// A white point, as the app reports it.
class ColourTemperature {
  /// Correlated colour temperature, Kelvin.
  final double kelvin;

  /// Distance from the Planckian locus in CIE 1960 UCS. Positive is green,
  /// negative magenta. This is the tint, and it is reported rather than
  /// averaged away: a single Kelvin number cannot describe a white point that
  /// sits off the locus, and on the R7 test frame it sits 0.009 below it.
  final double duv;

  /// True when the camera wrote its own Kelvin → multiplier table and that is
  /// what produced this figure.
  final bool fromCameraTable;

  /// False when the illuminant is far enough off the locus that a Kelvin
  /// figure does not describe it. Some Sony and Olympus bodies are always in
  /// this state; the UI says so instead of showing confident nonsense.
  final bool reliable;

  const ColourTemperature({
    required this.kelvin,
    required this.duv,
    required this.fromCameraTable,
    required this.reliable,
  });

  String get sourceLabel => fromCameraTable ? 'camera table' : 'colorimetric';

  String get tintLabel {
    if (duv.abs() < 0.002) return 'neutral';
    return duv > 0
        ? 'green ${(duv * 1000).toStringAsFixed(0)}'
        : 'magenta ${(-duv * 1000).toStringAsFixed(0)}';
  }
}

/// The colour maths for one open frame: what it was shot at, and the matrix
/// that moves it somewhere else.
class WhiteBalance {
  /// XYZ(D65) → camera.
  final List<List<double>> camXyz;

  /// camera → sRGB linear, built the way dcraw builds `rgb_cam`.
  final List<List<double>> rgbCam;

  /// sRGB linear → camera, the inverse of the above.
  final List<List<double>> camRgb;

  /// The camera's own table, `[kelvin, r, 1, b]` rows sorted by mired
  /// ascending (so, by Kelvin descending). Empty when the body wrote none.
  final List<List<double>> table;

  /// As-shot multipliers, green-normalised.
  final List<double> camMul;

  /// What the frame was shot at.
  final ColourTemperature asShot;

  WhiteBalance._({
    required this.camXyz,
    required this.rgbCam,
    required this.camRgb,
    required this.table,
    required this.camMul,
    required this.asShot,
  });

  factory WhiteBalance.from(RawColorData cd) {
    final camXyz = cd.camXyz;
    final rgbCam = _rgbCamFrom(camXyz);
    final camRgb = _invert3(rgbCam);

    final table = [...cd.wbct]..sort((a, b) => a[0].compareTo(b[0]));
    // Sorted ascending in Kelvin; the mired search below wants ascending
    // mired, which is the reverse.
    final byMired = table.reversed.toList();

    final asShot = _cctFor(cd.camMul, camXyz, byMired);

    return WhiteBalance._(
      camXyz: camXyz,
      rgbCam: rgbCam,
      camRgb: camRgb,
      table: byMired,
      camMul: cd.camMul,
      asShot: asShot,
    );
  }

  bool get hasCameraTable => table.isNotEmpty;

  /// The Kelvin range the slider should offer. Widened past the camera's own
  /// table only where the colorimetric route is what is answering anyway.
  double get minKelvin => hasCameraTable
      ? math.min(2000.0, table.last[0])
      : 2000.0;
  double get maxKelvin => hasCameraTable
      ? math.max(12000.0, table.first[0])
      : 12000.0;

  /// Camera-channel multipliers for a target temperature, green-normalised.
  ///
  /// Same route as `asShot` used, so `multipliersFor(asShot.kelvin)` and the
  /// as-shot multipliers agree by construction — which is what makes the
  /// slider an exact no-op at its initial position.
  List<double> multipliersFor(double kelvin) =>
      hasCameraTable ? _tableMul(table, kelvin) : _colorimetricMul(camXyz, kelvin);

  /// The 3×3 that re-balances an already-decoded scene-linear frame from the
  /// as-shot temperature to `kelvin` — approach.md §5, Mode B.
  ///
  /// The decode produced `P = rgb_cam · diag(m₀) · raw`. Balancing to a
  /// different temperature means `P' = rgb_cam · diag(m) · raw`, and
  /// substituting gives
  ///
  ///     P' = rgb_cam · diag(m/m₀) · rgb_cam⁻¹ · P
  ///
  /// which is exact, not an approximation: any global scale LibRaw folded
  /// into its own normalisation cancels in the ratio, and the per-channel
  /// scale happens in camera space where a white balance is defined. What it
  /// cannot do is recover highlights that clipped in camera space during the
  /// decode — for that the file has to be decoded again. Over the few hundred
  /// Kelvin a slider is normally dragged, that is invisible.
  ///
  /// Tint is untouched. The correction is a ratio between two points *on* the
  /// locus, so whatever perpendicular offset the shot had survives it.
  List<List<double>> matrixFor(double kelvin) {
    final target = multipliersFor(kelvin);
    final source = multipliersFor(asShot.kelvin);

    final ratio = [
      target[0] / source[0],
      target[1] / source[1],
      target[2] / source[2],
    ];
    // Green-normalise so the operation changes colour, not brightness; the
    // tone engine owns brightness.
    for (var i = 0; i < 3; i++) {
      ratio[i] /= ratio[1];
    }

    return _mul3(rgbCam, _mul3(_diag(ratio), camRgb));
  }

  /// True when `kelvin` is close enough to as-shot that the matrix is the
  /// identity to within rounding, so the renderer can skip nine multiplies per
  /// pixel.
  bool isNeutral(double kelvin) => (kelvin - asShot.kelvin).abs() < 1.0;
}

// ── Camera-table route ────────────────────────────────────────────────────

/// Interpolate the camera's table at `kelvin`. `table` is sorted by ascending
/// mired.
///
/// Mired rather than Kelvin: the R7's rows step 2400, 2800, 3000 … 10000,
/// 10900, which is 60 mired per step at the warm end and 8 at the cool end.
/// Linear interpolation in Kelvin across that spacing lands warm every time.
List<double> _tableMul(List<List<double>> table, double kelvin) {
  final m = 1e6 / kelvin;
  final first = 1e6 / table.first[0];
  final last = 1e6 / table.last[0];

  if (m <= first) return [table.first[1], 1.0, table.first[3]];
  if (m >= last) return [table.last[1], 1.0, table.last[3]];

  for (var i = 0; i < table.length - 1; i++) {
    final m0 = 1e6 / table[i][0];
    final m1 = 1e6 / table[i + 1][0];
    if (m >= m0 && m <= m1) {
      final t = (m1 - m0) == 0 ? 0.0 : (m - m0) / (m1 - m0);
      return [
        table[i][1] + (table[i + 1][1] - table[i][1]) * t,
        1.0,
        table[i][3] + (table[i + 1][3] - table[i][3]) * t,
      ];
    }
  }
  return [table.last[1], 1.0, table.last[3]];
}

/// The inverse: which temperature does the table assign to these multipliers?
///
/// Searched in log space over both ratios rather than solving on one of them.
/// The R7's as-shot red ratio implies above 6000 K while its blue ratio
/// implies below 5600 K — they disagree because the white point is off the
/// locus, and picking either one alone would silently discard the tint.
double _tableCct(List<List<double>> table, List<double> mul) {
  final mFirst = 1e6 / table.first[0];
  final mLast = 1e6 / table.last[0];

  var best = mFirst;
  var bestErr = double.infinity;
  const steps = 2000;
  for (var i = 0; i <= steps; i++) {
    final m = mFirst + (mLast - mFirst) * i / steps;
    final t = _tableMul(table, 1e6 / m);
    final e = _sq(math.log(t[0] / mul[0])) + _sq(math.log(t[2] / mul[2]));
    if (e < bestErr) {
      bestErr = e;
      best = m;
    }
  }
  return 1e6 / best;
}

// ── Colorimetric route ────────────────────────────────────────────────────

/// Camera multipliers that neutralise a Planckian illuminant at `kelvin`.
List<double> _colorimetricMul(List<List<double>> camXyz, double kelvin) {
  final xy = _planckianXy(kelvin);
  final xyz = [xy[0] / xy[1], 1.0, (1 - xy[0] - xy[1]) / xy[1]];
  final cam = _apply3(camXyz, xyz);
  final mul = [
    for (final c in cam) c.abs() < 1e-9 ? 1e9 : 1.0 / c,
  ];
  return [mul[0] / mul[1], 1.0, mul[2] / mul[1]];
}

ColourTemperature _cctFor(List<double> camMul, List<List<double>> camXyz,
    List<List<double>> table) {
  // Duv always comes from the colorimetric route: the camera's table is a
  // one-dimensional curve and has no way to express a distance from it.
  final neutral = [1.0 / camMul[0], 1.0 / camMul[1], 1.0 / camMul[2]];
  final xyz = _apply3(_invert3(camXyz), neutral);
  final sum = xyz[0] + xyz[1] + xyz[2];
  if (sum.abs() < 1e-12 || !sum.isFinite) {
    return const ColourTemperature(
        kelvin: 5500, duv: 0, fromCameraTable: false, reliable: false);
  }
  final x = xyz[0] / sum, y = xyz[1] / sum;
  final (colorimetricK, duv) = _cctDuvFromXy(x, y);

  final kelvin = table.isNotEmpty ? _tableCct(table, camMul) : colorimetricK;

  // Beyond about 0.05 the point is too far off the locus for a correlated
  // colour temperature to describe it — the CIE's own limit for quoting one.
  final reliable = duv.abs() < 0.05 &&
      kelvin.isFinite &&
      kelvin > 1000 &&
      kelvin < 40000;

  return ColourTemperature(
    kelvin: reliable ? kelvin : 5500,
    duv: duv,
    fromCameraTable: table.isNotEmpty,
    reliable: reliable,
  );
}

/// The Planckian locus in CIE xy, Kim et al.'s cubics. Valid 1667–25000 K,
/// which is wider than any slider this app offers.
List<double> _planckianXy(double t) {
  final k = t.clamp(1667.0, 25000.0);
  final u = 1000.0 / k;
  final double x;
  if (k < 4000) {
    x = -0.2661239 * u * u * u - 0.2343589 * u * u + 0.8776956 * u + 0.179910;
  } else {
    x = -3.0258469 * u * u * u + 2.1070379 * u * u + 0.2226347 * u + 0.240390;
  }
  final double y;
  if (k < 2222) {
    y = -1.1063814 * x * x * x - 1.34811020 * x * x + 2.18555832 * x -
        0.20219683;
  } else if (k < 4000) {
    y = -0.9549476 * x * x * x - 1.37418593 * x * x + 2.09137015 * x -
        0.16748867;
  } else {
    y = 3.0817580 * x * x * x - 5.87338670 * x * x + 3.75112997 * x -
        0.37001483;
  }
  return [x, y];
}

/// CIE 1960 UCS, the space Duv is defined in.
List<double> _uv(double x, double y) {
  final d = -2 * x + 12 * y + 3;
  return [4 * x / d, 6 * y / d];
}

/// Nearest point on the locus, by ternary search in mired.
///
/// A search rather than McCamy's cubic because it gives the perpendicular
/// distance as a by-product, and that distance is the tint — the thing a
/// single Kelvin figure cannot carry.
(double, double) _cctDuvFromXy(double x, double y) {
  final uv = _uv(x, y);

  double dist(double mired) {
    final p = _planckianXy(1e6 / mired);
    final puv = _uv(p[0], p[1]);
    return _sq(uv[0] - puv[0]) + _sq(uv[1] - puv[1]);
  }

  var lo = 1e6 / 25000, hi = 1e6 / 1667;
  for (var i = 0; i < 100; i++) {
    final a = lo + (hi - lo) / 3;
    final b = hi - (hi - lo) / 3;
    if (dist(a) < dist(b)) {
      hi = b;
    } else {
      lo = a;
    }
  }
  final mired = (lo + hi) / 2;
  final kelvin = 1e6 / mired;

  final p = _planckianXy(kelvin);
  final puv = _uv(p[0], p[1]);
  // In CIE 1960 UCS, higher v is greener — the standard sign convention for
  // Duv, and the one a "tint" control is expected to follow.
  final duv = math.sqrt(dist(mired)) * (uv[1] >= puv[1] ? 1.0 : -1.0);
  return (kelvin, duv);
}

// ── dcraw's camera → sRGB matrix ──────────────────────────────────────────

const List<List<double>> _xyzFromSrgb = [
  [0.4124564, 0.3575761, 0.1804375],
  [0.2126729, 0.7151522, 0.0721750],
  [0.0193339, 0.1191920, 0.9503041],
];

/// Reproduces dcraw's `cam_xyz_coeff`: compose XYZ→camera with sRGB→XYZ,
/// normalise each row to sum to 1, invert.
///
/// The row normalisation is not cosmetic — it is what makes a neutral camera
/// signal come out neutral in sRGB, and it is the step LibRaw folds into
/// `pre_mul`. Reconstructing the matrix the same way is what makes
/// `matrixFor` an exact inverse of what the decode did rather than an
/// approximation of it.
List<List<double>> _rgbCamFrom(List<List<double>> camXyz) {
  final camRgb = _mul3(camXyz, _xyzFromSrgb);
  for (var i = 0; i < 3; i++) {
    final sum = camRgb[i][0] + camRgb[i][1] + camRgb[i][2];
    if (sum.abs() > 1e-9) {
      for (var j = 0; j < 3; j++) {
        camRgb[i][j] /= sum;
      }
    }
  }
  return _invert3(camRgb);
}

// ── 3×3 helpers ───────────────────────────────────────────────────────────

double _sq(double v) => v * v;

List<List<double>> _diag(List<double> d) => [
      [d[0], 0, 0],
      [0, d[1], 0],
      [0, 0, d[2]],
    ];

List<List<double>> _mul3(List<List<double>> a, List<List<double>> b) => [
      for (var i = 0; i < 3; i++)
        [
          for (var j = 0; j < 3; j++)
            a[i][0] * b[0][j] + a[i][1] * b[1][j] + a[i][2] * b[2][j],
        ],
    ];

List<double> _apply3(List<List<double>> m, List<double> v) => [
      for (var i = 0; i < 3; i++)
        m[i][0] * v[0] + m[i][1] * v[1] + m[i][2] * v[2],
    ];

List<List<double>> _invert3(List<List<double>> m) {
  final a = m[0][0], b = m[0][1], c = m[0][2];
  final d = m[1][0], e = m[1][1], f = m[1][2];
  final g = m[2][0], h = m[2][1], i = m[2][2];

  final det = a * (e * i - f * h) - b * (d * i - f * g) + c * (d * h - e * g);
  if (det.abs() < 1e-12) {
    return [
      [1, 0, 0],
      [0, 1, 0],
      [0, 0, 1],
    ];
  }
  final inv = 1.0 / det;
  return [
    [(e * i - f * h) * inv, (c * h - b * i) * inv, (b * f - c * e) * inv],
    [(f * g - d * i) * inv, (a * i - c * g) * inv, (c * d - a * f) * inv],
    [(d * h - e * g) * inv, (b * g - a * h) * inv, (a * e - b * d) * inv],
  ];
}
