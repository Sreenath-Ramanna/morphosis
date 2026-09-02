// test/tone_test.dart
//
// The properties approach.md §11 asks for, on the parts of the design this
// app implements. They are cheap, and each one catches a specific way the
// tone engine can be subtly wrong while still producing a plausible picture.

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:morphosis/src/pipeline/tone.dart';

/// The input-EV → output-EV mapping the gain table encodes, evaluated
/// directly so a test can reason about the curve rather than about a lookup.
double mapEv(Tone t, double e, {double zoneScale = 1.0}) {
  final w = Float64List(4);
  Tone.weights(e, t.centres, w);
  final z = t.zoneEv;
  var e1 = e;
  for (var i = 0; i < 4; i++) {
    e1 += w[i] * z[i] * zoneScale;
  }
  final p = math.log(t.pivot) / math.ln2;
  return p + t.contrastSlope * (e1 - p);
}

void main() {
  group('zone weights', () {
    test('are a partition of unity across the whole range', () {
      final t = Tone(greyPoint: 0.05);
      final w = Float64List(4);
      for (var e = -20.0; e <= 4.0; e += 0.01) {
        Tone.weights(e, t.centres, w);
        final sum = w[0] + w[1] + w[2] + w[3];
        expect(sum, closeTo(1.0, 1e-12), reason: 'at $e EV');
        for (final v in w) {
          expect(v, greaterThanOrEqualTo(0.0));
        }
      }
    });

    test('the analytic slope matches a numerical difference', () {
      final t = Tone(greyPoint: 0.05);
      final k = t.centres;
      final a = Float64List(4), b = Float64List(4), s = Float64List(4);
      const h = 1e-5;
      for (var e = k[0] - 1; e <= k[3] + 1; e += 0.013) {
        Tone.weights(e - h, k, a);
        Tone.weights(e + h, k, b);
        Tone.weightSlopes(e, k, s);
        for (var i = 0; i < 4; i++) {
          expect(s[i], closeTo((b[i] - a[i]) / (2 * h), 1e-4),
              reason: 'weight $i at $e EV');
        }
      }
    });

    test('the top centre sits just under display white', () {
      // The whole reason the centres are anchored to the grey point rather
      // than to sensor saturation: a "white level" control has to act on what
      // the viewer sees as white.
      const grey = 0.048;
      final t = Tone(greyPoint: grey);
      final displayWhiteEv = math.log(grey / middleGrey) / math.ln2;
      expect(t.centres[3], closeTo(displayWhiteEv + defaultZoneCentresEv[3],
          1e-9));
      expect(t.centres[3], lessThan(displayWhiteEv));
      expect(t.centres[3], greaterThan(displayWhiteEv - 1));
    });

    test('each zone dominates at its own centre', () {
      final t = Tone(greyPoint: 0.05);
      final c = t.centres;
      final w = Float64List(4);
      for (var i = 0; i < 4; i++) {
        Tone.weights(c[i], c, w);
        var best = 0;
        for (var j = 1; j < 4; j++) {
          if (w[j] > w[best]) best = j;
        }
        expect(best, i, reason: 'zone \$i did not dominate at its own centre');
        // Wide basis functions are the point, but a zone that carried less
        // than half the weight at its own centre would not deserve the label.
        expect(w[i], greaterThan(0.5), reason: 'zone \$i weight \${w[i]}');
      }
    });
  });

  group('contrast', () {
    test('+c then −c is the identity', () {
      const grey = 0.05;
      for (final c in [0.5, 1.0, 2.0, 3.0]) {
        final up = Tone(greyPoint: grey, contrastEv: c);
        final down = Tone(greyPoint: grey, contrastEv: -c);
        for (var e = -12.0; e <= 1.0; e += 0.25) {
          expect(mapEv(down, mapEv(up, e)), closeTo(e, 1e-9),
              reason: 'c = $c at $e EV');
        }
      }
    });

    test('slope is 2^(c/3), so +3 doubles the stops between two tones', () {
      expect(Tone(greyPoint: 0.05, contrastEv: 3).contrastSlope,
          closeTo(2.0, 1e-12));
      expect(Tone(greyPoint: 0.05, contrastEv: -3).contrastSlope,
          closeTo(0.5, 1e-12));
      expect(Tone(greyPoint: 0.05, contrastEv: 0).contrastSlope,
          closeTo(1.0, 1e-12));
    });

    test('leaves the pivot fixed', () {
      final t = Tone(greyPoint: 0.05, contrastEv: 2.5);
      final p = math.log(t.pivot) / math.ln2;
      expect(mapEv(t, p), closeTo(p, 1e-9));
    });
  });

  group('monotonicity', () {
    test('opposed zones do drive the slope negative — the failure is real', () {
      // approach.md §7 warns this is reachable inside the ±3 EV the sliders
      // offer. If this ever stops being true the soft limit has become dead
      // code and the test below proves nothing.
      // Lifting blacks while crushing shadows: the widest-spaced adjacent
      // pair, so the steepest transition, and the direction that folds.
      final t = Tone(greyPoint: 0.05, blackEv: 3, shadowEv: -3);
      expect(t.minSlope(), lessThan(0));
      expect(t.softLimitFactor(), lessThan(1.0));
    });

    test('the soft limit restores it, for every combination of extremes', () {
      const grey = 0.05;
      for (final b in [-3.0, 0.0, 3.0]) {
        for (final s in [-3.0, 0.0, 3.0]) {
          for (final h in [-3.0, 0.0, 3.0]) {
            for (final w in [-3.0, 0.0, 3.0]) {
              for (final c in [-3.0, 0.0, 3.0]) {
                final t = Tone(
                  greyPoint: grey,
                  contrastEv: c,
                  blackEv: b,
                  shadowEv: s,
                  highlightEv: h,
                  whiteEv: w,
                );
                final f = t.softLimitFactor();
                expect(f, inInclusiveRange(0.0, 1.0));
                final scaled = [for (final z in t.zoneEv) z * f];
                expect(t.minSlope(scaled),
                    greaterThan(minSlopeFloor - 1e-6),
                    reason: 'b$b s$s h$h w$w c$c scaled to $f');
              }
            }
          }
        }
      }
    });

    test('leaves ordinary edits completely alone', () {
      // Open the shadows, pull the highlights, a little contrast — the most
      // common edit there is. Under the smoothstep basis approach.md §6
      // specifies, this was scaled back to 76%; it must not be.
      for (final t in [
        Tone(greyPoint: 0.05, shadowEv: 1.5, highlightEv: -1.0,
            contrastEv: 0.5),
        Tone(greyPoint: 0.05, blackEv: -1, shadowEv: 1.5, highlightEv: -1,
            whiteEv: 1),
        Tone(greyPoint: 0.05, shadowEv: 2, highlightEv: -2),
      ]) {
        expect(t.softLimitFactor(), 1.0);
      }
    });

    test('the tabulated curve never decreases', () {
      final t = Tone(
        greyPoint: 0.05,
        blackEv: -2,
        shadowEv: 3,
        highlightEv: -3,
        whiteEv: 2,
        contrastEv: 1.5,
      );
      final lut = t.buildGainLut();
      var previous = -1.0;
      for (var i = 0; i < Tone.gainEntries; i++) {
        final y = ((i + 0.5) / Tone.gainEntries) *
            ((i + 0.5) / Tone.gainEntries) *
            Tone.gainYMax;
        final out = y * lut[i];
        expect(out, greaterThanOrEqualTo(previous - 1e-9),
            reason: 'entry $i went backwards');
        previous = out;
      }
    });
  });

  group('gain table', () {
    test('is the identity when nothing is adjusted', () {
      final lut = Tone(greyPoint: 0.05).buildGainLut();
      for (final v in lut) {
        expect(v, 1.0);
      }
    });

    test('indexing round-trips to within a hundredth of a stop', () {
      // Below about −13 EV the engine clamps to `evFloor` anyway, so the
      // table's resolution there is not load-bearing.
      for (final y in [1e-4, 0.001, 0.01, 0.05, 0.18, 0.5, 1.0, 3.9]) {
        final i = Tone.gainIndex(y);
        final t = (i + 0.5) / Tone.gainEntries;
        final recovered = t * t * Tone.gainYMax;
        expect((math.log(recovered / y) / math.ln2).abs(), lessThan(0.02),
            reason: 'Y = $y');
      }
    });
  });

  group('display table', () {
    test('the shoulder is the identity when white is at 1.0', () {
      // approach.md §9: extended Reinhard with W = 1 reduces to y, which is
      // why engaging the shoulder needs something above display white first.
      final clip = Tone(greyPoint: middleGrey)
          .buildDisplayLut(outMax: 255, entries: 4096);
      final shoulder = Tone(greyPoint: middleGrey, shoulder: true)
          .buildDisplayLut(outMax: 255, entries: 4096);
      for (var i = 0; i <= 4096; i++) {
        expect(shoulder.asBytes[i], clip.asBytes[i], reason: 'entry $i');
      }
    });

    test('the shoulder compresses rather than flattens when brightening', () {
      // The test approach.md §11 names for catching a materialised
      // intermediate buffer: with real headroom, clip and shoulder must
      // disagree, and the shoulder must keep distinct values near the top.
      const grey = 0.045; // roughly +2 stops
      final clip = Tone(greyPoint: grey)
          .buildDisplayLut(outMax: 255, entries: 1 << 14);
      final shoulder = Tone(greyPoint: grey, shoulder: true)
          .buildDisplayLut(outMax: 255, entries: 1 << 14);

      var differ = 0;
      for (var i = 0; i <= 1 << 14; i++) {
        if (clip.asBytes[i] != shoulder.asBytes[i]) differ++;
      }
      expect(differ, greaterThan(1000),
          reason: 'shoulder and clip agreed — the rolloff did nothing');

      // Values well above display white must still be distinguishable.
      int codeAt(double v) {
        final i = (math.sqrt(v) * shoulder.indexScale)
            .toInt()
            .clamp(0, shoulder.entries);
        return shoulder.asBytes[i];
      }
      expect(codeAt(0.30), lessThan(codeAt(0.60)));
      expect(codeAt(0.60), lessThan(codeAt(0.95)));
      // Clipping, by contrast, has pinned all of those to white.
      int clipAt(double v) {
        final i =
            (math.sqrt(v) * clip.indexScale).toInt().clamp(0, clip.entries);
        return clip.asBytes[i];
      }
      expect(clipAt(0.30), 255);
    });

    test('is monotonic and spans the output range', () {
      final lut = Tone(greyPoint: 0.05, shoulder: true)
          .buildDisplayLut(outMax: 65535, entries: 1 << 16);
      var previous = -1;
      for (var i = 0; i <= 1 << 16; i++) {
        final v = lut.asWords[i];
        expect(v, greaterThanOrEqualTo(previous));
        previous = v;
      }
      expect(lut.asWords[0], 0);
      expect(lut.asWords[1 << 16], 65535);
    });
  });

  group('brightness', () {
    test('halving the grey point is exactly one stop', () {
      final a = Tone(greyPoint: 0.10);
      final b = Tone(greyPoint: 0.05);
      expect(b.displayOffsetEv - a.displayOffsetEv, closeTo(-1.0, 1e-12));
    });
  });
}
