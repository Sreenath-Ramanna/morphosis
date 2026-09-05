// test/tone_test.dart
//
// The properties approach.md §11 asks for, on the parts of the design this
// app implements. They are cheap, and each one catches a specific way the
// tone engine can be subtly wrong while still producing a plausible picture.

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:morphosis/src/model/edit.dart' show CameraLook;
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
      // L9 is the second Tone: the same extremes with the preset on. Flat at
      // the top once the base curve clips, which greaterThanOrEqualTo allows.
      for (final t in [
        Tone(
          greyPoint: 0.05,
          blackEv: -2,
          shadowEv: 3,
          highlightEv: -3,
          whiteEv: 2,
          contrastEv: 1.5,
        ),
        Tone(
          greyPoint: 0.05,
          blackEv: -2,
          shadowEv: 3,
          highlightEv: -3,
          whiteEv: 2,
          contrastEv: 1.5,
          cameraLook: CameraLook.camera,
        ),
      ]) {
        final lut = t.buildGainLut();
        var previous = -1.0;
        for (var i = 0; i < Tone.gainEntries; i++) {
          final y = ((i + 0.5) / Tone.gainEntries) *
              ((i + 0.5) / Tone.gainEntries) *
              Tone.gainYMax;
          final out = y * lut[i];
          // With the look on the top of the table is a plateau — L6's clip —
          // and a plateau of *constant output* is a gain that falls like 1/y,
          // which a Float32 table cannot hold exactly. The slack there has to
          // be relative to the value, at about ten times Float32's epsilon.
          // The look-off arm keeps the absolute 1e-9 it always had.
          final slack = t.cameraLook.isNone
              ? 1e-9
              : math.max(1e-9, previous.abs() * 1e-6);
          expect(out, greaterThanOrEqualTo(previous - slack),
              reason: 'entry $i went backwards, look ${t.cameraLook.name}');
          previous = out;
        }
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

  group('camera look', () {
    /// `base(v)` evaluated directly, so a test can reason about the curve
    /// rather than about a table entry.
    // The enum's field is not a constant expression, so it cannot be a
    // default parameter value; the null does the same job.
    double base(double v, {double? gain}) =>
        cameraLookCurve(v, gain ?? CameraLook.camera.gain);

    test('L1 the dcraw curve\'s two segments meet in value and in slope', () {
      // The bisection in `gamma_curve_init` exists to solve exactly this, so
      // it is the property that pins the curve without a table of samples.
      final c = dcrawCurve;
      final b = c.breakpoint;

      // Value. The plan asks for this as |encode(b−h) − encode(b+h)|, which
      // cannot be met: the curve's slope there is 4.5, so that difference is
      // ~9e-7 for any h large enough to be meaningful. Continuity is a
      // statement about the two closed forms agreeing *at* b, and that is what
      // the bisection actually solves, so it is asserted directly.
      final fromToe = b * c.toeSlope;
      final fromPower =
          math.pow(b, c.power).toDouble() * (1 + c.offset) - c.offset;
      expect((fromToe - fromPower).abs(), lessThan(1e-9),
          reason: 'the segments do not meet at the breakpoint');

      // Slope, one-sided, either side of the breakpoint.
      const h = 1e-7;
      final below = (c.encode(b) - c.encode(b - h)) / h;
      final above = (c.encode(b + h) - c.encode(b)) / h;
      expect(below, closeTo(above, 1e-4));

      // The toe is exactly linear with the slope it was given — exactly,
      // because it is one multiply.
      for (final r in [1e-6, 1e-4, 0.001, 0.01, b * 0.5, b * 0.99]) {
        expect(c.encode(r), r * c.toeSlope, reason: 'toe at $r');
      }
      expect(c.toeSlope, 4.5);

      // And the power segment is `v^g0 · (1 + g4) − g4` for the solved g4,
      // self-consistently — no published constant appears here, only the ones
      // the bisection produced.
      for (final r in [b * 1.01, 0.05, 0.2, 0.5, 0.9, 0.999]) {
        expect(c.encode(r),
            closeTo(math.pow(r, c.power).toDouble() * (1 + c.offset) - c.offset,
                1e-15),
            reason: 'power segment at $r');
      }
    });

    test('L2 the dcraw curve is Rec.709\'s published shape', () {
      // The cross-check that catches a transcription error rather than a maths
      // error — in particular a reciprocal power applied the wrong way round,
      // which stays smooth, stays monotone and fails only here.
      //
      // The tolerance is the gap between the constants the bisection solves
      // (1.099275 / 0.099275) and the published rounded ones (1.099 / 0.099).
      // Do not tighten it: it is a property of the rounding in the standard,
      // not slack.
      expect(dcrawCurve.breakpoint, closeTo(0.018053, 1e-4));
      for (final v in [0.05, 0.2, 0.5, 0.9]) {
        final published = 1.099 * math.pow(v, 0.45).toDouble() - 0.099;
        expect((dcrawCurve.encode(v) - published).abs(), lessThan(2e-3),
            reason: 'at $v');
      }
    });

    test('L3 the base curve fixes its endpoints', () {
      expect(base(0), closeTo(0.0, 1e-12));
      // The load-bearing half: display white does not move, which is why the
      // preset is a look and not an exposure change.
      expect(base(1), closeTo(1.0, 1e-12));
    });

    test('L4 the base curve is monotone and bounded', () {
      const steps = 100000;
      var previous = -1.0;
      for (var i = 0; i <= steps; i++) {
        final v = DisplayLut.vMax * i / steps;
        final y = base(v);
        expect(y, greaterThanOrEqualTo(previous), reason: 'went back at $v');
        // The upper bound is a real property, not paperwork: it is what makes
        // the curve safe to compose before the shoulder.
        expect(y, inInclusiveRange(0.0, 1.0), reason: 'out of range at $v');
        previous = y;
      }
    });

    test('L5 the base curve crosses the identity exactly once below mid grey',
        () {
      // This is what "adds contrast" means without a golden table.
      const steps = 200000;
      var crossings = 0;
      var crossing = double.nan;
      var previous = base(1 / steps) - 1 / steps;
      for (var i = 2; i < steps; i++) {
        final v = i / steps;
        final d = base(v) - v;
        if (d == 0) continue;
        if (previous < 0 && d > 0 || previous > 0 && d < 0) {
          crossings++;
          crossing = v;
        }
        previous = d;
      }
      expect(crossings, 1, reason: 'the curve is not a single-crossing shape');
      // Below it shadows darken — the black point that ships inside the
      // preset — and above it midtones lift.
      expect(base(crossing * 0.5), lessThan(crossing * 0.5));
      expect(base(0.5), greaterThan(0.5));
      expect(crossing, inExclusiveRange(0.03, 0.15));
      expect(crossing, lessThan(middleGrey));
    });

    test('L6 the base curve saturates, and that is the design', () {
      // The one surprising consequence of the settled design: with the preset
      // on, a neutral highlight is already at display white before
      // `buildDisplayLut` runs, so the highlight-rolloff shoulder has nothing
      // left to compress on neutral colour. That falls out of "reproduces a
      // plain LibRaw decode" — a clipping decode is what is being reproduced.
      final gain = CameraLook.camera.gain;
      final clipsAt = 1 / gain;
      expect(clipsAt, closeTo(0.6988, 1e-4));
      for (final v in [
        clipsAt * (1 + 1e-12),
        0.7,
        0.75,
        0.9,
        1.0,
        2.0,
        DisplayLut.vMax,
      ]) {
        expect(base(v), 1.0, reason: 'did not clip at $v');
      }
      for (final v in [0.1, 0.3, 0.5, 0.65, clipsAt * (1 - 1e-6)]) {
        expect(base(v), lessThan(1.0), reason: 'clipped early at $v');
      }
    });

    test('L7 the gain table is unchanged when the look is none', () {
      final implicit =
          Tone(greyPoint: 0.05, contrastEv: 0.8, shadowEv: 1.2).buildGainLut();
      final explicit = Tone(
        greyPoint: 0.05,
        contrastEv: 0.8,
        shadowEv: 1.2,
        cameraLook: CameraLook.none,
      ).buildGainLut();
      for (var i = 0; i < Tone.gainEntries; i++) {
        expect(explicit[i], implicit[i], reason: 'entry $i');
      }
      // And the fast path is still exactly the identity when it should be.
      final neutral =
          Tone(greyPoint: 0.05, cameraLook: CameraLook.none).buildGainLut();
      for (final v in neutral) {
        expect(v, 1.0);
      }
    });

    test('L8 the all-ones fast path does not swallow the preset', () {
      // `!anyZone && slope == 1.0` is exactly a neutral edit with the preset
      // on. Without the `&& !hasLook` clause the table comes back all ones,
      // the preset does nothing, and L3–L6 all still pass because they test
      // the curve function rather than the table.
      final tone = Tone(greyPoint: 0.05, cameraLook: CameraLook.camera);
      final lut = tone.buildGainLut();
      var moved = 0;
      for (final v in lut) {
        if ((v - 1.0).abs() > 1e-6) moved++;
      }
      expect(moved, greaterThan(Tone.gainEntries ~/ 2),
          reason: 'the all-ones fast path swallowed the preset');

      // Populated is not enough: it must be populated the right way up.
      // displayScale is 3.6 here, so these are display-referred 0.01 and 0.5.
      double gainAt(double v) => lut[Tone.gainIndex(v / tone.displayScale)];
      expect(gainAt(0.01), lessThan(0.6), reason: 'shadows must darken');
      expect(gainAt(0.5), greaterThan(1.0), reason: 'midtones must lift');
    });

    test('L10 the look is applied after contrast, not before', () {
      // Invisible in any aggregate statistic, so it needs its own assertion:
      // the composed mapping is base(contrast(v)), never contrast(base(v)).
      final tone = Tone(
        greyPoint: 0.05,
        contrastEv: 2,
        cameraLook: CameraLook.camera,
      );
      final lut = tone.buildGainLut();
      final scale = tone.displayScale;
      for (final probe in [0.01, 0.05, 0.2]) {
        final i = Tone.gainIndex(probe);
        // The table entry is the midpoint of the range it covers, so the
        // expectation has to be evaluated at that same luminance.
        final t = (i + 0.5) / Tone.gainEntries;
        final y = t * t * Tone.gainYMax;
        final e = math.log(y) / math.ln2;
        final contrastOnly = math.pow(2.0, mapEv(tone, e) - e).toDouble();
        final v = y * contrastOnly * scale;
        final expected = contrastOnly * cameraLookCurve(v, tone.cameraLook.gain) / v;
        expect(lut[i], closeTo(expected, 1e-6), reason: 'at Y = $probe');

        // And the other order really is a different number, or the assertion
        // above would be satisfied by either.
        final looked = cameraLookCurve(y * scale, tone.cameraLook.gain) /
            (y * scale);
        final wrongWayRound = looked *
            math.pow(2.0, mapEv(tone, e + math.log(looked) / math.ln2) - e)
                .toDouble() /
            math.pow(2.0, math.log(looked) / math.ln2).toDouble();
        expect((wrongWayRound - expected).abs(), greaterThan(1e-3),
            reason: 'the two orders agree at Y = $probe, so this proves '
                'nothing');
      }
    });

    test('L11 the display scale is one number', () {
      final tone = Tone(greyPoint: 0.05, cameraLook: CameraLook.camera);
      expect(tone.displayScale, middleGrey / tone.greyPoint);

      // Display white, seen through the gain table: L3's base(1) == 1. Held to
      // the table's own resolution, which is about 0.003 EV per step.
      final white = 1 / tone.displayScale;
      expect(tone.buildGainLut()[Tone.gainIndex(white)], closeTo(1.0, 0.005));

      // And the display transform agrees about where that white is. If the two
      // stages ever used different scales the preset would target a different
      // white from the transform that follows it, and this is what says so.
      final disp = tone.buildDisplayLut(
          outMax: 255, entries: DisplayLut.previewEntries);
      final i = (math.sqrt(white) * disp.indexScale)
          .toInt()
          .clamp(0, disp.entries);
      expect(disp.asBytes[i], 255);
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
