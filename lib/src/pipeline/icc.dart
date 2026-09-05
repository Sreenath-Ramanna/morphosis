// lib/src/pipeline/icc.dart
//
// A minimal ICC v2.4 matrix/TRC display profile, built in Dart.
//
// Generated rather than shipped. Adobe RGB (1998) and ProPhoto/ROMM profile
// *files* are copyrighted and their redistribution terms are not
// MIT-compatible; a profile constructed from published primaries is not. It
// also means the profile is derived from the same matrices the render applies,
// so it describes the pixels that were actually written rather than a
// plausible neighbour of them.
//
// The profile honestly declares wide primaries with the sRGB transfer curve.
// That is what is true: `tone.dart` applies the IEC 61966-2-1 piecewise curve
// everywhere, preview and export alike, and the TRC here is sampled from that
// same function. A conforming reader handles the combination without
// complaint; a file claiming ProPhoto's gamma 1.8 would be a lie.

import 'dart:typed_data';

import '../ria/ria.dart';
import 'tone.dart';
import 'working_space.dart';

/// sRGB → XYZ(D50), the ICC specification's own sRGB colorants as columns.
///
/// D50 rather than D65 because that is the only PCS an ICC v2 display profile
/// has. Every colorant below is derived through this, so the chromatic
/// adaptation is already inside the numbers and no `chad` tag is needed.
const List<List<double>> xyzd50FromSrgb = [
  [0.436083, 0.385083, 0.143055],
  [0.222507, 0.716888, 0.060608],
  [0.013930, 0.097097, 0.714022],
];

/// The PCS illuminant, and the profile's white point: D50 as ICC encodes it.
const List<double> _d50 = [0.9642, 1.0, 0.8249];

/// Entries in the tone reproduction curve.
///
/// 1024 rather than a v4 parametric curve: every ICC v2 reader in existence
/// handles a sampled `curv`, and the table is checkable against the code that
/// produced it. It costs about 2.5 KB, which is nothing beside a 200 MB TIFF.
const int trcEntries = 1024;

final Map<int, Uint8List> _cache = {};

/// The ICC profile describing `space` with the pipeline's sRGB transfer curve.
///
/// Byte-identical between runs: the creation date is a fixed constant and the
/// tag table is written in a fixed order, so an export is reproducible.
Uint8List iccProfileFor(int space) =>
    _cache.putIfAbsent(space, () => _build(space));

String _describe(int space) {
  switch (space) {
    case RiaColorspace.srgb:
      return 'sRGB (Morphosis)';
    case RiaColorspace.adobe:
      return 'Adobe RGB primaries, sRGB TRC (Morphosis)';
    case RiaColorspace.wide:
      return 'Wide Gamut RGB primaries, sRGB TRC (Morphosis)';
    case RiaColorspace.prophoto:
      return 'ProPhoto RGB primaries, sRGB TRC (Morphosis)';
    case RiaColorspace.aces:
      return 'ACES primaries, sRGB TRC (Morphosis)';
  }
  // RIA_COLORSPACE_XYZ and RIA_COLORSPACE_RAW have no RGB primaries, so an
  // 'RGB ' matrix/TRC profile cannot describe them. Refused rather than
  // approximated: a file that says XYZ and carries RGB colorants is worse than
  // no file.
  throw ArgumentError.value(space, 'space', 'has no RGB matrix/TRC profile');
}

/// The three colorants, as XYZ(D50) columns.
///
/// `xyzd50FromSrgb · srgbFromWorking(space)` is `space → XYZ(D50)`, whose
/// columns are the primaries. Derived, never tabulated: a tabulated colorant
/// can disagree with the matrix the render applied, and nothing would say so.
List<List<double>> _colorants(int space) =>
    mul3(xyzd50FromSrgb, srgbFromWorking(space));

Uint8List _build(int space) {
  final desc = _describe(space);
  final m = _colorants(space);

  final tags = <_Tag>[
    _Tag('desc', _textDescription(desc)),
    _Tag('cprt', _text('Public domain. Built from published primaries.')),
    _Tag('wtpt', _xyz(_d50[0], _d50[1], _d50[2])),
    _Tag('rXYZ', _xyz(m[0][0], m[1][0], m[2][0])),
    _Tag('gXYZ', _xyz(m[0][1], m[1][1], m[2][1])),
    _Tag('bXYZ', _xyz(m[0][2], m[1][2], m[2][2])),
  ];

  // One `curv` element, referenced by all three channel tags. The pipeline
  // applies one curve to all three, and three copies of the same 2 KB table
  // would be three chances for them to disagree.
  final curv = _curve();

  const headerSize = 128;
  final tagCount = tags.length + 3;
  final tableSize = 4 + tagCount * 12;
  var offset = headerSize + tableSize;

  final placed = <String, (int, int)>{};
  for (final t in tags) {
    placed[t.sig] = (offset, t.bytes.length);
    offset += _align4(t.bytes.length);
  }
  final trcOffset = offset;
  offset += _align4(curv.length);
  final total = offset;

  final out = Uint8List(total);
  final bd = ByteData.view(out.buffer);

  void ascii(int at, String s4) {
    for (var i = 0; i < 4; i++) {
      out[at + i] = s4.codeUnitAt(i);
    }
  }

  // ── Header ──────────────────────────────────────────────────────────────
  bd.setUint32(0, total);
  ascii(4, 'none'); // preferred CMM: none in particular
  bd.setUint32(8, 0x02400000); // v2.4
  ascii(12, 'mntr'); // display device
  ascii(16, 'RGB ');
  ascii(20, 'XYZ ');
  // A fixed creation date, so two runs produce equal bytes.
  bd.setUint16(24, 2026);
  bd.setUint16(26, 1);
  bd.setUint16(28, 1);
  bd.setUint16(30, 0);
  bd.setUint16(32, 0);
  bd.setUint16(34, 0);
  ascii(36, 'acsp');
  // Platform, flags, manufacturer, model, attributes and rendering intent all
  // stay zero: nothing here is platform-specific, and perceptual (0) is the
  // right default for a photograph.
  bd.setInt32(68, _s15(_d50[0]));
  bd.setInt32(72, _s15(_d50[1]));
  bd.setInt32(76, _s15(_d50[2]));
  // Creator, profile ID and the reserved block stay zero.

  // ── Tag table ───────────────────────────────────────────────────────────
  var p = headerSize;
  bd.setUint32(p, tagCount);
  p += 4;
  void entry(String sig, int off, int size) {
    ascii(p, sig);
    bd.setUint32(p + 4, off);
    bd.setUint32(p + 8, size);
    p += 12;
  }

  for (final t in tags) {
    final (off, size) = placed[t.sig]!;
    entry(t.sig, off, size);
  }
  entry('rTRC', trcOffset, curv.length);
  entry('gTRC', trcOffset, curv.length);
  entry('bTRC', trcOffset, curv.length);

  // ── Tag data ────────────────────────────────────────────────────────────
  for (final t in tags) {
    out.setRange(placed[t.sig]!.$1, placed[t.sig]!.$1 + t.bytes.length,
        t.bytes);
  }
  out.setRange(trcOffset, trcOffset + curv.length, curv);

  return out;
}

class _Tag {
  final String sig;
  final Uint8List bytes;
  const _Tag(this.sig, this.bytes);
}

int _align4(int n) => (n + 3) & ~3;

/// s15Fixed16Number, the only numeric type an ICC v2 XYZ tag has.
int _s15(double v) => (v * 65536.0).round();

Uint8List _xyz(double x, double y, double z) {
  final out = Uint8List(20);
  final bd = ByteData.view(out.buffer);
  for (var i = 0; i < 4; i++) {
    out[i] = 'XYZ '.codeUnitAt(i);
  }
  bd.setInt32(8, _s15(x));
  bd.setInt32(12, _s15(y));
  bd.setInt32(16, _s15(z));
  return out;
}

/// `textType` — signature, reserved, then NUL-terminated ASCII.
Uint8List _text(String s) {
  final out = Uint8List(8 + s.length + 1);
  for (var i = 0; i < 4; i++) {
    out[i] = 'text'.codeUnitAt(i);
  }
  for (var i = 0; i < s.length; i++) {
    out[8 + i] = s.codeUnitAt(i);
  }
  return out;
}

/// `textDescriptionType` — the v2 profile description, with its empty Unicode
/// and ScriptCode halves. Both are required to be present even when unused.
Uint8List _textDescription(String s) {
  final ascii = s.length + 1;
  final out = Uint8List(12 + ascii + 4 + 4 + 2 + 1 + 67);
  final bd = ByteData.view(out.buffer);
  for (var i = 0; i < 4; i++) {
    out[i] = 'desc'.codeUnitAt(i);
  }
  bd.setUint32(8, ascii);
  for (var i = 0; i < s.length; i++) {
    out[12 + i] = s.codeUnitAt(i);
  }
  // Unicode language code, Unicode count, ScriptCode code, count and the
  // 67-byte ScriptCode buffer all stay zero.
  return out;
}

/// `curveType`, sampled from the pipeline's own transfer function.
///
/// A TRC maps a device value to linear, so this is [srgbDecode], not
/// [srgbEncode]. Written the other way round the file opens fine everywhere
/// and looks wrong everywhere, which is why `icc_test.dart` checks the
/// direction by round-tripping through `srgbEncode`.
Uint8List _curve() {
  final out = Uint8List(12 + trcEntries * 2);
  final bd = ByteData.view(out.buffer);
  for (var i = 0; i < 4; i++) {
    out[i] = 'curv'.codeUnitAt(i);
  }
  bd.setUint32(8, trcEntries);
  for (var i = 0; i < trcEntries; i++) {
    final v = srgbDecode(i / (trcEntries - 1));
    bd.setUint16(12 + i * 2, (v * 65535.0).round().clamp(0, 65535));
  }
  return out;
}
