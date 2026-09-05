// lib/src/ria/ria.dart
//
// A thin Dart layer over the raw_images_api FFI bindings: where the .so lives,
// how a RAW file is opened and decoded, and the two things every RAW in the
// folder list needs — its metadata and its embedded preview.
//
// Everything here is synchronous and blocking. Callers run it inside an
// isolate; nothing in this file touches the UI.

import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'bindings.dart';

export 'bindings.dart'
    show
        RiaColorspace,
        RiaDemosaic,
        RiaFlip,
        RiaFormat,
        RiaStatus,
        RiaTransfer,
        riaPreviewJpeg;

/// Thrown when a library call fails. Carries the `ria_status` so a caller can
/// distinguish "not a RAW file" from "out of memory".
class RiaException implements Exception {
  final String call;
  final int status;
  final String message;

  RiaException(this.call, this.status, this.message);

  @override
  String toString() => '$call failed: $message ($status)';
}

/// Where `libraw_images_api.so` is, and the one `RiaLib` per isolate.
class Ria {
  static RiaLib? _lib;

  /// Overrides the .so location. Set from the main isolate before any decode,
  /// and passed explicitly to workers — a static in one isolate is invisible
  /// to another.
  static String? libraryPathOverride;

  /// The bundle layout `linux/CMakeLists.txt` installs: the executable at the
  /// bundle root, its libraries in `lib/` beside it.
  static String resolveLibraryPath() {
    final override = libraryPathOverride;
    if (override != null) return override;
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    return '$exeDir/lib/libraw_images_api.so';
  }

  static RiaLib lib([String? soPath]) =>
      _lib ??= RiaLib.open(soPath ?? resolveLibraryPath());

  /// The 3x3 converting linear sRGB to `space`, row-major, as the decode
  /// applied it — `ria_colorspace_from_srgb`.
  ///
  /// The table lives in C because C is what builds against LibRaw, and a
  /// second hand-mirrored copy of a LibRaw internal in Dart is the thing this
  /// call exists to avoid. Callers should go through
  /// `pipeline/working_space.dart`, which caches it per isolate.
  static List<double> colorspaceFromSrgb(int space) {
    final m = calloc<Float>(9);
    try {
      _check('ria_colorspace_from_srgb', lib().colorspaceFromSrgb(space, m));
      return [for (var i = 0; i < 9; i++) m[i]];
    } finally {
      calloc.free(m);
    }
  }

  /// True for extensions LibRaw is likely to handle. Used to filter a folder
  /// listing without opening every file in it.
  static bool isRawFile(String path) {
    final p = path.toNativeUtf8();
    try {
      return lib().isRawExtension(p) != 0;
    } finally {
      calloc.free(p);
    }
  }
}

void _check(String call, int status) {
  if (status != RiaStatus.ok) {
    throw RiaException(call, status, Ria.lib().describe(status));
  }
}

// ── Value types crossing the isolate boundary ─────────────────────────────

/// Camera and exposure data, flattened out of `ria_metadata`.
class RawMetadata {
  final String make;
  final String model;
  final String lens;
  final double isoSpeed;
  final double shutter;
  final double aperture;
  final double focalLen;

  /// As displayed — already transposed for portrait frames.
  final int width;
  final int height;

  /// When the photograph was taken, or null when the file says nothing.
  ///
  /// `ria_metadata.timestamp` is Unix seconds and the C library zero-fills the
  /// struct on a failed read, so 0 is converted to null here rather than to
  /// 1970 — which is not a plausible capture date for a RAW file, and would
  /// sort a whole folder of unknowns to the top of any date search.
  final DateTime? capturedAt;

  const RawMetadata({
    required this.make,
    required this.model,
    required this.lens,
    required this.isoSpeed,
    required this.shutter,
    required this.aperture,
    required this.focalLen,
    required this.width,
    required this.height,
    this.capturedAt,
  });

  static const String unknown = '—';

  static bool _usable(double v) => v.isFinite && v > 0;

  String get camera {
    final name = '$make $model'.trim();
    return name.isEmpty ? unknown : name;
  }

  String get shutterText {
    if (!_usable(shutter)) return unknown;
    if (shutter >= 1) return '${shutter.toStringAsFixed(1)} s';
    return '1/${(1 / shutter).round()} s';
  }

  String get apertureText =>
      _usable(aperture) ? 'f/${aperture.toStringAsFixed(1)}' : unknown;

  String get isoText => _usable(isoSpeed) ? 'ISO ${isoSpeed.round()}' : unknown;

  String get focalText =>
      _usable(focalLen) ? '${focalLen.round()} mm' : unknown;

  String get sizeText =>
      (width > 0 && height > 0) ? '$width × $height' : unknown;
}

/// The inputs to a colour temperature calculation, copied out of
/// `ria_color_data` so they can be sent between isolates.
class RawColorData {
  /// As-shot multipliers, normalised so green is 1.
  final List<double> camMul;

  /// XYZ(D65) → camera, 3×3 leading block.
  final List<List<double>> camXyz;

  /// The camera's own Kelvin → multiplier table, empty when the body does not
  /// record one. Rows are `[kelvin, r, g, b]`, normalised so green is 1.
  final List<List<double>> wbct;

  const RawColorData({
    required this.camMul,
    required this.camXyz,
    required this.wbct,
  });
}

/// A decoded, scene-referred linear frame, as a Dart-owned buffer.
///
/// `data` is 16-bit RGB where 1.0 (65535) is sensor saturation — the domain
/// every EV-denominated control in this app works in. It is never written
/// back to disk and never modified in place.
class SceneImage {
  final Uint16List data;
  final int width;
  final int height;

  /// `ria_image.saturation_level`: the sample value that is sensor
  /// saturation, in these units. 1.0 unless highlight reconstruction rescaled
  /// the frame, and below 1.0 when it did.
  ///
  /// Every EV computation divides by it. The pixels are left alone — a 16-bit
  /// buffer multiplied back to the anchor re-clips exactly the highlights the
  /// reconstruction recovered.
  final double saturationScale;

  /// `ria_image.colorspace`: the primaries `data` is expressed in, as a
  /// `RiaColorspace` value.
  final int colorspace;

  const SceneImage(
    this.data,
    this.width,
    this.height, {
    this.saturationScale = 1.0,
    this.colorspace = RiaColorspace.srgb,
  });

  int get pixels => width * height;
}

/// The camera's own JPEG rendering, as stored in the file.
class EmbeddedPreview {
  final Uint8List bytes;
  final int flip;

  const EmbeddedPreview(this.bytes, this.flip);
}

// ── Operations ────────────────────────────────────────────────────────────

/// An open RAW file. Close it, or LibRaw keeps the mapping alive.
class RawFile {
  final Pointer<RiaRaw> _handle;
  bool _closed = false;

  RawFile._(this._handle);

  factory RawFile.open(String path) {
    final lib = Ria.lib();
    final out = calloc<Pointer<RiaRaw>>();
    final p = path.toNativeUtf8();
    try {
      _check('ria_raw_open', lib.rawOpen(p, out));
      return RawFile._(out.value);
    } finally {
      calloc.free(p);
      calloc.free(out);
    }
  }

  void close() {
    if (_closed) return;
    _closed = true;
    Ria.lib().rawClose(_handle);
  }

  RawMetadata metadata() {
    final m = calloc<RiaMetadata>();
    try {
      _check('ria_raw_metadata', Ria.lib().rawMetadata(_handle, m));
      final r = m.ref;
      return RawMetadata(
        make: _str(r.make, 64),
        model: _str(r.model, 64),
        lens: _str(r.lens, 128),
        isoSpeed: r.isoSpeed,
        shutter: r.shutter,
        aperture: r.aperture,
        focalLen: r.focalLen,
        width: r.width,
        height: r.height,
        // The one boundary where a stored instant becomes a DateTime. UTC
        // here, local only where it is drawn — PLAN.md section 12.
        capturedAt: r.timestamp > 0
            ? DateTime.fromMillisecondsSinceEpoch(r.timestamp * 1000,
                isUtc: true)
            : null,
      );
    } finally {
      calloc.free(m);
    }
  }

  RawColorData colorData() {
    final c = calloc<RiaColorData>();
    try {
      _check('ria_raw_color_data', Ria.lib().rawColorData(_handle, c));
      final r = c.ref;

      // Normalise to green so the ratios are comparable with the camera
      // table, which is stored that way. Canon writes raw sensor counts here
      // (1967/1024/1606), Nikon writes ratios; dividing removes the
      // difference.
      final g = r.camMul[1] != 0 ? r.camMul[1] : 1.0;
      final camMul = [
        r.camMul[0] / g,
        1.0,
        r.camMul[2] / g,
      ];

      final camXyz = [
        for (var i = 0; i < 3; i++)
          [for (var j = 0; j < 3; j++) r.camXyz[i][j].toDouble()],
      ];

      final wbct = <List<double>>[];
      for (var i = 0; i < r.wbctRows; i++) {
        final row = r.wbct[i];
        final rg = row[2] != 0 ? row[2] : 1.0;
        wbct.add([row[0], row[1] / rg, 1.0, row[3] / rg]);
      }

      return RawColorData(camMul: camMul, camXyz: camXyz, wbct: wbct);
    } finally {
      calloc.free(c);
    }
  }

  /// The embedded JPEG, when there is one. A file read and a memcpy against
  /// seconds for a demosaic, which is why the folder list uses it.
  EmbeddedPreview? preview() {
    final lib = Ria.lib();
    final out = calloc<Pointer<RiaPreview>>();
    try {
      final rc = lib.rawPreview(_handle, out);
      if (rc != RiaStatus.ok) return null;
      final p = out.value;
      try {
        if (p.ref.format != riaPreviewJpeg || p.ref.dataSize == 0) return null;
        // Copy: the bytes belong to LibRaw and are freed below.
        final bytes = Uint8List.fromList(
            p.ref.data.asTypedList(p.ref.dataSize));
        return EmbeddedPreview(bytes, p.ref.flip);
      } finally {
        lib.previewFree(p);
      }
    } finally {
      calloc.free(out);
    }
  }

  /// Decode to scene-referred linear 16-bit RGB, orientation baked in.
  ///
  /// `ria_decode_options_scene_linear` with three fields overridden:
  /// `demosaic`, `highlightMode` and `outputColor`. Gamma 1.0, 16-bit and no
  /// auto-brightness are the preset's, and they are what make 1.0 mean sensor
  /// saturation — and therefore what make the EV controls mean the same thing
  /// on every file.
  ///
  /// `highlightMode` above 0 asks LibRaw to reconstruct clipped highlights.
  /// LibRaw then rescales the whole frame, and the applied scale comes back on
  /// [SceneImage.saturationScale]: divide by it before taking log2 and the EV
  /// scale is anchored to saturation whatever the mode was. At mode 0 it is
  /// exactly 1.0, so the existing path does not move.
  ///
  /// `outputColor` chooses the primaries. Anything wider than sRGB stops the
  /// gamut clip that otherwise happens inside `dcraw_process`, which is where
  /// a saturated red loses its gradation.
  ///
  /// `maxEdge` shrinks the result with `ria_fit_within` after the decode,
  /// which is how the editing preview stays interactive. Resampling here is
  /// resampling *linear* light, which is the correct place for it.
  ///
  /// `demosaic` defaults to the library's own preview-grade choice, so a
  /// caller pays the cost of a better algorithm only by asking for it. The
  /// choice does not disturb the scene-referred preset: measured across both
  /// bodies in `test-images/`, every algorithm lands the median within 0.001
  /// EV of the others, so a preview and an export decoded differently still
  /// agree about what an EV means.
  SceneImage decodeSceneLinear({
    int? maxEdge,
    bool halfSize = false,
    int demosaic = RiaDemosaic.ppg,
    int highlightMode = 0,
    int outputColor = RiaColorspace.srgb,
  }) {
    final lib = Ria.lib();
    final opt = calloc<RiaDecodeOptions>();
    final out = calloc<Pointer<RiaImage>>();
    try {
      lib.decodeOptionsSceneLinear(opt);
      opt.ref.demosaic = demosaic;
      opt.ref.highlightMode = highlightMode;
      opt.ref.outputColor = outputColor;
      opt.ref.halfSize = halfSize ? 1 : 0;
      opt.ref.applyOrientation = 1;
      opt.ref.userFlip = -1;
      opt.ref.alpha = 0;

      _check('ria_raw_decode', lib.rawDecode(_handle, opt, out));
      var img = out.value;

      try {
        if (maxEdge != null && (img.ref.width > maxEdge ||
            img.ref.height > maxEdge)) {
          final small = calloc<Pointer<RiaImage>>();
          try {
            final rc = lib.fitWithin(
                img, maxEdge, maxEdge, RiaResizeFilter.triangle, small);
            _check('ria_fit_within', rc);
            lib.imageFree(img);
            img = small.value;
          } finally {
            calloc.free(small);
          }
        }

        if (img.ref.format != RiaFormat.rgb16) {
          throw RiaException('ria_raw_decode', RiaStatus.internal,
              'expected RGB16, got format ${img.ref.format}');
        }

        final n = img.ref.width * img.ref.height * 3;
        final data = Uint16List(n);
        data.setAll(0, img.ref.data.cast<Uint16>().asTypedList(n));
        // Read after the resize, not before: `ria_image_copy_encoding` carries
        // both labels across `ria_fit_within`, and a resized buffer that
        // forgot its anchor makes every EV downstream wrong.
        return SceneImage(
          data,
          img.ref.width,
          img.ref.height,
          saturationScale: img.ref.saturationLevel,
          colorspace: img.ref.colorspace,
        );
      } finally {
        lib.imageFree(img);
      }
    } finally {
      calloc.free(opt);
      calloc.free(out);
    }
  }
}

// ── Operations on a caller-owned display buffer ───────────────────────────

/// Sharpen an RGB8 buffer in place, then measure it.
///
/// Both operations belong to the display domain and both are already
/// implemented in C over parallelised row loops, so the fused Dart renderer
/// hands its output straight to them rather than reimplementing either. The
/// buffer is wrapped, not copied — `ria_image_wrap` takes ownership of
/// nothing.
class DisplayBuffer {
  final Pointer<Uint8> data;
  final int width;
  final int height;
  final Pointer<RiaImage> _img;

  DisplayBuffer._(this.data, this.width, this.height, this._img);

  factory DisplayBuffer.allocate(int width, int height) {
    final lib = Ria.lib();
    final bytes = width * height * 3;
    final data = calloc<Uint8>(bytes);
    final out = calloc<Pointer<RiaImage>>();
    try {
      final rc = lib.imageWrap(data, width, height, RiaFormat.rgb8, out);
      if (rc != RiaStatus.ok) {
        calloc.free(data);
        _check('ria_image_wrap', rc);
      }
      return DisplayBuffer._(data, width, height, out.value);
    } finally {
      calloc.free(out);
    }
  }

  /// A view over the native pixels. Writing through it writes the buffer that
  /// the C calls below will read, with no copy in between.
  Uint8List get pixels => data.asTypedList(width * height * 3);

  void unsharpMask(double sigma, double amount, double threshold) {
    if (amount == 0) return;
    _check('ria_unsharp_mask',
        Ria.lib().unsharpMask(_img, sigma, amount, threshold));
  }

  /// 256 bins for R, G, B and luma, plus the clipping fractions.
  Histogram histogram() {
    final h = calloc<RiaHistogram>();
    try {
      _check('ria_compute_histogram', Ria.lib().computeHistogram(_img, h));
      final r = h.ref;
      return Histogram(
        red: _bins(r.r),
        green: _bins(r.g),
        blue: _bins(r.b),
        luma: _bins(r.luma),
        pixels: r.pixels,
        clippedBlack: r.clippedBlack,
        clippedWhite: r.clippedWhite,
      );
    } finally {
      calloc.free(h);
    }
  }

  void dispose() {
    // ria_image_wrap does not own the pixels, so both have to go.
    Ria.lib().imageFree(_img);
    calloc.free(data);
  }

  static Uint32List _bins(Array<Uint32> a) {
    final out = Uint32List(riaHistogramBins);
    for (var i = 0; i < riaHistogramBins; i++) {
      out[i] = a[i];
    }
    return out;
  }
}

/// Unsharp-mask a 16-bit RGB buffer that lives in Dart memory.
///
/// The C filter needs native pixels, and a 16-bit TIFF export has no RGBA
/// buffer to reuse, so this is a copy in and a copy out. Two passes over
/// 200 MB against reimplementing a separable Gaussian in Dart: the copy is
/// the cheaper of the two by a wide margin, and it keeps one implementation
/// of the filter rather than two that can drift apart.
void sharpenRgb16(Uint16List rgb, int width, int height, double sigma,
    double amount, double threshold) {
  if (amount == 0) return;
  final lib = Ria.lib();
  final bytes = rgb.lengthInBytes;
  final native = calloc<Uint8>(bytes);
  final out = calloc<Pointer<RiaImage>>();
  try {
    native.cast<Uint16>().asTypedList(rgb.length).setAll(0, rgb);
    _check('ria_image_wrap',
        lib.imageWrap(native, width, height, RiaFormat.rgb16, out));
    final img = out.value;
    try {
      _check('ria_unsharp_mask', lib.unsharpMask(img, sigma, amount, threshold));
      rgb.setAll(0, native.cast<Uint16>().asTypedList(rgb.length));
    } finally {
      lib.imageFree(img);
    }
  } finally {
    calloc.free(native);
    calloc.free(out);
  }
}

/// A 256-bin histogram of the *displayed* image — display-referred by
/// definition, which is the right domain for a widget that describes what the
/// viewer is looking at.
class Histogram {
  final Uint32List red;
  final Uint32List green;
  final Uint32List blue;
  final Uint32List luma;
  final int pixels;
  final double clippedBlack;
  final double clippedWhite;

  const Histogram({
    required this.red,
    required this.green,
    required this.blue,
    required this.luma,
    required this.pixels,
    required this.clippedBlack,
    required this.clippedWhite,
  });

  static Histogram empty() => Histogram(
        red: Uint32List(riaHistogramBins),
        green: Uint32List(riaHistogramBins),
        blue: Uint32List(riaHistogramBins),
        luma: Uint32List(riaHistogramBins),
        pixels: 0,
        clippedBlack: 0,
        clippedWhite: 0,
      );
}

String _str(Array<Uint8> a, int max) {
  final b = <int>[];
  for (var i = 0; i < max; i++) {
    final c = a[i];
    if (c == 0) break;
    b.add(c);
  }
  return String.fromCharCodes(b).trim();
}
