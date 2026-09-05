// test/pipeline/working_space_test.dart
//
// The working space, and the matrices that move in and out of it.
//
// The matrices normally come from C, but the colour work is fully testable in
// CI without a RAW file and without a built `.so` — and that is worth stating
// plainly, because the alternative is a whole feature checked only by hand.
// [_libRawTable] below is LibRaw 0.22.2's own `out_rgb[]`, read out of the
// installed library during planning, and `colorspaceMatrixSource` is pointed
// at it. `tool/pipeline_check.dart`'s P7 is the one place the C table and this
// reference are checked against each other, on a machine that has both.

import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:morphosis/src/pipeline/colour_temp.dart';
import 'package:morphosis/src/pipeline/working_space.dart';
import 'package:morphosis/src/ria/ria.dart';

import '../colour_temp_test.dart' show canon, nikon;

/// LibRaw 0.22.2's `out_rgb[]`: linear sRGB → the named space, row-major.
const Map<int, List<double>> libRawTable = {
  RiaColorspace.srgb: [1, 0, 0, 0, 1, 0, 0, 0, 1],
  RiaColorspace.adobe: [
    0.715146, 0.284856, 0.000000, //
    0.000000, 1.000000, 0.000000, //
    0.000000, 0.041166, 0.958839,
  ],
  RiaColorspace.wide: [
    0.593087, 0.404710, 0.002206, //
    0.095413, 0.843149, 0.061439, //
    0.011621, 0.069091, 0.919288,
  ],
  RiaColorspace.prophoto: [
    0.529317, 0.330092, 0.140588, //
    0.098368, 0.873465, 0.028169, //
    0.016879, 0.117663, 0.865457,
  ],
  RiaColorspace.xyz: [
    0.412456, 0.357576, 0.180438, //
    0.212673, 0.715152, 0.072175, //
    0.019334, 0.119192, 0.950304,
  ],
  RiaColorspace.aces: [
    0.439680, 0.382953, 0.177367, //
    0.089790, 0.813433, 0.096777, //
    0.017548, 0.111562, 0.870890,
  ],
};

/// The spaces with RGB primaries. XYZ is deliberately not among them: it is
/// not an RGB space, so its rows sum to the D65 white point rather than to 1
/// and a neutral does not stay neutral through it. Every "a grey in is a grey
/// out" property below is about RGB spaces.
const rgbSpaces = <int>[
  RiaColorspace.srgb,
  RiaColorspace.adobe,
  RiaColorspace.wide,
  RiaColorspace.prophoto,
  RiaColorspace.aces,
];

const allSpaces = <int>[...rgbSpaces, RiaColorspace.xyz];

void main() {
  setUp(() {
    colorspaceMatrixSource = (space) => libRawTable[space]!;
    resetWorkingSpaceCache();
  });

  tearDown(() {
    colorspaceMatrixSource = Ria.colorspaceFromSrgb;
    resetWorkingSpaceCache();
  });

  group('the matrices', () {
    test('W1 sRGB is the identity, and costs nothing', () {
      final m = srgbFromWorking(RiaColorspace.srgb);
      for (var i = 0; i < 3; i++) {
        for (var j = 0; j < 3; j++) {
          expect(m[i][j], i == j ? 1.0 : 0.0,
              reason: 'bit-exact, not close to');
        }
      }
      expect(
        composedMatrix(
            inputSpace: RiaColorspace.srgb,
            outputSpace: RiaColorspace.srgb,
            wbMatrix: null,
            saturationScale: 1.0),
        isNull,
        reason: 'the existing nine-multiplies fast path survives where it can',
      );
    });

    test('W2 a round trip is the identity', () {
      final rnd = math.Random(20260905);
      for (final space in allSpaces) {
        final f = workingFromSrgb(space);
        final b = srgbFromWorking(space);
        var worst = 0.0;
        for (var i = 0; i < 1000; i++) {
          final v = [rnd.nextDouble(), rnd.nextDouble(), rnd.nextDouble()];
          final round = apply3(b, apply3(f, v));
          for (var c = 0; c < 3; c++) {
            final e = (round[c] - v[c]).abs();
            if (e > worst) worst = e;
          }
        }
        expect(worst, lessThan(1e-9), reason: 'space $space');
      }
    });

    test('W3 a neutral grey stays neutral', () {
      for (final space in rgbSpaces) {
        for (final v in [0.02, 0.18, 1.0]) {
          for (final m in [workingFromSrgb(space), srgbFromWorking(space)]) {
            final out = apply3(m, [v, v, v]);
            for (var c = 0; c < 3; c++) {
              expect(out[c], closeTo(v, 1e-5), reason: 'space $space at $v');
            }
          }
        }
      }
    });
  });

  group('the luminance row', () {
    test('W4 it measures the same light Rec.709 does', () {
      final rnd = math.Random(4);
      for (final space in allSpaces) {
        final row = lumaRowFor(space);
        final f = workingFromSrgb(space);
        for (var i = 0; i < 200; i++) {
          final c = [rnd.nextDouble(), rnd.nextDouble(), rnd.nextDouble()];
          final inSpace = apply3(f, c);
          final mine = row[0] * inSpace[0] +
              row[1] * inSpace[1] +
              row[2] * inSpace[2];
          final rec709 = rec709Luma[0] * c[0] +
              rec709Luma[1] * c[1] +
              rec709Luma[2] * c[2];
          // The same linear functional of the source, by construction. It is
          // what makes the preview and the TIFF agree about how bright a pixel
          // is, and it is why this row rather than the space's own D50 Y row.
          expect(mine, closeTo(rec709, 1e-9), reason: 'space $space');
        }
      }
    });

    test('W5 it is not Rec.709 in a wide space', () {
      final row = lumaRowFor(RiaColorspace.prophoto);
      var worst = 0.0;
      for (var i = 0; i < 3; i++) {
        final d = (row[i] - rec709Luma[i]).abs();
        if (d > worst) worst = d;
      }
      expect(worst, greaterThan(0.01),
          reason: 'a copy-paste that left Rec.709 in place would pass every '
              'other property here');
      // The refinement in the plan's section 0, written down.
      expect(row[0], closeTo(0.268206, 1e-5));
      expect(row[1], closeTo(0.715217, 1e-5));
      expect(row[2], closeTo(0.016577, 1e-5));
    });

    test('sRGB gets Rec.709 back, identically', () {
      expect(lumaRowFor(RiaColorspace.srgb), rec709Luma);
    });
  });

  group('the white balance follows the space', () {
    test('W6 an sRGB working space reproduces the matrix from before', () {
      for (final cd in [nikon, canon]) {
        final wb = WhiteBalance.from(cd);
        for (var k = wb.minKelvin; k <= wb.maxKelvin; k += 250) {
          final before = wb.matrixFor(k);
          final after = composedMatrix(
            inputSpace: RiaColorspace.srgb,
            outputSpace: RiaColorspace.srgb,
            wbMatrix: before,
            saturationScale: 1.0,
          )!;
          for (var i = 0; i < 3; i++) {
            for (var j = 0; j < 3; j++) {
              expect(after[i * 3 + j], closeTo(before[i][j], 1e-12),
                  reason: 'at ${k.round()} K');
            }
          }
        }
      }
    });

    test('W7 the wide matrix is the similarity transform of the sRGB one', () {
      const space = RiaColorspace.prophoto;
      final m = workingFromSrgb(space);
      final mInv = srgbFromWorking(space);
      for (final cd in [nikon, canon]) {
        final srgbWb = WhiteBalance.from(cd);
        final wideWb = WhiteBalance.from(cd, space: space);
        for (final k in [3000.0, 4500.0, 5600.0, 7000.0, 9000.0]) {
          final expected = mul3(mul3(m, srgbWb.matrixFor(k)), mInv);
          final actual = wideWb.matrixFor(k);
          for (var i = 0; i < 3; i++) {
            for (var j = 0; j < 3; j++) {
              expect(actual[i][j], closeTo(expected[i][j], 1e-9),
                  reason: 'a left/right multiply swap survives every other '
                      'property in this file');
            }
          }
        }
      }
    });

    test('W8 the row normalisation survived', () {
      // The snippet in requirements section C reduces this loop to a comment.
      // Without it a neutral camera signal stops coming out neutral, and the
      // symptom reads as "the wide decode looks a bit off" rather than a bug.
      //
      // The tolerance is the table's own rounding, not slack. LibRaw publishes
      // `out_rgb[]` to six decimal places, so its rows sum to 1 only to within
      // 2.5e-6 — Adobe RGB's first row is 1.000002 — and that residual passes
      // straight through the inverse. sRGB's matrix is the exact identity, so
      // there the normalisation is checked at full precision, and that is the
      // case the deleted loop would break first.
      for (final cd in [nikon, canon]) {
        for (final space in rgbSpaces) {
          final wb = WhiteBalance.from(cd, space: space);
          final tolerance = space == RiaColorspace.srgb ? 1e-9 : 5e-6;
          for (var i = 0; i < 3; i++) {
            final sum = wb.camRgb[i][0] + wb.camRgb[i][1] + wb.camRgb[i][2];
            expect(sum, closeTo(1.0, tolerance),
                reason: 'space $space, row $i');
          }
        }
      }
    });

    test('W9 the matrix is still the identity at as-shot, in every space', () {
      for (final cd in [nikon, canon]) {
        for (final space in rgbSpaces) {
          final wb = WhiteBalance.from(cd, space: space);
          final m = wb.matrixFor(wb.asShot.kelvin);
          for (var i = 0; i < 3; i++) {
            for (var j = 0; j < 3; j++) {
              expect(m[i][j], closeTo(i == j ? 1.0 : 0.0, 1e-9),
                  reason: 'the slider must be an exact no-op at its initial '
                      'position, whatever the working space (space $space)');
            }
          }
        }
      }
    });
  });

  group('the saturation anchor', () {
    test('W10 it enters as a scalar', () {
      final wb = WhiteBalance.from(canon, space: RiaColorspace.prophoto);
      final m = wb.matrixFor(wb.asShot.kelvin + 900);
      final one = composedMatrix(
        inputSpace: RiaColorspace.prophoto,
        outputSpace: RiaColorspace.srgb,
        wbMatrix: m,
        saturationScale: 1.0,
      )!;
      final half = composedMatrix(
        inputSpace: RiaColorspace.prophoto,
        outputSpace: RiaColorspace.srgb,
        wbMatrix: m,
        saturationScale: 0.5,
      )!;
      for (var i = 0; i < 9; i++) {
        expect(half[i], one[i] * 2.0, reason: 'exactly, not closeTo');
      }
    });

    test('a scale alone is enough to need a matrix', () {
      expect(
        composedMatrix(
            inputSpace: RiaColorspace.srgb,
            outputSpace: RiaColorspace.srgb,
            wbMatrix: null,
            saturationScale: 0.52),
        isNotNull,
      );
    });
  });

  group('the delivery decisions', () {
    test('the working space is wide, and the JPEG is not', () {
      expect(workingSpace, RiaColorspace.prophoto);
      expect(exportTiffSpace, workingSpace);
      expect(exportJpegSpace, RiaColorspace.srgb);
      expect(previewSpace, RiaColorspace.srgb);
    });
  });
}
