// test/render_test.dart
//
// The fused render pass and the file writers, on synthetic frames.

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:morphosis/src/model/edit.dart' show saturationRange, vibranceRange;
import 'package:image/image.dart' as img;
import 'package:morphosis/src/pipeline/export.dart';
import 'package:morphosis/src/pipeline/icc.dart';
import 'package:morphosis/src/pipeline/render.dart';
import 'package:morphosis/src/pipeline/tone.dart';
import 'package:morphosis/src/pipeline/working_space.dart';
import 'package:morphosis/src/ria/ria.dart';

import 'pipeline/working_space_test.dart' show libRawTable;

/// A grey ramp in scene-linear 16-bit RGB, spanning fourteen stops.
Uint16List rampFrame(int n) {
  final out = Uint16List(n * 3);
  for (var i = 0; i < n; i++) {
    final t = i / (n - 1);
    final v = (65535 * math.pow(2.0, -14 * (1 - t))).round().clamp(0, 65535);
    out[i * 3] = out[i * 3 + 1] = out[i * 3 + 2] = v;
  }
  return out;
}

/// Saturated colour patches in scene-linear 16-bit RGB, one pixel each.
///
/// A grey ramp cannot exercise a control whose whole job is chroma. These sit
/// below sensor saturation and span the hue circle, so no property below can
/// be satisfied by one accidental channel order; the neutral and the near
/// black are there because a control that only works on vivid colour is a
/// control that has a special case nobody wrote down.
const _patches = <List<int>>[
  [30000, 9000, 4500], // warm
  [5000, 22000, 8000], // green
  [6000, 9000, 33000], // blue
  [26000, 26000, 6000], // yellow
  [22000, 6000, 22000], // magenta
  [5000, 24000, 26000], // cyan
  [15000, 15000, 15000], // neutral: nothing to saturate
  [900, 800, 1000], // near black
];

Uint16List _colourFrame() {
  final out = Uint16List(_patches.length * 3);
  for (var i = 0; i < _patches.length; i++) {
    out[i * 3] = _patches[i][0];
    out[i * 3 + 1] = _patches[i][1];
    out[i * 3 + 2] = _patches[i][2];
  }
  return out;
}

void main() {
  group('vibrance', () {
    final src = _vibranceFrame();
    final n = _vibrancePairs.length;
    final base = _render8(src, n, 0);

    test('zero is byte-exact, with and without saturation', () {
      for (final sat in [0.0, 30.0, -30.0]) {
        final withoutIt = _render8(src, n, sat);
        final withZero = _render8(src, n, sat, vibrance: 0);
        expect(withZero, withoutIt,
            reason: 'vibrance 0 must change nothing at saturation $sat');
      }
    });

    test('a boost lifts flat colour further than vivid colour', () {
      // The defining property, and the whole difference from saturation:
      // the weight is 1 − how saturated the pixel already is.
      for (final setting in [25.0, 50.0]) {
        final out = _render8(src, n, 0, vibrance: setting);
        for (var pair = 0; pair < n; pair += 2) {
          final pale = pair, vivid = pair + 1;
          final paleGain = _spread(out, pale) / _spread(base, pale);
          final vividGain = _spread(out, vivid) / _spread(base, vivid);
          expect(paleGain, greaterThan(vividGain),
              reason: 'vibrance $setting: the pale patch $pale gained '
                  '${paleGain.toStringAsFixed(3)}× and the vivid patch '
                  '$vivid gained ${vividGain.toStringAsFixed(3)}×');
          expect(paleGain, greaterThan(1.0));
        }
      }
    });

    test('a pixel already at full saturation is left alone at every setting',
        () {
      // One channel at zero means the weight is exactly 1 − 1, so the factor
      // is exactly 1 and the write must land on the same code it started on.
      final full = Uint16List.fromList([30000, 0, 0]);
      final flat = _render8(full, 1, 0);
      expect(flat[1], 0, reason: 'the patch must really be fully saturated');

      for (final setting in [-50.0, -10.0, 10.0, 50.0]) {
        expect(_render8(full, 1, 0, vibrance: setting), flat,
            reason: 'vibrance $setting must not move a pixel that has no '
                'flatness left to lift');
      }
    });

    test('luma is preserved at every setting', () {
      for (var setting = -vibranceRange;
          setting <= vibranceRange;
          setting += 5) {
        final out = _render8(src, n, 0, vibrance: setting);
        for (var i = 0; i < n; i++) {
          expect(_lumaAt(out, i), closeTo(_lumaAt(base, i), 1.0),
              reason: 'vibrance $setting, patch $i');
        }
      }
    });

    test('a boost holds the hue direction', () {
      var checked = 0;
      for (final setting in [10.0, 25.0, 50.0]) {
        final out = _render8(src, n, 0, vibrance: setting);
        for (var i = 0; i < n; i++) {
          if (!_wellInside(base, i)) continue;
          _expectSameDirection(base, out, i, 'vibrance $setting, patch $i');
          checked++;
        }
      }
      expect(checked, greaterThan(4));
    });

    test('the two controls compose, neither cancelling the other', () {
      // The factors multiply, so both together can only widen what either
      // widened alone.
      final sat = _render8(src, n, 25);
      final vib = _render8(src, n, 0, vibrance: 25);
      final both = _render8(src, n, 25, vibrance: 25);
      for (var i = 0; i < n; i++) {
        if (!_wellInside(base, i)) continue;
        expect(_spread(both, i), greaterThanOrEqualTo(_spread(sat, i)),
            reason: 'patch $i');
        expect(_spread(both, i), greaterThanOrEqualTo(_spread(vib, i)),
            reason: 'patch $i');
      }
    });

    test('the export loop applies it too', () {
      // renderRgb16 is a separate loop with a wider table; a fix applied to
      // one and not the other shows up here and nowhere else.
      final t = Tone(greyPoint: _greyPoint);
      final disp =
          t.buildDisplayLut(outMax: 65535, entries: DisplayLut.exportEntries);
      final flat = Uint16List(n * 3);
      renderRgb16(src, n, 1, null, t.buildGainLut(), disp, flat);
      final boosted = Uint16List(n * 3);
      renderRgb16(src, n, 1, null, t.buildGainLut(), disp, boosted,
          vibrance: vibranceRange);

      for (var pair = 0; pair < n; pair += 2) {
        expect(_spread(boosted, pair), greaterThan(_spread(flat, pair)),
            reason: 'the pale patch $pair must be lifted in the export loop');
      }
    });
  });

  group('the fused pass', () {
    test('a neutral edit is monotonic across fourteen stops', () {
      const n = 512;
      final src = rampFrame(n);
      final tone = Tone(greyPoint: 0.05);
      final dst = Uint8List(n * 3);
      renderRgb8(src, n, 1, null, tone.buildGainLut(),
          tone.buildDisplayLut(outMax: 255, entries: DisplayLut.previewEntries),
          dst);

      var previous = -1;
      for (var i = 0; i < n; i++) {
        expect(dst[i * 3], dst[i * 3 + 1], reason: 'grey stayed grey');
        expect(dst[i * 3 + 1], dst[i * 3 + 2]);
        expect(dst[i * 3], greaterThanOrEqualTo(previous));
        previous = dst[i * 3];
      }
      // The darkest sample is −14 EV, which after a two-stop lift is still
      // inside the first code value or two rather than exactly zero.
      expect(dst[0], lessThanOrEqualTo(2));
      expect(dst[(n - 1) * 3], 255);

      final rgba = expandToRgba(dst, n);
      for (var i = 0; i < n; i++) {
        expect(rgba[i * 4], dst[i * 3]);
        expect(rgba[i * 4 + 3], 255, reason: 'alpha is opaque');
      }
    });

    test('brightness of one stop moves midtones the way it should', () {
      const n = 256;
      final src = rampFrame(n);
      Uint8List renderAt(double grey) {
        final t = Tone(greyPoint: grey);
        final dst = Uint8List(n * 3);
        renderRgb8(
            src,
            n,
            1,
            null,
            t.buildGainLut(),
            t.buildDisplayLut(
                outMax: 255, entries: DisplayLut.previewEntries),
            dst);
        return dst;
      }

      final dark = renderAt(0.10);
      final bright = renderAt(0.05);
      // Everything that was not already black or white is brighter.
      var lifted = 0;
      for (var i = 0; i < n; i++) {
        if (dark[i * 3] > 4 && dark[i * 3] < 250) {
          expect(bright[i * 3], greaterThan(dark[i * 3]));
          lifted++;
        }
      }
      expect(lifted, greaterThan(50));
    });

    test('exposure adjustments preserve hue', () {
      // approach.md §11: the test that catches an accidental per-channel
      // implementation. A saturated patch must keep its chromaticity when the
      // tone engine changes its luminance.
      const n = 1;
      // Deliberately well below saturation and adjusted gently: the property
      // is about the arithmetic, and a channel that clips has lost its ratio
      // to the clamp rather than to a per-channel bug.
      final src = Uint16List.fromList([8000, 2400, 1200]);
      final ratios = <List<double>>[];
      for (final shadow in [-1.5, 0.0, 1.5]) {
        final t = Tone(greyPoint: 0.18, shadowEv: shadow, highlightEv: shadow);
        final out = Uint16List(3);
        renderRgb16(
            src,
            n,
            1,
            null,
            t.buildGainLut(),
            t.buildDisplayLut(
                outMax: 65535, entries: DisplayLut.exportEntries),
            out);
        for (final v in out) {
          expect(v, greaterThan(0));
          expect(v, lessThan(65535), reason: 'the patch must not clip');
        }
        // Back to linear before comparing: the ratios are only meaningful
        // there, which is the whole point of the two-domain split.
        final lin = [for (final v in out) srgbDecode(v / 65535)];
        final sum = lin[0] + lin[1] + lin[2];
        ratios.add([lin[0] / sum, lin[1] / sum]);
      }
      for (final r in ratios.skip(1)) {
        expect(r[0], closeTo(ratios[0][0], 0.01));
        expect(r[1], closeTo(ratios[0][1], 0.01));
      }
    });

    test('a white-balance matrix that is null costs nothing and changes nothing',
        () {
      const n = 64;
      final src = rampFrame(n);
      final t = Tone(greyPoint: 0.05);
      final lut = t.buildGainLut();
      final disp =
          t.buildDisplayLut(outMax: 255, entries: DisplayLut.previewEntries);

      final withNull = Uint8List(n * 3);
      renderRgb8(src, n, 1, null, lut, disp, withNull);
      final withIdentity = Uint8List(n * 3);
      renderRgb8(
          src,
          n,
          1,
          Float64List.fromList([1, 0, 0, 0, 1, 0, 0, 0, 1]),
          lut,
          disp,
          withIdentity);
      expect(withIdentity, withNull);
    });
  });

  group('saturation', () {
    final src = _colourFrame();
    final n = _patches.length;
    final base = _render8(src, n, 0);

    test('zero is byte-exact against a render that never mentions saturation',
        () {
      final t = Tone(greyPoint: _greyPoint);
      final lut = t.buildGainLut();
      final disp =
          t.buildDisplayLut(outMax: 255, entries: DisplayLut.previewEntries);
      // With and without a white balance, because the two arms of the matrix
      // branch reach the write through different locals.
      final matrix = Float64List.fromList(
          [1.04, 0.02, -0.01, 0.01, 0.99, 0.02, -0.02, 0.03, 1.08]);

      for (final m in <Float64List?>[null, matrix]) {
        final withoutIt = Uint8List(n * 3);
        renderRgb8(src, n, 1, m, lut, disp, withoutIt);
        final withZero = Uint8List(n * 3);
        renderRgb8(src, n, 1, m, lut, disp, withZero, saturation: 0);
        // `y + (c − y) × 1.0` is not bit-exactly `c`, so this is the test that
        // fails if the zero branch is not hoisted out of the loop.
        expect(withZero, withoutIt,
            reason: 'saturation 0 must be the same lookups and the same '
                'writes as a render that has never heard of it');
      }
    });

    test('−50 lands every pixel on its own luma', () {
      final grey = _render8(src, n, -saturationRange);
      for (var i = 0; i < n; i++) {
        expect(grey[i * 3], grey[i * 3 + 1], reason: 'patch $i');
        expect(grey[i * 3 + 1], grey[i * 3 + 2], reason: 'patch $i');
        // One code of tolerance is the quantisation, not slack: the common
        // value is the rounded Rec.709 luma of the unsaturated render.
        expect(grey[i * 3].toDouble(), closeTo(_lumaAt(base, i), 1.0),
            reason: 'patch $i');
      }
    });

    test('a boost widens the channel spread and never narrows it', () {
      var strict = 0;
      for (final setting in [5.0, 10.0, 25.0, 50.0]) {
        final out = _render8(src, n, setting);
        for (var i = 0; i < n; i++) {
          expect(_spread(out, i), greaterThanOrEqualTo(_spread(base, i)),
              reason: 'saturation $setting, patch $i');
          if (_wellInside(base, i)) {
            expect(_spread(out, i), greaterThan(_spread(base, i)),
                reason: 'saturation $setting, patch $i');
            strict++;
          }
        }
      }
      expect(strict, greaterThan(8),
          reason: 'the strict half of the property must not be vacuous');
    });

    test('a boost holds the hue direction on an in-gamut pixel', () {
      // Hue in this operation *is* the direction of (r − y, g − y, b − y). A
      // per-channel clamp is exactly what rotates it, so this is the property
      // that separates the gamut limiter from the rejected implementation.
      var checked = 0;
      for (final setting in [10.0, 25.0, 50.0]) {
        final out = _render8(src, n, setting);
        for (var i = 0; i < n; i++) {
          if (!_wellInside(base, i)) continue;
          _expectSameDirection(base, out, i, 'saturation $setting, patch $i');
          checked++;
        }
      }
      expect(checked, greaterThan(6));
    });

    test('luma is preserved at every setting', () {
      // The gamut-limited factor scales all three distances by one number, so
      // the weighted sum of the distances stays zero. Hard clamping is what
      // destroys this.
      for (var setting = -saturationRange;
          setting <= saturationRange;
          setting += 5) {
        final out = _render8(src, n, setting);
        for (var i = 0; i < n; i++) {
          expect(_lumaAt(out, i), closeTo(_lumaAt(base, i), 1.0),
              reason: 'saturation $setting, patch $i');
        }
      }
    });

    test('boosting never reorders the channels, so nothing wrapped or clipped',
        () {
      // A Uint8List assignment of 256 wraps silently to 0, which turns the
      // brightest channel into the darkest. A dense grid of sources, because
      // the arithmetic edge is what is being hunted rather than any one hue.
      const levels = [900, 5000, 15000, 34000, 65535];
      final grid = <int>[];
      for (final r in levels) {
        for (final g in levels) {
          for (final b in levels) {
            grid.addAll([r, g, b]);
          }
        }
      }
      final dense = Uint16List.fromList(grid);
      final count = levels.length * levels.length * levels.length;
      final flat = _render8(dense, count, 0);
      final boosted = _render8(dense, count, saturationRange);

      for (var i = 0; i < count; i++) {
        final f = [flat[i * 3], flat[i * 3 + 1], flat[i * 3 + 2]];
        final o = [boosted[i * 3], boosted[i * 3 + 1], boosted[i * 3 + 2]];
        final hi = f.indexOf(f.reduce(math.max));
        final lo = f.indexOf(f.reduce(math.min));
        expect(o[hi], o.reduce(math.max), reason: 'pixel $i: $f became $o');
        expect(o[lo], o.reduce(math.min), reason: 'pixel $i: $f became $o');
      }
    });

    test('a pixel already at the gamut edge keeps its hue and takes what boost '
        'it can', () {
      // Bright enough that the red channel renders at display white, so the
      // limiter has nowhere left to move it.
      final edge = Uint16List.fromList([65535, 26000, 9000]);
      final flat = _render8(edge, 1, 0);
      expect(flat[0], 255, reason: 'the patch must actually reach the edge');

      final boosted = _render8(edge, 1, saturationRange);
      expect(boosted[0], 255,
          reason: 'the maximum channel stays at white — not wrapped to 0, and '
              'not pulled back down');
      _expectSameDirection(flat, boosted, 0, 'at the gamut edge');
    });

    test('the spread is monotone in the setting and no channel crosses its '
        'luma', () {
      // The operation is affine about the luma, so a larger setting can only
      // move a channel further out along the same ray. That is composition
      // stated in the form the public API can express.
      final previous = List<int>.filled(n, -1);
      for (var setting = -saturationRange;
          setting <= saturationRange;
          setting += 5) {
        final out = _render8(src, n, setting);
        for (var i = 0; i < n; i++) {
          expect(_spread(out, i), greaterThanOrEqualTo(previous[i]),
              reason: 'saturation $setting, patch $i');
          previous[i] = _spread(out, i);

          final y = _lumaAt(base, i);
          for (var c = 0; c < 3; c++) {
            final d = base[i * 3 + c] - y;
            // Half a code is the rounding of the write; the sign itself never
            // turns over.
            if (d > 0) {
              expect(out[i * 3 + c].toDouble(), greaterThanOrEqualTo(y - 0.5),
                  reason: 'saturation $setting, patch $i, channel $c');
            } else if (d < 0) {
              expect(out[i * 3 + c].toDouble(), lessThanOrEqualTo(y + 0.5),
                  reason: 'saturation $setting, patch $i, channel $c');
            }
          }
        }
      }
    });

    test('black stays black and white stays white', () {
      // The Rec.709 weights are all positive and sum to one, so the luma can
      // only reach an end of the range when all three channels are already
      // there. Every distance is then zero and the factor has nothing to
      // scale — which is why neither end needs a special case, and why the
      // channel-on-its-own-luma branch has to be a skip rather than a bound
      // computed from a zero denominator.
      final ends = Uint16List.fromList([0, 0, 0, 65535, 65535, 65535]);
      for (final setting in [-saturationRange, 25.0, saturationRange]) {
        final out = _render8(ends, 2, setting);
        expect(out.sublist(0, 3), [0, 0, 0], reason: 'saturation $setting');
        expect(out.sublist(3, 6), [255, 255, 255],
            reason: 'saturation $setting');
      }
    });

    test('the export loop and the preview loop agree no less well with '
        'saturation than without', () {
      // The two loops read display tables of different widths, so exact
      // equality is not available and is not the property. Staying within the
      // factor is: the operation is affine about the luma, so it scales the
      // half-code the two tables already disagree by rather than inventing a
      // disagreement of its own. A fix applied to one loop and not the other
      // shows up as a hundred codes, not as one.
      double worstAt(double setting) {
        final eight = _render8(src, n, setting);
        final sixteen = _render16(src, n, setting);
        var worst = 0.0;
        for (var i = 0; i < n * 3; i++) {
          final d = (eight[i] - sixteen[i] * 255.0 / 65535.0).abs();
          if (d > worst) worst = d;
        }
        return worst;
      }

      final neutral = worstAt(0);
      for (final setting in [saturationRange, -saturationRange]) {
        final factor = 1 + setting / saturationRange;
        // Plus one code for the rounding of the write, which the neutral pass
        // does not do at all — it copies table entries.
        expect(worstAt(setting), lessThanOrEqualTo(factor * neutral + 1),
            reason: 'saturation $setting pulled the two loops apart by more '
                'than the factor it applies');
      }
    });
  });

  group('camera look', () {
    final src = _colourFrame();
    final n = _patches.length;

    Uint8List render8(
            {double saturation = 0, double lookSaturation = 0,
            Float64List? matrix}) {
      final t = Tone(greyPoint: _greyPoint);
      final dst = Uint8List(n * 3);
      renderRgb8(
          src,
          n,
          1,
          matrix,
          t.buildGainLut(),
          t.buildDisplayLut(outMax: 255, entries: DisplayLut.previewEntries),
          dst,
          saturation: saturation,
          lookSaturation: lookSaturation);
      return dst;
    }

    Uint16List render16({double saturation = 0, double lookSaturation = 0}) {
      final t = Tone(greyPoint: _greyPoint);
      final dst = Uint16List(n * 3);
      renderRgb16(
          src,
          n,
          1,
          null,
          t.buildGainLut(),
          t.buildDisplayLut(outMax: 65535, entries: DisplayLut.exportEntries),
          dst,
          saturation: saturation,
          lookSaturation: lookSaturation);
      return dst;
    }

    test('L12 lookSaturation 0 is byte-exact against a render that never '
        'mentions it', () {
      // The exact twin of the saturation case above, and for the same reason:
      // `y + (c − y) × 1.0` is not bit-exactly `c`, so at zero the arithmetic
      // has to be skipped rather than passed through.
      final matrix = Float64List.fromList(
          [1.04, 0.02, -0.01, 0.01, 0.99, 0.02, -0.02, 0.03, 1.08]);
      for (final m in <Float64List?>[null, matrix]) {
        expect(render8(lookSaturation: 0, matrix: m), render8(matrix: m),
            reason: 'lookSaturation 0 must be the same lookups and the same '
                'writes as a render that has never heard of it');
      }
      expect(render16(lookSaturation: 0), render16());
    });

    test('L13 the look\'s colour and the slider compose multiplicatively', () {
      // At slider zero the look *is* +20, which is what the measurement said.
      expect(render8(lookSaturation: 20, saturation: 0),
          render8(lookSaturation: 0, saturation: 20));

      // And the composition itself, stated as an equality against the existing
      // one-factor path, so the gamut limiter is exercised identically in both.
      for (final s in [-50.0, -25.0, 25.0, 50.0]) {
        final combined =
            saturationRange * ((1 + 20 / saturationRange) *
                (1 + s / saturationRange) - 1);
        expect(render8(lookSaturation: 20, saturation: s),
            render8(lookSaturation: 0, saturation: combined),
            reason: 'slider $s composes to $combined');
      }
    });

    test('L14 −50 is greyscale whether the look is on or off', () {
      // The property that decides the composition. Under an *additive* one the
      // effective value would be −30, the factor 0.4, and a monochrome
      // conversion would be unreachable with the preset on — the slider's
      // endpoint would silently change meaning.
      final grey =
          render8(lookSaturation: 20, saturation: -saturationRange);
      for (var i = 0; i < n; i++) {
        expect(grey[i * 3], grey[i * 3 + 1], reason: 'patch $i');
        expect(grey[i * 3 + 1], grey[i * 3 + 2], reason: 'patch $i');
      }
      expect(grey, render8(saturation: -saturationRange));
    });
  });

  group('zone histogram', () {
    test('finds the percentile of a known ramp', () {
      const n = 4096;
      final zh = ZoneHistogram.compute(rampFrame(n), n, 1,
          lumaRow: rec709Luma, saturationScale: 1.0);
      expect(zh.pixels, n);
      // The ramp is uniform in EV over [−14, 0], so the median sits at −7.
      expect(zh.medianEv, closeTo(-7.0, 0.4));
    });

    test('the auto grey point places the top of the frame at display white',
        () {
      const n = 4096;
      final zh = ZoneHistogram.compute(rampFrame(n), n, 1,
          lumaRow: rec709Luma, saturationScale: 1.0);
      final grey = zh.autoGreyPoint();
      final displayWhite = grey / 0.18;
      // p99.5 of a −14…0 EV ramp is about −0.07 EV, i.e. just under 1.0.
      expect(displayWhite, inInclusiveRange(0.8, 1.05));
    });

    test('an all-black frame does not produce a degenerate grey point', () {
      final zh = ZoneHistogram.compute(Uint16List(300), 100, 1,
          lumaRow: rec709Luma, saturationScale: 1.0);
      final grey = zh.autoGreyPoint();
      expect(grey, greaterThan(0));
      expect(grey.isFinite, isTrue);
    });
  });

  group('TIFF', () {
    test('has a readable header and the right amount of data', () {
      const w = 7, h = 5;
      final rgb = Uint16List(w * h * 3);
      for (var i = 0; i < rgb.length; i++) {
        rgb[i] = (i * 997) & 0xFFFF;
      }
      final bytes = encodeTiff16(rgb, w, h);
      final bd = ByteData.view(bytes.buffer);

      expect(bytes[0], 0x49);
      expect(bytes[1], 0x49);
      expect(bd.getUint16(2, Endian.little), 42);
      final ifd = bd.getUint32(4, Endian.little);
      final count = bd.getUint16(ifd, Endian.little);
      expect(count, greaterThan(8));

      final tags = <int, List<int>>{};
      for (var i = 0; i < count; i++) {
        final off = ifd + 2 + i * 12;
        tags[bd.getUint16(off, Endian.little)] = [
          bd.getUint16(off + 2, Endian.little),
          bd.getUint32(off + 4, Endian.little),
          bd.getUint32(off + 8, Endian.little),
        ];
      }
      expect(tags[256]![2], w);
      expect(tags[257]![2], h);
      expect(tags[259]![2] & 0xFFFF, 1, reason: 'uncompressed');
      expect(tags[262]![2] & 0xFFFF, 2, reason: 'RGB');
      expect(tags[277]![2] & 0xFFFF, 3, reason: 'three samples');
      expect(tags[279]![2], rgb.lengthInBytes);

      // Tags must be in ascending order or a strict reader rejects the file.
      final ordered = tags.keys.toList()..sort();
      expect(tags.keys.toList(), ordered);

      // BitsPerSample lives out of line; three 16s.
      final bps = tags[258]![2];
      for (var i = 0; i < 3; i++) {
        expect(bd.getUint16(bps + i * 2, Endian.little), 16);
      }

      // And the pixels come back unchanged.
      final start = tags[273]![2];
      for (var i = 0; i < rgb.length; i++) {
        expect(bd.getUint16(start + i * 2, Endian.little), rgb[i]);
      }
      expect(bytes.length, start + rgb.lengthInBytes);
    });
  });

  group('JPEG', () {
    test('encodes at the requested quality and round-trips roughly', () {
      const w = 32, h = 32;
      final rgb = Uint8List(w * h * 3);
      for (var i = 0; i < w * h; i++) {
        rgb[i * 3] = (i * 3) & 0xFF;
        rgb[i * 3 + 1] = 128;
        rgb[i * 3 + 2] = 200;
      }
      final bytes = encodeJpeg(rgb, w, h, defaultJpegQuality);
      expect(bytes.length, greaterThan(100));
      expect(bytes[0], 0xFF);
      expect(bytes[1], 0xD8, reason: 'SOI');
      expect(bytes[bytes.length - 2], 0xFF);
      expect(bytes[bytes.length - 1], 0xD9, reason: 'EOI');

      // Quality is actually plumbed through, not ignored.
      final low = encodeJpeg(rgb, w, h, 60);
      expect(low.length, lessThan(bytes.length));
    });

    test('the default quality is 95', () {
      expect(defaultJpegQuality, 95);
    });
  });

  // ── The working space, the anchor, and the profiles ────────────────────

  group('the composed matrix', () {
    setUp(() {
      colorspaceMatrixSource = (space) => libRawTable[space]!;
      resetWorkingSpaceCache();
    });
    tearDown(() {
      colorspaceMatrixSource = Ria.colorspaceFromSrgb;
      resetWorkingSpaceCache();
    });

    Uint8List render8(Uint16List src, int n, Float64List? m,
        List<double> lumaRow) {
      final tone = Tone(greyPoint: 0.05);
      final dst = Uint8List(n * 3);
      renderRgb8(
          src,
          n,
          1,
          m,
          tone.buildGainLut(),
          tone.buildDisplayLut(
              outMax: 255, entries: DisplayLut.previewEntries),
          dst,
          lumaRow: lumaRow);
      return dst;
    }

    Uint16List render16(Uint16List src, int n, Float64List? m,
        List<double> lumaRow) {
      final tone = Tone(greyPoint: 0.05);
      final dst = Uint16List(n * 3);
      renderRgb16(
          src,
          n,
          1,
          m,
          tone.buildGainLut(),
          tone.buildDisplayLut(
              outMax: 65535, entries: DisplayLut.exportEntries),
          dst,
          lumaRow: lumaRow);
      return dst;
    }

    test('R6 a null matrix and an identity matrix render identically', () {
      const n = 512;
      final src = rampFrame(n);
      final identity = Float64List.fromList([1, 0, 0, 0, 1, 0, 0, 0, 1]);
      expect(render8(src, n, null, rec709Luma),
          render8(src, n, identity, rec709Luma),
          reason: 'the hasMatrix fast path must agree with the loop it skips');
      expect(render16(src, n, null, rec709Luma),
          render16(src, n, identity, rec709Luma));
    });

    test('R7 the two output spaces agree about the pixel', () {
      // One working-space buffer, rendered twice: once converted to sRGB with
      // the Rec.709 row, once left in ProPhoto with the working-space row.
      // Undo the display encoding on both and the second, converted down to
      // sRGB, must be the first — which is the property that makes a TIFF and
      // the preview that approved it the same photograph.
      const space = RiaColorspace.prophoto;
      final toSrgb = srgbFromWorking(space);
      final m = composedMatrix(
        inputSpace: space,
        outputSpace: RiaColorspace.srgb,
        wbMatrix: null,
        saturationScale: 1.0,
      );
      final src = _colourFrame();
      final n = _patches.length;

      final a = render8(src, n, m, rec709Luma);
      final b = render16(src, n, null, lumaRowFor(space));

      for (var i = 0; i < n; i++) {
        final linA = [
          for (var c = 0; c < 3; c++) srgbDecode(a[i * 3 + c] / 255.0),
        ];
        final linB = [
          for (var c = 0; c < 3; c++) srgbDecode(b[i * 3 + c] / 65535.0),
        ];
        // Only in-gamut pixels: a channel resting on 0 or 1 has been clamped
        // and carries no information about what it was.
        final clamped = linA.any((v) => v <= 0.0 || v >= 1.0) ||
            linB.any((v) => v <= 0.0 || v >= 1.0);
        if (clamped) continue;

        final converted = apply3(toSrgb, linB);
        for (var c = 0; c < 3; c++) {
          expect(converted[c], closeTo(linA[c], 4 / 255.0),
              reason: 'patch $i, channel $c');
        }
      }
    });

    test('R9 the zone histogram uses the row it is given', () {
      // A saturated blue: Rec.709 weights blue at 0.0722, the ProPhoto row at
      // 0.0166, so the same pixel is more than a stop darker under the second.
      final src = Uint16List.fromList([0, 0, 60000]);
      final rec = ZoneHistogram.compute(src, 1, 1,
          lumaRow: rec709Luma, saturationScale: 1.0);
      final wide = ZoneHistogram.compute(src, 1, 1,
          lumaRow: lumaRowFor(RiaColorspace.prophoto), saturationScale: 1.0);

      double expectedEv(List<double> row) =>
          math.log(row[2] * 60000 / 65535.0) / math.ln2;

      expect(rec.medianEv, closeTo(expectedEv(rec709Luma), 0.3));
      expect(wide.medianEv,
          closeTo(expectedEv(lumaRowFor(RiaColorspace.prophoto)), 0.3));
      expect(rec.medianEv - wide.medianEv, greaterThan(1.0),
          reason: 'the two rows must genuinely disagree, or this proves '
              'nothing');
    });
  });

  group('the saturation anchor', () {
    test('R8 it is an exposure shift the histogram undoes', () {
      // The synthetic, CI-runnable form of the headline property: a frame
      // rescaled by s and binned with saturationScale s reports the median it
      // had before. P3 in pipeline_check.dart is the same thing on a real
      // frame.
      const n = 4096;
      final base = rampFrame(n);
      final unscaled = ZoneHistogram.compute(base, n, 1,
          lumaRow: rec709Luma, saturationScale: 1.0);

      for (final s in [0.5401, 0.5206, 0.25]) {
        final scaled = Uint16List(base.length);
        for (var i = 0; i < base.length; i++) {
          scaled[i] = (base[i] * s).round();
        }
        final anchored = ZoneHistogram.compute(scaled, n, 1,
            lumaRow: rec709Luma, saturationScale: s);
        expect(anchored.medianEv, closeTo(unscaled.medianEv, 0.02),
            reason: 'at a scale of $s');

        // And without the division it moves by exactly the scale, which is
        // the failure this exists to catch.
        final unanchored = ZoneHistogram.compute(scaled, n, 1,
            lumaRow: rec709Luma, saturationScale: 1.0);
        expect(unanchored.medianEv,
            closeTo(unscaled.medianEv + math.log(s) / math.ln2, 0.05));
      }
    });

    test('R10 the tone tables reach past the recovered maximum', () {
      // Requirements section 5 measured the maximum in anchor units at 1.24
      // for highlight_mode 1, 1.50 for mode 2 and 1.92 for mode 3; the library
      // implementation then measured 1.715 for mode 2 on the Canon frame. The
      // recovered highlights have to reach the shoulder unclamped, which means
      // both tables must span well past that.
      expect(Tone.gainYMax, greaterThanOrEqualTo(2.0));
      expect(DisplayLut.vMax, greaterThanOrEqualTo(2.0));
    });
  });

  group('ICC tagging', () {
    setUp(() {
      colorspaceMatrixSource = (space) => libRawTable[space]!;
      resetWorkingSpaceCache();
    });
    tearDown(() {
      colorspaceMatrixSource = Ria.colorspaceFromSrgb;
      resetWorkingSpaceCache();
    });

    test('R1 tag 34675 points at the profile and the pixels still follow it',
        () {
      const w = 7, h = 5;
      final rgb = Uint16List(w * h * 3);
      for (var i = 0; i < rgb.length; i++) {
        rgb[i] = (i * 997) & 0xFFFF;
      }
      final profile = iccProfileFor(RiaColorspace.prophoto);
      final bytes = encodeTiff16(rgb, w, h, iccProfile: profile);
      final bd = ByteData.view(bytes.buffer);

      final ifd = bd.getUint32(4, Endian.little);
      final count = bd.getUint16(ifd, Endian.little);
      expect(count, 13, reason: 'twelve entries plus the profile');

      final tags = <int, List<int>>{};
      for (var i = 0; i < count; i++) {
        final off = ifd + 2 + i * 12;
        tags[bd.getUint16(off, Endian.little)] = [
          bd.getUint16(off + 2, Endian.little),
          bd.getUint32(off + 4, Endian.little),
          bd.getUint32(off + 8, Endian.little),
        ];
      }
      final ordered = tags.keys.toList()..sort();
      expect(tags.keys.toList(), ordered, reason: 'tags must ascend');

      final icc = tags[34675]!;
      expect(icc[0], 7, reason: 'UNDEFINED');
      expect(icc[1], profile.length);
      final pixelOffset = tags[273]![2];
      expect(icc[2] + icc[1], lessThanOrEqualTo(pixelOffset),
          reason: 'the profile block sits before the pixels');
      expect(bytes.sublist(icc[2], icc[2] + icc[1]), profile);

      // And the pixels still come back unchanged.
      for (var i = 0; i < rgb.length; i++) {
        expect(bd.getUint16(pixelOffset + i * 2, Endian.little), rgb[i]);
      }
      expect(bytes.length, pixelOffset + rgb.lengthInBytes);
    });

    test('R2 without a profile the file is exactly what it was', () {
      const w = 7, h = 5;
      final rgb = Uint16List(w * h * 3);
      for (var i = 0; i < rgb.length; i++) {
        rgb[i] = (i * 997) & 0xFFFF;
      }
      expect(encodeTiff16(rgb, w, h, iccProfile: null),
          encodeTiff16(rgb, w, h));
      final bd = ByteData.view(encodeTiff16(rgb, w, h).buffer);
      expect(bd.getUint16(bd.getUint32(4, Endian.little), Endian.little), 12);
    });

    test('R3 the APP2 segment is conformant', () {
      const w = 32, h = 32;
      final rgb = Uint8List(w * h * 3);
      for (var i = 0; i < w * h; i++) {
        rgb[i * 3] = (i * 3) & 0xFF;
        rgb[i * 3 + 1] = 128;
        rgb[i * 3 + 2] = 200;
      }
      final profile = iccProfileFor(RiaColorspace.srgb);
      final bytes =
          encodeJpeg(rgb, w, h, defaultJpegQuality, iccProfile: profile);

      expect(bytes[0], 0xFF);
      expect(bytes[1], 0xD8, reason: 'SOI');

      // Walk the segments: the APP2 must appear after SOI and after any APPn
      // the encoder already wrote, and before SOS.
      var at = 2, found = -1;
      while (at + 3 < bytes.length && bytes[at] == 0xFF) {
        final marker = bytes[at + 1];
        if (marker == 0xDA) break; // SOS
        final len = (bytes[at + 2] << 8) | bytes[at + 3];
        if (marker == 0xE2) {
          found = at;
          break;
        }
        at += 2 + len;
      }
      expect(found, greaterThan(2), reason: 'an APP2 segment before SOS');

      final len = (bytes[found + 2] << 8) | bytes[found + 3];
      expect(len, 2 + 12 + 2 + profile.length,
          reason: 'package:image 4.9.2 writes this two bytes short, which is '
              'why the segment is spliced by hand');
      expect(
          String.fromCharCodes(bytes.sublist(found + 4, found + 15)),
          'ICC_PROFILE');
      expect(bytes[found + 15], 0, reason: 'the signature NUL');
      expect(bytes[found + 16], 1, reason: 'chunk number, 1-based');
      expect(bytes[found + 17], 1, reason: 'chunk count');
      expect(bytes.sublist(found + 18, found + 18 + profile.length), profile);
    });

    test('R4 the spliced file still decodes', () {
      const w = 32, h = 32;
      final rgb = Uint8List(w * h * 3);
      for (var i = 0; i < w * h; i++) {
        rgb[i * 3] = 40;
        rgb[i * 3 + 1] = 130;
        rgb[i * 3 + 2] = 210;
      }
      final bytes = encodeJpeg(rgb, w, h, defaultJpegQuality,
          iccProfile: iccProfileFor(RiaColorspace.srgb));
      final decoded = img.decodeJpg(bytes);
      expect(decoded, isNotNull);
      expect(decoded!.width, w);
      expect(decoded.height, h);
      final px = decoded.getPixel(16, 16);
      expect(px.r, closeTo(40, 8));
      expect(px.g, closeTo(130, 8));
      expect(px.b, closeTo(210, 8));
    });

    test('R5 an oversized profile is refused, not truncated', () {
      const w = 8, h = 8;
      final rgb = Uint8List(w * h * 3);
      final bytes = encodeJpeg(rgb, w, h, defaultJpegQuality);
      expect(() => spliceIccApp2(bytes, Uint8List(70000)),
          throwsArgumentError);
      expect(maxIccSegment, lessThan(65533 - 14 + 1));
    });

    test('a real profile is nowhere near the single-chunk limit', () {
      for (final space in [RiaColorspace.srgb, RiaColorspace.prophoto]) {
        expect(iccProfileFor(space).length, lessThan(8000));
      }
    });
  });
}

/// The tone every saturation property renders through. One grey point, so the
/// only thing moving between two renders is the setting under test.
const double _greyPoint = 0.18;

Uint8List _render8(Uint16List src, int n, double saturation,
    {double vibrance = 0}) {
  final t = Tone(greyPoint: _greyPoint);
  final dst = Uint8List(n * 3);
  renderRgb8(src, n, 1, null, t.buildGainLut(),
      t.buildDisplayLut(outMax: 255, entries: DisplayLut.previewEntries), dst,
      saturation: saturation, vibrance: vibrance);
  return dst;
}

/// Pairs of the same hue, one washed out and one vivid, at similar luma.
/// Vibrance is defined by what it does *differently* to the two, so a frame
/// of uniformly vivid patches could not test it at all.
const _vibrancePairs = <List<int>>[
  [11000, 12500, 15500], // pale blue
  [3000, 6000, 30000], // vivid blue
  [13000, 15000, 11500], // pale green
  [4000, 26000, 6000], // vivid green
  [16000, 13500, 13000], // pale warm
  [30000, 9000, 4500], // vivid warm
];

Uint16List _vibranceFrame() {
  final out = Uint16List(_vibrancePairs.length * 3);
  for (var i = 0; i < _vibrancePairs.length; i++) {
    out[i * 3] = _vibrancePairs[i][0];
    out[i * 3 + 1] = _vibrancePairs[i][1];
    out[i * 3 + 2] = _vibrancePairs[i][2];
  }
  return out;
}

Uint16List _render16(Uint16List src, int n, double saturation) {
  final t = Tone(greyPoint: _greyPoint);
  final dst = Uint16List(n * 3);
  renderRgb16(src, n, 1, null, t.buildGainLut(),
      t.buildDisplayLut(outMax: 65535, entries: DisplayLut.exportEntries), dst,
      saturation: saturation);
  return dst;
}

double _lumaAt(List<int> px, int i) =>
    px[i * 3] * 0.2126 + px[i * 3 + 1] * 0.7152 + px[i * 3 + 2] * 0.0722;

int _spread(List<int> px, int i) {
  final r = px[i * 3], g = px[i * 3 + 1], b = px[i * 3 + 2];
  return math.max(r, math.max(g, b)) - math.min(r, math.min(g, b));
}

/// A patch with room to move in both directions, so a boost is not silently
/// tested against a pixel the limiter has already pinned.
bool _wellInside(List<int> px, int i) {
  final r = px[i * 3], g = px[i * 3 + 1], b = px[i * 3 + 2];
  return math.min(r, math.min(g, b)) >= 20 &&
      math.max(r, math.max(g, b)) <= 200 &&
      _spread(px, i) >= 30;
}

/// The two pixels point the same way out of grey — the cross product of the
/// normalised distance vectors is zero to within quantisation.
void _expectSameDirection(List<int> a, List<int> b, int i, String reason) {
  final ya = _lumaAt(a, i), yb = _lumaAt(b, i);
  final u = [a[i * 3] - ya, a[i * 3 + 1] - ya, a[i * 3 + 2] - ya];
  final v = [b[i * 3] - yb, b[i * 3 + 1] - yb, b[i * 3 + 2] - yb];
  final nu = math.sqrt(u[0] * u[0] + u[1] * u[1] + u[2] * u[2]);
  final nv = math.sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]);
  expect(nu, greaterThan(1e-6), reason: '$reason: the source has no chroma');
  expect(nv, greaterThan(1e-6), reason: '$reason: the chroma disappeared');
  final cross = [
    (u[1] * v[2] - u[2] * v[1]) / (nu * nv),
    (u[2] * v[0] - u[0] * v[2]) / (nu * nv),
    (u[0] * v[1] - u[1] * v[0]) / (nu * nv),
  ];
  for (final c in cross) {
    expect(c, closeTo(0, 0.03), reason: '$reason: hue rotated');
  }
}
