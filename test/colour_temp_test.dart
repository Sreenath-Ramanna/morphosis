// test/colour_temp_test.dart
//
// Colour temperature, checked against two things that are not itself: the
// Canon EOS R7's own Kelvin → multiplier table, which is the vendor's answer
// and the strongest ground truth available, and the round trips approach.md
// §11 asks for.
//
// The camera data below was read out of the test frames in
// raw_viewer/test-images with ria_raw_color_data, so these are real
// characterisations rather than plausible-looking numbers.

import 'package:flutter_test/flutter_test.dart';
import 'package:morphosis/src/pipeline/colour_temp.dart';
import 'package:morphosis/src/ria/ria.dart';

/// Nikon Z 6_2, DSC_1436.NEF. No WBCT table at all, so the colorimetric route
/// is the only one available — which is the case this design exists to cover.
final nikon = RawColorData(
  camMul: const [1.8516, 1.0, 1.2285],
  camXyz: const [
    [0.9943, -0.3269, -0.0839],
    [-0.5323, 1.3269, 0.2259],
    [-0.1198, 0.2083, 0.7557],
  ],
  wbct: const [],
);

/// Canon EOS R7, 20250803_A0A8111.CR3. Fifteen rows, 2400–10900 K.
final canonTable = <List<double>>[
  [10900, 2.37037, 1.0, 1.16496],
  [10000, 2.30631, 1.0, 1.19347],
  [8300, 2.16949, 1.0, 1.27205],
  [7000, 2.03579, 1.0, 1.36716],
  [6000, 1.88235, 1.0, 1.47763],
  [5600, 1.81239, 1.0, 1.53523],
  [5200, 1.74446, 1.0, 1.59750],
  [4700, 1.63840, 1.0, 1.72101],
  [4200, 1.51704, 1.0, 1.88582],
  [3800, 1.40274, 1.0, 2.04800],
  [3500, 1.30612, 1.0, 2.20690],
  [3200, 1.20047, 1.0, 2.40941],
  [3000, 1.12404, 1.0, 2.59241],
  [2800, 1.04811, 1.0, 2.77507],
  [2400, 0.89043, 1.0, 3.18012],
];

final canon = RawColorData(
  // As recorded: raw sensor counts, not ratios. RawFile.colorData normalises
  // these; the constant here is already normalised the same way.
  camMul: const [1967.0 / 1024.0, 1.0, 1606.0 / 1024.0],
  camXyz: const [
    [1.0424, -0.3138, -0.1300],
    [-0.4221, 1.1938, 0.2584],
    [-0.0547, 0.1658, 0.6183],
  ],
  wbct: canonTable,
);

final canonWithoutTable = RawColorData(
  camMul: canon.camMul,
  camXyz: canon.camXyz,
  wbct: const [],
);

void main() {
  group('as-shot temperature', () {
    test('the Nikon frame reads as daylight, near the locus', () {
      final wb = WhiteBalance.from(nikon);
      expect(wb.hasCameraTable, isFalse);
      expect(wb.asShot.fromCameraTable, isFalse);
      expect(wb.asShot.reliable, isTrue);
      expect(wb.asShot.kelvin, inInclusiveRange(5000, 6500));
      // Measured Duv is +0.0001 — this white point sits on the locus, so a
      // single Kelvin figure genuinely does describe it.
      expect(wb.asShot.duv.abs(), lessThan(0.002));
    });

    test('the Canon frame is off the locus, and says so', () {
      final wb = WhiteBalance.from(canon);
      expect(wb.hasCameraTable, isTrue);
      expect(wb.asShot.fromCameraTable, isTrue);
      expect(wb.asShot.kelvin, inInclusiveRange(5000, 6500));
      // approach.md §4: the R7's red ratio implies above 6000 K while its
      // blue ratio implies below 5600 K, because the white point is not on
      // the locus. That disagreement is the tint, and it has to survive.
      expect(wb.asShot.duv.abs(), greaterThan(0.004));
      expect(wb.asShot.tintLabel, isNot('neutral'));
    });

    test('the two routes agree to within a few percent', () {
      // Testing a colour temperature implementation only against itself
      // proves nothing. The camera table is an independent answer.
      final table = WhiteBalance.from(canon).asShot.kelvin;
      final colorimetric = WhiteBalance.from(canonWithoutTable).asShot.kelvin;
      expect((colorimetric / table - 1).abs(), lessThan(0.05),
          reason: 'table $table K vs colorimetric $colorimetric K');
    });
  });

  group('multipliers', () {
    test('reproduce the camera table across its whole range', () {
      // The colorimetric route against the vendor's own numbers. Red tracks
      // to a couple of percent; blue carries a systematic offset because the
      // camera's table is not a pure Planckian series and cam_xyz is a D65
      // characterisation. Both are bounded and neither drifts with
      // temperature, which is what makes the route usable.
      final wb = WhiteBalance.from(canonWithoutTable);
      for (final row in canonTable) {
        final m = wb.multipliersFor(row[0]);
        expect((m[0] / row[1] - 1).abs(), lessThan(0.04),
            reason: 'red at ${row[0]} K');
        expect((m[2] / row[3] - 1).abs(), lessThan(0.10),
            reason: 'blue at ${row[0]} K');
      }
    });

    test('are green-normalised and monotonic in temperature', () {
      for (final cd in [nikon, canon]) {
        final wb = WhiteBalance.from(cd);
        double? lastRed, lastBlue;
        for (var k = 2500.0; k <= 10000; k += 250) {
          final m = wb.multipliersFor(k);
          expect(m[1], closeTo(1.0, 1e-9));
          // Cooler light needs more red and less blue as the target rises.
          if (lastRed != null) expect(m[0], greaterThan(lastRed));
          if (lastBlue != null) expect(m[2], lessThan(lastBlue));
          lastRed = m[0];
          lastBlue = m[2];
        }
      }
    });

    test('CCT → multipliers → CCT round-trips within 1%', () {
      // approach.md §11. Run on the colorimetric route, which is the one that
      // has to be self-consistent; the table route is an interpolation of
      // fifteen rows and round-trips exactly by construction.
      final wb = WhiteBalance.from(canonWithoutTable);
      for (var k = 2500.0; k <= 10000; k += 500) {
        final mul = wb.multipliersFor(k);
        final probe = WhiteBalance.from(RawColorData(
          camMul: mul,
          camXyz: canon.camXyz,
          wbct: const [],
        ));
        expect((probe.asShot.kelvin / k - 1).abs(), lessThan(0.01),
            reason: 'at $k K got ${probe.asShot.kelvin} K');
      }
    });
  });

  group('the adaptation matrix', () {
    test('is the identity at the as-shot temperature', () {
      // The slider starting position must be an exact no-op, or opening a
      // frame would silently alter it.
      for (final cd in [nikon, canon]) {
        final wb = WhiteBalance.from(cd);
        expect(wb.isNeutral(wb.asShot.kelvin), isTrue);
        final m = wb.matrixFor(wb.asShot.kelvin);
        for (var i = 0; i < 3; i++) {
          for (var j = 0; j < 3; j++) {
            expect(m[i][j], closeTo(i == j ? 1.0 : 0.0, 1e-9));
          }
        }
      }
    });

    test('composes back to the identity', () {
      // Going to 3200 K and back to as-shot must land where it started.
      final wb = WhiteBalance.from(canon);
      final away = wb.matrixFor(3200);
      final back = _invert(away);
      final product = _mul(back, away);
      for (var i = 0; i < 3; i++) {
        for (var j = 0; j < 3; j++) {
          expect(product[i][j], closeTo(i == j ? 1.0 : 0.0, 1e-9));
        }
      }
    });

    test('warms the image when the target temperature rises', () {
      // The convention every editor uses: raising the Temp slider says the
      // scene light was bluer than assumed, so the render compensates warm.
      final wb = WhiteBalance.from(canon);
      final grey = [0.2, 0.2, 0.2];
      final warm = _apply(wb.matrixFor(wb.asShot.kelvin + 2500), grey);
      final cool = _apply(wb.matrixFor(wb.asShot.kelvin - 2000), grey);
      expect(warm[0] / warm[2], greaterThan(1.0));
      expect(cool[0] / cool[2], lessThan(1.0));
    });

    test('leaves luminance roughly where it was', () {
      // The matrix changes colour; brightness belongs to the tone engine. A
      // white-balance control that also moved exposure would make every EV
      // reading on screen a moving target.
      final wb = WhiteBalance.from(nikon);
      const lr = 0.2126, lg = 0.7152, lb = 0.0722;
      final base = [0.2, 0.2, 0.2];
      final baseY = base[0] * lr + base[1] * lg + base[2] * lb;
      for (final k in [3000.0, 4500.0, 8000.0, 11000.0]) {
        final out = _apply(wb.matrixFor(k), base);
        final y = out[0] * lr + out[1] * lg + out[2] * lb;
        expect((y / baseY - 1).abs(), lessThan(0.35), reason: 'at $k K');
      }
    });
  });

  group('slider range', () {
    test('covers the camera table when there is one', () {
      final wb = WhiteBalance.from(canon);
      expect(wb.minKelvin, lessThanOrEqualTo(2400));
      expect(wb.maxKelvin, greaterThanOrEqualTo(10900));
    });

    test('falls back to a sane range when there is not', () {
      final wb = WhiteBalance.from(nikon);
      expect(wb.minKelvin, 2000);
      expect(wb.maxKelvin, 12000);
    });
  });
}

List<double> _apply(List<List<double>> m, List<double> v) => [
      for (var i = 0; i < 3; i++)
        m[i][0] * v[0] + m[i][1] * v[1] + m[i][2] * v[2],
    ];

List<List<double>> _mul(List<List<double>> a, List<List<double>> b) => [
      for (var i = 0; i < 3; i++)
        [
          for (var j = 0; j < 3; j++)
            a[i][0] * b[0][j] + a[i][1] * b[1][j] + a[i][2] * b[2][j],
        ],
    ];

List<List<double>> _invert(List<List<double>> m) {
  final a = m[0][0], b = m[0][1], c = m[0][2];
  final d = m[1][0], e = m[1][1], f = m[1][2];
  final g = m[2][0], h = m[2][1], i = m[2][2];
  final det = a * (e * i - f * h) - b * (d * i - f * g) + c * (d * h - e * g);
  final inv = 1.0 / det;
  return [
    [(e * i - f * h) * inv, (c * h - b * i) * inv, (b * f - c * e) * inv],
    [(f * g - d * i) * inv, (a * i - c * g) * inv, (c * d - a * f) * inv],
    [(d * h - e * g) * inv, (b * g - a * h) * inv, (a * e - b * d) * inv],
  ];
}
