// test/render_test.dart
//
// The fused render pass and the file writers, on synthetic frames.

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:morphosis/src/pipeline/export.dart';
import 'package:morphosis/src/pipeline/render.dart';
import 'package:morphosis/src/pipeline/tone.dart';

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

void main() {
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
        final lin = [for (final v in out) _srgbDecode(v / 65535)];
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

  group('zone histogram', () {
    test('finds the percentile of a known ramp', () {
      const n = 4096;
      final zh = ZoneHistogram.compute(rampFrame(n), n, 1);
      expect(zh.pixels, n);
      // The ramp is uniform in EV over [−14, 0], so the median sits at −7.
      expect(zh.medianEv, closeTo(-7.0, 0.4));
    });

    test('the auto grey point places the top of the frame at display white',
        () {
      const n = 4096;
      final zh = ZoneHistogram.compute(rampFrame(n), n, 1);
      final grey = zh.autoGreyPoint();
      final displayWhite = grey / 0.18;
      // p99.5 of a −14…0 EV ramp is about −0.07 EV, i.e. just under 1.0.
      expect(displayWhite, inInclusiveRange(0.8, 1.05));
    });

    test('an all-black frame does not produce a degenerate grey point', () {
      final zh = ZoneHistogram.compute(Uint16List(300), 100, 1);
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
}

double _srgbDecode(double v) {
  if (v <= 0) return 0;
  if (v >= 1) return 1;
  return v <= 0.04045 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
}
