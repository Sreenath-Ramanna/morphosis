// lib/src/ria/bindings.dart
//
// dart:ffi bindings to libraw_images_api.so — the modern `ria_*` ABI, not the
// legacy `raw_*` one that raw_viewer still uses.
//
// Field order and type must match include/raw_images_api.h exactly. Nothing
// checks that across the boundary at build time — the app builds the library
// from source as part of its own CMake, which is what keeps the two in step.

import 'dart:ffi';

import 'package:ffi/ffi.dart';

// ── Status ────────────────────────────────────────────────────────────────

abstract final class RiaStatus {
  static const int ok = 0;
  static const int invalid = -1;
  static const int memory = -2;
  static const int io = -3;
  static const int unsupported = -4;
  static const int noData = -5;
  static const int internal = -6;
}

// ── Enums, as plain ints ──────────────────────────────────────────────────

abstract final class RiaFormat {
  static const int rgb8 = 0;
  static const int rgba8 = 1;
  static const int rgb16 = 2;
  static const int rgba16 = 3;
  static const int gray8 = 4;
  static const int gray16 = 5;
}

abstract final class RiaTransfer {
  static const int linear = 0;
  static const int srgb = 1;
  static const int gamma = 2;
}

abstract final class RiaResizeFilter {
  static const int nearest = 0;
  static const int bilinear = 1;
  static const int catmullRom = 2;
  static const int lanczos3 = 3;
}

abstract final class RiaDemosaic {
  static const int linear = 0;
  static const int vng = 1;
  static const int ppg = 2;
  static const int ahd = 3;
}

/// LibRaw orientation codes, as carried on `ria_image.pending_flip`.
abstract final class RiaFlip {
  static const int none = 0;
  static const int rot180 = 3;
  static const int rot90ccw = 5;
  static const int rot90cw = 6;
}

// ── Structs ───────────────────────────────────────────────────────────────

final class RiaImage extends Struct {
  external Pointer<Uint8> data;

  @Int32()
  external int width;
  @Int32()
  external int height;
  @Int32()
  external int channels;
  @Int32()
  external int bits;

  @Size()
  external int stride;
  @Size()
  external int dataSize;

  @Int32()
  external int format;
  @Int32()
  external int pendingFlip;

  @Int32()
  external int transfer;
  @Float()
  external double transferGamma;
  @Float()
  external double transferSlope;
  @Int32()
  external int colorspace;
}

final class RiaDecodeOptions extends Struct {
  @Int32()
  external int demosaic;
  @Int32()
  external int outputColor;
  @Int32()
  external int outputBits;
  @Int32()
  external int halfSize;
  @Int32()
  external int useCameraWb;
  @Int32()
  external int useAutoWb;
  @Int32()
  external int noAutoBright;
  @Float()
  external double bright;
  @Float()
  external double gammaPower;
  @Float()
  external double gammaSlope;
  @Int32()
  external int highlightMode;
  @Int32()
  external int userFlip;
  @Int32()
  external int applyOrientation;
  @Int32()
  external int alpha;
}

final class RiaMetadata extends Struct {
  @Array(64)
  external Array<Uint8> make;
  @Array(64)
  external Array<Uint8> model;
  @Array(64)
  external Array<Uint8> software;
  @Array(128)
  external Array<Uint8> lens;
  @Array(64)
  external Array<Uint8> artist;

  @Float()
  external double isoSpeed;
  @Float()
  external double shutter;
  @Float()
  external double aperture;
  @Float()
  external double focalLen;
  @Int64()
  external int timestamp;

  @Int32()
  external int width;
  @Int32()
  external int height;
  @Int32()
  external int rawWidth;
  @Int32()
  external int rawHeight;
  @Int32()
  external int flip;

  @Int32()
  external int colors;
  @Int32()
  external int blackLevel;
  @Int32()
  external int whiteLevel;
  @Array(4)
  external Array<Float> camMul;
}

/// The raw materials for a colour temperature calculation — see
/// `ria_color_data` in raw_images_api.h. The library deliberately stops short
/// of a Kelvin figure; `ColourTemperature` in colour_temp.dart derives it.
final class RiaColorData extends Struct {
  @Array(4)
  external Array<Float> camMul;
  @Array(4)
  external Array<Float> preMul;
  @Array.multi([4, 3])
  external Array<Array<Float>> camXyz;
  @Int32()
  external int colors;
  @Int32()
  external int wbctRows;
  @Array.multi([64, 5])
  external Array<Array<Float>> wbct;
}

const int riaHistogramBins = 256;

final class RiaHistogram extends Struct {
  @Array(riaHistogramBins)
  external Array<Uint32> r;
  @Array(riaHistogramBins)
  external Array<Uint32> g;
  @Array(riaHistogramBins)
  external Array<Uint32> b;
  @Array(riaHistogramBins)
  external Array<Uint32> luma;
  @Uint64()
  external int pixels;
  @Double()
  external double clippedBlack;
  @Double()
  external double clippedWhite;
}

const int riaPreviewJpeg = 1;
const int riaPreviewBitmap = 2;

final class RiaPreview extends Struct {
  external Pointer<Uint8> data;
  @Size()
  external int dataSize;
  @Int32()
  external int format;
  @Int32()
  external int width;
  @Int32()
  external int height;
  @Int32()
  external int flip;
}

/// Opaque `ria_raw*`.
final class RiaRaw extends Opaque {}

// ── Native signatures ─────────────────────────────────────────────────────
//
// Two typedefs per call: the native one, whose types are `dart:ffi` marker
// types, and the Dart one, which is what the call actually looks like. The
// Dart-side ones are public because they are the declared types of `RiaLib`'s
// fields.

typedef _VersionNative = Pointer<Utf8> Function();
typedef VersionFn = Pointer<Utf8> Function();

typedef _StatusStringNative = Pointer<Utf8> Function(Int32);
typedef StatusStringFn = Pointer<Utf8> Function(int);

typedef _RawOpenNative = Int32 Function(
    Pointer<Utf8>, Pointer<Pointer<RiaRaw>>);
typedef RawOpenFn = int Function(Pointer<Utf8>, Pointer<Pointer<RiaRaw>>);

typedef _RawCloseNative = Void Function(Pointer<RiaRaw>);
typedef RawCloseFn = void Function(Pointer<RiaRaw>);

typedef _RawMetadataNative = Int32 Function(
    Pointer<RiaRaw>, Pointer<RiaMetadata>);
typedef RawMetadataFn = int Function(Pointer<RiaRaw>, Pointer<RiaMetadata>);

typedef _RawColorDataNative = Int32 Function(
    Pointer<RiaRaw>, Pointer<RiaColorData>);
typedef RawColorDataFn = int Function(Pointer<RiaRaw>, Pointer<RiaColorData>);

typedef _RawPreviewNative = Int32 Function(
    Pointer<RiaRaw>, Pointer<Pointer<RiaPreview>>);
typedef RawPreviewFn = int Function(
    Pointer<RiaRaw>, Pointer<Pointer<RiaPreview>>);

typedef _PreviewFreeNative = Void Function(Pointer<RiaPreview>);
typedef PreviewFreeFn = void Function(Pointer<RiaPreview>);

typedef _RawDecodeNative = Int32 Function(Pointer<RiaRaw>,
    Pointer<RiaDecodeOptions>, Pointer<Pointer<RiaImage>>);
typedef RawDecodeFn = int Function(Pointer<RiaRaw>, Pointer<RiaDecodeOptions>,
    Pointer<Pointer<RiaImage>>);

typedef _DecodeOptionsNative = Void Function(Pointer<RiaDecodeOptions>);
typedef DecodeOptionsFn = void Function(Pointer<RiaDecodeOptions>);

typedef _ImageFreeNative = Void Function(Pointer<RiaImage>);
typedef ImageFreeFn = void Function(Pointer<RiaImage>);

typedef _ImageWrapNative = Int32 Function(
    Pointer<Uint8>, Int32, Int32, Int32, Pointer<Pointer<RiaImage>>);
typedef ImageWrapFn = int Function(
    Pointer<Uint8>, int, int, int, Pointer<Pointer<RiaImage>>);

typedef _FitWithinNative = Int32 Function(
    Pointer<RiaImage>, Int32, Int32, Int32, Pointer<Pointer<RiaImage>>);
typedef FitWithinFn = int Function(
    Pointer<RiaImage>, int, int, int, Pointer<Pointer<RiaImage>>);

typedef _UnsharpNative = Int32 Function(Pointer<RiaImage>, Float, Float, Float);
typedef UnsharpFn = int Function(Pointer<RiaImage>, double, double, double);

typedef _HistogramNative = Int32 Function(
    Pointer<RiaImage>, Pointer<RiaHistogram>);
typedef HistogramFn = int Function(Pointer<RiaImage>, Pointer<RiaHistogram>);

typedef _IsRawExtNative = Int32 Function(Pointer<Utf8>);
typedef IsRawExtFn = int Function(Pointer<Utf8>);

typedef _SupportedExtNative = Pointer<Pointer<Utf8>> Function();
typedef SupportedExtFn = Pointer<Pointer<Utf8>> Function();

// ── Loader ────────────────────────────────────────────────────────────────

/// The resolved symbol table. One instance per isolate: a `DynamicLibrary`
/// handle cannot cross an isolate boundary, so workers reopen the same file
/// rather than receiving this object.
class RiaLib {
  final DynamicLibrary _lib;

  late final VersionFn versionString;
  late final StatusStringFn statusString;
  late final RawOpenFn rawOpen;
  late final RawCloseFn rawClose;
  late final RawMetadataFn rawMetadata;
  late final RawColorDataFn rawColorData;
  late final RawPreviewFn rawPreview;
  late final PreviewFreeFn previewFree;
  late final RawDecodeFn rawDecode;
  late final DecodeOptionsFn decodeOptionsDefaults;
  late final DecodeOptionsFn decodeOptionsSceneLinear;
  late final ImageFreeFn imageFree;
  late final ImageWrapFn imageWrap;
  late final FitWithinFn fitWithin;
  late final UnsharpFn unsharpMask;
  late final HistogramFn computeHistogram;
  late final IsRawExtFn isRawExtension;
  late final SupportedExtFn supportedExtensions;

  RiaLib._(this._lib) {
    versionString =
        _lib.lookupFunction<_VersionNative, VersionFn>('ria_version_string');
    statusString = _lib
        .lookupFunction<_StatusStringNative, StatusStringFn>('ria_status_string');
    rawOpen = _lib.lookupFunction<_RawOpenNative, RawOpenFn>('ria_raw_open');
    rawClose = _lib.lookupFunction<_RawCloseNative, RawCloseFn>('ria_raw_close');
    rawMetadata = _lib
        .lookupFunction<_RawMetadataNative, RawMetadataFn>('ria_raw_metadata');
    rawColorData = _lib.lookupFunction<_RawColorDataNative, RawColorDataFn>(
        'ria_raw_color_data');
    rawPreview =
        _lib.lookupFunction<_RawPreviewNative, RawPreviewFn>('ria_raw_preview');
    previewFree = _lib
        .lookupFunction<_PreviewFreeNative, PreviewFreeFn>('ria_preview_free');
    rawDecode =
        _lib.lookupFunction<_RawDecodeNative, RawDecodeFn>('ria_raw_decode');
    decodeOptionsDefaults =
        _lib.lookupFunction<_DecodeOptionsNative, DecodeOptionsFn>(
            'ria_decode_options_defaults');
    decodeOptionsSceneLinear =
        _lib.lookupFunction<_DecodeOptionsNative, DecodeOptionsFn>(
            'ria_decode_options_scene_linear');
    imageFree =
        _lib.lookupFunction<_ImageFreeNative, ImageFreeFn>('ria_image_free');
    imageWrap =
        _lib.lookupFunction<_ImageWrapNative, ImageWrapFn>('ria_image_wrap');
    fitWithin =
        _lib.lookupFunction<_FitWithinNative, FitWithinFn>('ria_fit_within');
    unsharpMask =
        _lib.lookupFunction<_UnsharpNative, UnsharpFn>('ria_unsharp_mask');
    computeHistogram = _lib
        .lookupFunction<_HistogramNative, HistogramFn>('ria_compute_histogram');
    isRawExtension = _lib
        .lookupFunction<_IsRawExtNative, IsRawExtFn>('ria_is_raw_extension');
    supportedExtensions =
        _lib.lookupFunction<_SupportedExtNative, SupportedExtFn>(
            'ria_supported_extensions');
  }

  factory RiaLib.open(String soPath) => RiaLib._(DynamicLibrary.open(soPath));

  String get version => versionString().toDartString();

  String describe(int status) =>
      status == RiaStatus.ok ? 'ok' : statusString(status).toDartString();
}
