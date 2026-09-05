// test/pipeline/icc_test.dart
//
// The generated ICC profile, checked as a container and as a description of
// the pixels — without an ICC library, because there is none in the dependency
// set and adding one to check 2.5 KB of our own output would be circular.
//
// The matrices come from C in production; here they come from the same LibRaw
// table `working_space_test.dart` records, so this runs in CI.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:morphosis/src/pipeline/icc.dart';
import 'package:morphosis/src/pipeline/tone.dart';
import 'package:morphosis/src/pipeline/working_space.dart';
import 'package:morphosis/src/ria/ria.dart';

import 'working_space_test.dart' show libRawTable, rgbSpaces;

String _sig(ByteData bd, int at) => String.fromCharCodes(
    [for (var i = 0; i < 4; i++) bd.getUint8(at + i)]);

double _s15(ByteData bd, int at) => bd.getInt32(at) / 65536.0;

class _Tags {
  final Map<String, (int, int)> bySig;
  const _Tags(this.bySig);

  static _Tags of(Uint8List p) {
    final bd = ByteData.view(p.buffer, p.offsetInBytes, p.length);
    final count = bd.getUint32(128);
    final out = <String, (int, int)>{};
    for (var i = 0; i < count; i++) {
      final at = 132 + i * 12;
      out[_sig(bd, at)] = (bd.getUint32(at + 4), bd.getUint32(at + 8));
    }
    return _Tags(out);
  }
}

List<double> _xyzTag(Uint8List p, String sig) {
  final bd = ByteData.view(p.buffer, p.offsetInBytes, p.length);
  final (off, _) = _Tags.of(p).bySig[sig]!;
  expect(_sig(bd, off), 'XYZ ');
  return [_s15(bd, off + 8), _s15(bd, off + 12), _s15(bd, off + 16)];
}

void main() {
  setUp(() {
    colorspaceMatrixSource = (space) => libRawTable[space]!;
    resetWorkingSpaceCache();
  });

  tearDown(() {
    colorspaceMatrixSource = Ria.colorspaceFromSrgb;
    resetWorkingSpaceCache();
  });

  group('the container', () {
    test('I1 it is a well-formed ICC v2.4 display profile', () {
      for (final space in rgbSpaces) {
        final p = iccProfileFor(space);
        final bd = ByteData.view(p.buffer, p.offsetInBytes, p.length);

        expect(bd.getUint32(0), p.length,
            reason: 'the header size field is the buffer length');
        expect(_sig(bd, 36), 'acsp', reason: 'the profile file signature');
        expect(bd.getUint32(8), 0x02400000, reason: 'v2.4');
        expect(_sig(bd, 12), 'mntr', reason: 'a display device profile');
        expect(_sig(bd, 16), 'RGB ');
        expect(_sig(bd, 20), 'XYZ ', reason: 'the PCS');
        // The PCS illuminant is fixed by the specification at D50.
        expect(_s15(bd, 68), closeTo(0.9642, 1e-4));
        expect(_s15(bd, 72), closeTo(1.0, 1e-4));
        expect(_s15(bd, 76), closeTo(0.8249, 1e-4));

        final count = bd.getUint32(128);
        final tags = _Tags.of(p);
        expect(tags.bySig.length, count,
            reason: 'the tag count matches the table');
        expect(
            tags.bySig.keys,
            containsAll(<String>[
              'desc', 'cprt', 'wtpt', 'rXYZ', 'gXYZ', 'bXYZ', //
              'rTRC', 'gTRC', 'bTRC',
            ]));

        for (final e in tags.bySig.entries) {
          final (off, size) = e.value;
          expect(off % 4, 0, reason: '${e.key} starts on a word boundary');
          expect(off, greaterThanOrEqualTo(132 + count * 12));
          expect(off + size, lessThanOrEqualTo(p.length),
              reason: '${e.key} lies inside the buffer');
        }
      }
    });

    test('I6 two runs produce equal bytes', () {
      for (final space in rgbSpaces) {
        final a = iccProfileFor(space);
        resetWorkingSpaceCache();
        // A fresh build, not the memo — the memo would prove nothing.
        final b = Uint8List.fromList(iccProfileFor(space));
        expect(a, b, reason: 'no timestamps, no map iteration order');
      }
    });

    test('I7 the three TRC tags share one element', () {
      final tags = _Tags.of(iccProfileFor(RiaColorspace.prophoto)).bySig;
      expect(tags['rTRC'], tags['gTRC']);
      expect(tags['gTRC'], tags['bTRC']);
    });
  });

  group('the colorants', () {
    test('I2 they add up to the white point', () {
      for (final space in rgbSpaces) {
        final p = iccProfileFor(space);
        final w = _xyzTag(p, 'wtpt');
        final r = _xyzTag(p, 'rXYZ');
        final g = _xyzTag(p, 'gXYZ');
        final b = _xyzTag(p, 'bXYZ');
        for (var i = 0; i < 3; i++) {
          // A transposed colorant matrix passes every "a grey stays grey"
          // property there is; this is what sees it.
          expect(r[i] + g[i] + b[i], closeTo(w[i], 2e-4),
              reason: 'space $space, component $i');
        }
      }
    });

    test('I3 the sRGB profile carries the published sRGB colorants', () {
      // The ICC specification's own sRGB red colorant — an external oracle,
      // not our own output, which is what makes a literal justified here.
      final r = _xyzTag(iccProfileFor(RiaColorspace.srgb), 'rXYZ');
      expect(r[0], closeTo(0.436083, 1e-4));
      expect(r[1], closeTo(0.222507, 1e-4));
      expect(r[2], closeTo(0.013930, 1e-4));
    });

    test('a space with no RGB primaries is refused, not approximated', () {
      expect(() => iccProfileFor(RiaColorspace.xyz), throwsArgumentError);
      expect(() => iccProfileFor(RiaColorspace.raw), throwsArgumentError);
    });

    test('a wide profile is not the sRGB one', () {
      final s = _xyzTag(iccProfileFor(RiaColorspace.srgb), 'rXYZ');
      final w = _xyzTag(iccProfileFor(RiaColorspace.prophoto), 'rXYZ');
      // ProPhoto's red primary is far outside sRGB's; if these ever agree the
      // profile has stopped describing the pixels the decode produced.
      expect((w[0] - s[0]).abs(), greaterThan(0.2));
    });
  });

  group('the tone curve', () {
    List<int> curve(int space) {
      final p = iccProfileFor(space);
      final bd = ByteData.view(p.buffer, p.offsetInBytes, p.length);
      final (off, _) = _Tags.of(p).bySig['rTRC']!;
      expect(_sig(bd, off), 'curv');
      final n = bd.getUint32(off + 8);
      return [for (var i = 0; i < n; i++) bd.getUint16(off + 12 + i * 2)];
    }

    test('I4 it is the curve the pipeline actually applies', () {
      final t = curve(RiaColorspace.prophoto);
      expect(t.length, trcEntries);
      for (var s = 0; s < 32; s++) {
        final i = (s * (t.length - 1) / 31).round();
        // A TRC maps a device value to linear. Written in the encode direction
        // instead, the file opens fine everywhere and looks wrong everywhere.
        expect(srgbEncode(t[i] / 65535.0), closeTo(i / (t.length - 1), 1.5 / 1023),
            reason: 'entry $i');
      }
    });

    test('I5 it is monotonic and spans the range', () {
      final t = curve(RiaColorspace.srgb);
      expect(t.first, 0);
      expect(t.last, 65535);
      for (var i = 1; i < t.length; i++) {
        expect(t[i], greaterThanOrEqualTo(t[i - 1]));
      }
    });
  });
}
