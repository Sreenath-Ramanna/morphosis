// test/geometry_test.dart
//
// Rotation and crop: the value type, and the resampling that applies it.

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:morphosis/src/model/geometry.dart';
import 'package:morphosis/src/pipeline/geometry_ops.dart';
import 'package:morphosis/src/ria/ria.dart';

/// A frame whose every pixel encodes its own coordinates, so a resample can be
/// checked by reading the answer rather than by comparing to a fixture.
SceneImage coordinateFrame(int w, int h) {
  final data = Uint16List(w * h * 3);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final i = (y * w + x) * 3;
      data[i] = x;
      data[i + 1] = y;
      data[i + 2] = 1000;
    }
  }
  return SceneImage(data, w, h);
}

(int, int) pixelAt(SceneImage img, int x, int y) {
  final i = (y * img.width + x) * 3;
  return (img.data[i], img.data[i + 1]);
}

void main() {
  group('output size', () {
    test('quarter turns transpose it', () {
      const g = Geometry(quarterTurns: 1);
      expect(g.outputSize(600, 400), (400, 600));
      expect(const Geometry(quarterTurns: 2).outputSize(600, 400), (600, 400));
      expect(const Geometry(quarterTurns: 3).outputSize(600, 400), (400, 600));
    });

    test('a crop scales it', () {
      const g = Geometry(crop: CropRect(0.25, 0.0, 0.75, 0.5));
      expect(g.outputSize(600, 400), (300, 200));
    });

    test('a crop of a turned frame is measured against the turned frame', () {
      const g =
          Geometry(quarterTurns: 1, crop: CropRect(0, 0, 0.5, 1));
      // Rotated frame is 400x600; half its width is 200.
      expect(g.outputSize(600, 400), (200, 600));
    });
  });

  group('identity', () {
    test('is recognised, and passes the buffer straight through', () {
      final src = coordinateFrame(8, 6);
      final out = applyGeometry(src, Geometry.identity);
      expect(identical(out, src), isTrue,
          reason: 'the common path must not copy');
    });

    test('four quarter turns come back to the start', () {
      final src = coordinateFrame(9, 5);
      var img = src;
      for (var i = 0; i < 4; i++) {
        img = applyGeometry(img, const Geometry(quarterTurns: 1));
      }
      expect(img.width, src.width);
      expect(img.height, src.height);
      expect(img.data, src.data);
    });
  });

  group('rotation', () {
    test('90 degrees clockwise moves the top-left corner to the top-right',
        () {
      final src = coordinateFrame(4, 3);
      final out = applyGeometry(src, const Geometry(quarterTurns: 1));
      expect((out.width, out.height), (3, 4));

      // Source (0,0) must end up at the top-right of the result.
      expect(pixelAt(out, out.width - 1, 0), (0, 0));
      // Source (3,0) — top-right — ends at bottom-right.
      expect(pixelAt(out, out.width - 1, out.height - 1), (3, 0));
      // Source (0,2) — bottom-left — ends at top-left.
      expect(pixelAt(out, 0, 0), (0, 2));
    });

    test('180 degrees reverses both axes', () {
      final src = coordinateFrame(4, 3);
      final out = applyGeometry(src, const Geometry(quarterTurns: 2));
      expect(pixelAt(out, 0, 0), (3, 2));
      expect(pixelAt(out, 3, 2), (0, 0));
    });

    test('a quarter turn loses nothing — every source pixel appears once', () {
      final src = coordinateFrame(7, 5);
      final out = applyGeometry(src, const Geometry(quarterTurns: 3));
      final seen = <int>{};
      for (var y = 0; y < out.height; y++) {
        for (var x = 0; x < out.width; x++) {
          final (sx, sy) = pixelAt(out, x, y);
          expect(seen.add(sy * 7 + sx), isTrue, reason: 'duplicate ($sx,$sy)');
        }
      }
      expect(seen.length, 35);
    });
  });

  group('crop', () {
    test('takes the requested region', () {
      final src = coordinateFrame(100, 100);
      final out =
          applyGeometry(src, const Geometry(crop: CropRect(0.2, 0.4, 0.6, 0.8)));
      expect((out.width, out.height), (40, 40));
      // First output pixel is around source (20, 40).
      final (x, y) = pixelAt(out, 0, 0);
      expect(x, closeTo(20, 1));
      expect(y, closeTo(40, 1));
    });

    test('composes with a rotation', () {
      final src = coordinateFrame(100, 60);
      // Rotated frame is 60x100; the left half of it is the top half of the
      // source, read bottom-to-top.
      final out = applyGeometry(
          src, const Geometry(quarterTurns: 1, crop: CropRect(0, 0, 1, 0.5)));
      expect((out.width, out.height), (60, 50));
    });
  });

  group('straighten', () {
    test('bounds shrink as the angle grows, and are symmetric in sign', () {
      const base = Geometry();
      expect(base.straightenBounds(600, 400), CropRect.full);

      double area(double deg) {
        final b = Geometry(straightenDegrees: deg).straightenBounds(600, 400);
        return b.width * b.height;
      }

      expect(area(5), lessThan(1.0));
      expect(area(10), lessThan(area(5)));
      expect(area(15), lessThan(area(10)));
      expect(area(-8), closeTo(area(8), 1e-9));
      expect(area(15), greaterThan(0.3),
          reason: 'the maximum angle must still leave a usable frame');
    });

    test('the inscribed rectangle really is inside the rotated frame', () {
      // Every corner of the bounds, rotated back, must land within the source.
      const w = 600.0, h = 400.0;
      for (final deg in [3.0, 7.0, 12.0, 15.0]) {
        final b = Geometry(straightenDegrees: deg).straightenBounds(600, 400);
        final a = -deg * math.pi / 180.0;
        final cosA = math.cos(a), sinA = math.sin(a);
        for (final corner in [
          [b.left, b.top],
          [b.right, b.top],
          [b.left, b.bottom],
          [b.right, b.bottom],
        ]) {
          final x = corner[0] * w - w / 2;
          final y = corner[1] * h - h / 2;
          final rx = cosA * x - sinA * y + w / 2;
          final ry = sinA * x + cosA * y + h / 2;
          expect(rx, greaterThanOrEqualTo(-0.5), reason: 'at $deg deg');
          expect(rx, lessThanOrEqualTo(w + 0.5), reason: 'at $deg deg');
          expect(ry, greaterThanOrEqualTo(-0.5), reason: 'at $deg deg');
          expect(ry, lessThanOrEqualTo(h + 0.5), reason: 'at $deg deg');
        }
      }
    });

    test('resampling a flat field leaves it flat', () {
      // Bilinear weights sum to one, so a constant image must survive
      // rotation unchanged. Catches a normalisation error that a photograph
      // would only show as a faint darkening.
      const n = 64;
      final data = Uint16List(n * n * 3);
      for (var i = 0; i < data.length; i++) {
        data[i] = 30000;
      }
      final src = SceneImage(data, n, n);
      final out = applyGeometry(
          src,
          const Geometry(
              straightenDegrees: 7, crop: CropRect(0.2, 0.2, 0.8, 0.8)));
      for (var i = 0; i < out.data.length; i++) {
        expect(out.data[i], closeTo(30000, 1));
      }
    });

    test('a horizontal gradient stays monotonic through a small rotation', () {
      const n = 128;
      final data = Uint16List(n * n * 3);
      for (var y = 0; y < n; y++) {
        for (var x = 0; x < n; x++) {
          final i = (y * n + x) * 3;
          data[i] = data[i + 1] = data[i + 2] = (x * 500).clamp(0, 65535);
        }
      }
      final out = applyGeometry(
          SceneImage(data, n, n),
          const Geometry(
              straightenDegrees: 4, crop: CropRect(0.25, 0.25, 0.75, 0.75)));
      final row = out.height ~/ 2;
      var previous = -1;
      for (var x = 0; x < out.width; x++) {
        final v = out.data[(row * out.width + x) * 3];
        expect(v, greaterThanOrEqualTo(previous - 1));
        previous = v;
      }
    });
  });

  group('rotating the crop with the frame', () {
    test('a corner crop stays on the same corner of the picture', () {
      // Crop the top-left quarter, then turn the frame clockwise: that region
      // is now the top-right quarter, and the rectangle must follow it.
      const g = Geometry(crop: CropRect(0, 0, 0.5, 0.5));
      final turned = g.rotatedClockwise();
      expect(turned.quarterTurns, 1);
      expect(turned.crop, const CropRect(0.5, 0, 1.0, 0.5));
    });

    test('four turns return the crop unchanged', () {
      const start = Geometry(crop: CropRect(0.1, 0.2, 0.7, 0.9));
      var g = start;
      for (var i = 0; i < 4; i++) {
        g = g.rotatedClockwise();
      }
      expect(g.quarterTurns, 0);
      expect(g.crop.left, closeTo(start.crop.left, 1e-12));
      expect(g.crop.top, closeTo(start.crop.top, 1e-12));
      expect(g.crop.right, closeTo(start.crop.right, 1e-12));
      expect(g.crop.bottom, closeTo(start.crop.bottom, 1e-12));
    });

    test('turning one way then the other is the identity', () {
      const start = Geometry(crop: CropRect(0.1, 0.2, 0.7, 0.9));
      final there = start.rotatedClockwise().rotatedAnticlockwise();
      expect(there.quarterTurns, 0);
      expect(there.crop.left, closeTo(start.crop.left, 1e-12));
      expect(there.crop.bottom, closeTo(start.crop.bottom, 1e-12));
    });
  });

  group('fitting a crop inside bounds', () {
    test('an oversized crop is pulled in', () {
      const bounds = CropRect(0.1, 0.1, 0.9, 0.9);
      final fitted = CropRect.full.fittedInside(bounds);
      expect(fitted, bounds);
    });

    test('a crop already inside is untouched', () {
      const bounds = CropRect(0.1, 0.1, 0.9, 0.9);
      const inner = CropRect(0.2, 0.3, 0.6, 0.7);
      expect(inner.fittedInside(bounds), inner);
    });

    test('a crop clamped to nothing falls back to the bounds', () {
      const bounds = CropRect(0.4, 0.4, 0.6, 0.6);
      const outside = CropRect(0.0, 0.0, 0.05, 0.05);
      expect(outside.fittedInside(bounds), bounds);
    });
  });

  group('aspect options', () {
    test('original resolves to the frame ratio, free to nothing', () {
      expect(AspectOption.original.resolve(1.5), 1.5);
      expect(AspectOption.free.resolve(1.5), isNull);
      expect(AspectOption.all[2].resolve(1.5), 1.0);
    });
  });
}
