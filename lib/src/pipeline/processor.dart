// lib/src/pipeline/processor.dart
//
// The worker isolate. It owns the decoded scene-referred buffer, the native
// display buffer, and the FFI handle — none of which the UI isolate ever
// touches. The UI sends an `Edit` and receives finished pixels.
//
// One long-lived isolate rather than `Isolate.run` per render: the scene
// buffer is 100–200 MB and would otherwise be copied on every slider frame.
// Export is the exception and runs in its own throwaway isolate, because a
// full-resolution decode takes seconds and must not stall the preview.

import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import '../model/edit.dart';
import '../model/geometry.dart';
import '../ria/ria.dart';
import 'colour_temp.dart';
import 'export.dart';
import 'geometry_ops.dart';
import 'render.dart';
import 'tone.dart';

/// How large the editing preview is allowed to get.
///
/// A 33 MP frame is 100 million samples per pass; at this size it is under
/// two, which is what keeps a slider drag interactive — measured on the
/// release build, roughly 45 ms for the fused pass and another 70 ms when
/// sharpening is on. Saturation off zero roughly doubles the pass, to about
/// 100 ms: it is per-pixel three-channel arithmetic that cannot be folded
/// into a table, so it costs what it costs, and it costs nothing at zero. The full resolution is decoded again at export time, so
/// nothing is lost: approach.md's "adapt for the preview, re-decode for the
/// export", applied to the whole pipeline rather than only to white balance.
const int previewMaxEdge = 1600;

/// What the UI learns when a frame is opened.
class FrameInfo {
  final String path;
  final RawMetadata metadata;
  final ColourTemperature asShot;
  final double minKelvin;
  final double maxKelvin;
  final double autoGreyPoint;
  final double medianEv;
  final int fullWidth;
  final int fullHeight;
  final int previewWidth;
  final int previewHeight;

  const FrameInfo({
    required this.path,
    required this.metadata,
    required this.asShot,
    required this.minKelvin,
    required this.maxKelvin,
    required this.autoGreyPoint,
    required this.medianEv,
    required this.fullWidth,
    required this.fullHeight,
    required this.previewWidth,
    required this.previewHeight,
  });
}

/// One finished preview.
class RenderResult {
  final Uint8List rgba;
  final int width;
  final int height;
  final Histogram histogram;

  /// How far the zone controls had to be scaled back to keep the tone curve
  /// monotonic. 1.0 when nothing was.
  final double softLimitFactor;

  /// Wall time for the pass, shown in the status bar.
  final int millis;

  const RenderResult({
    required this.rgba,
    required this.width,
    required this.height,
    required this.histogram,
    required this.softLimitFactor,
    required this.millis,
  });
}

// ── Messages ──────────────────────────────────────────────────────────────

class _Req {
  final int id;
  const _Req(this.id);
}

class _OpenReq extends _Req {
  final String path;
  const _OpenReq(super.id, this.path);
}

class _RenderReq extends _Req {
  final Edit edit;

  /// The crop tool shows the whole straightened frame with a rectangle drawn
  /// over it, so it asks for a render with the crop suppressed. Everything
  /// else is unchanged, including the geometry cache key.
  final bool suppressCrop;

  const _RenderReq(super.id, this.edit, this.suppressCrop);
}

class _ThumbReq extends _Req {
  final String path;
  const _ThumbReq(super.id, this.path);
}

class _CloseReq extends _Req {
  const _CloseReq(super.id);
}

class _Reply {
  final int id;
  final Object? value;
  final Object? error;
  const _Reply(this.id, this.value, this.error);
}

class _Boot {
  final SendPort reply;
  final String soPath;
  const _Boot(this.reply, this.soPath);
}

// ── Client ────────────────────────────────────────────────────────────────

/// Handle on the worker. Every method completes with the worker's answer or
/// throws whatever it threw.
class Processor {
  final Isolate _isolate;
  final SendPort _commands;
  final ReceivePort _replies;
  final Map<int, Completer<Object?>> _pending;
  int _nextId = 1;

  Processor._(this._isolate, this._commands, this._replies, this._pending);

  static Future<Processor> start(String soPath) async {
    final replies = ReceivePort();
    final ready = Completer<SendPort>();
    final pending = <int, Completer<Object?>>{};

    // One listener for the port's whole life: the worker's first message is
    // its command port, everything after that is a reply. Listening twice —
    // once to wait for the port, once for replies — would throw, because a
    // ReceivePort is single-subscription.
    replies.listen((msg) {
      if (msg is SendPort) {
        if (!ready.isCompleted) ready.complete(msg);
        return;
      }
      if (msg is! _Reply) return;
      final c = pending.remove(msg.id);
      if (c == null) return;
      if (msg.error != null) {
        c.completeError(msg.error!);
      } else {
        c.complete(msg.value);
      }
    });

    final isolate = await Isolate.spawn(
        _workerMain, _Boot(replies.sendPort, soPath),
        debugName: 'morphosis-worker');
    return Processor._(isolate, await ready.future, replies, pending);
  }

  Future<T> _send<T>(_Req Function(int id) build) {
    final id = _nextId++;
    final c = Completer<Object?>();
    _pending[id] = c;
    _commands.send(build(id));
    return c.future.then((v) => v as T);
  }

  Future<FrameInfo> open(String path) =>
      _send<FrameInfo>((id) => _OpenReq(id, path));

  Future<RenderResult> render(Edit edit, {bool suppressCrop = false}) =>
      _send<RenderResult>((id) => _RenderReq(id, edit, suppressCrop));

  /// The camera's embedded JPEG, for the folder list. Null when the file has
  /// none in a format we can hand to Flutter.
  Future<Uint8List?> thumbnail(String path) =>
      _send<Uint8List?>((id) => _ThumbReq(id, path));

  Future<void> dispose() async {
    try {
      await _send<void>((id) => _CloseReq(id)).timeout(
          const Duration(seconds: 2),
          onTimeout: () {});
    } catch (_) {
      // The worker is going away regardless.
    }
    _isolate.kill(priority: Isolate.immediate);
    _replies.close();
  }
}

// ── Worker ────────────────────────────────────────────────────────────────

void _workerMain(_Boot boot) {
  Ria.libraryPathOverride = boot.soPath;
  final commands = ReceivePort();
  boot.reply.send(commands.sendPort);

  final worker = _Worker();
  commands.listen((msg) {
    if (msg is! _Req) return;
    try {
      final value = worker.handle(msg);
      boot.reply.send(_Reply(msg.id, value, null));
    } catch (e, st) {
      boot.reply.send(_Reply(msg.id, null, '$e\n$st'));
    }
  });
}

class _Worker {
  /// The frame as decoded — never modified, and the input every geometry is
  /// applied to. Keeping the original means a crop can be reopened and
  /// widened again without going back to the file.
  SceneImage? _scene;

  /// The frame with the current geometry applied, and the grey point measured
  /// from it. Cached because resampling a 1.7 MP buffer is tens of
  /// milliseconds and the geometry only changes when a crop handle moves —
  /// not on every tonal slider frame.
  SceneImage? _working;
  Geometry? _workingGeometry;
  double _autoGrey = middleGrey;

  WhiteBalance? _wb;
  DisplayBuffer? _buffer;

  Object? handle(_Req req) {
    if (req is _OpenReq) return _open(req.path);
    if (req is _RenderReq) return _render(req.edit, req.suppressCrop);
    if (req is _ThumbReq) return _thumb(req.path);
    if (req is _CloseReq) {
      _release();
      return null;
    }
    return null;
  }

  Uint8List? _thumb(String path) {
    final f = RawFile.open(path);
    try {
      return f.preview()?.bytes;
    } finally {
      f.close();
    }
  }

  FrameInfo _open(String path) {
    _release();
    final f = RawFile.open(path);
    try {
      final meta = f.metadata();
      final wb = WhiteBalance.from(f.colorData());
      final scene = f.decodeSceneLinear(maxEdge: previewMaxEdge);

      _scene = scene;
      _wb = wb;
      final working = _ensureWorking(Geometry.identity);

      return FrameInfo(
        path: path,
        metadata: meta,
        asShot: wb.asShot,
        minKelvin: wb.minKelvin,
        maxKelvin: wb.maxKelvin,
        autoGreyPoint: _autoGrey,
        medianEv: _medianEv,
        fullWidth: meta.width,
        fullHeight: meta.height,
        previewWidth: working.width,
        previewHeight: working.height,
      );
    } finally {
      f.close();
    }
  }

  double _medianEv = 0;

  /// Rebuild the geometry-applied buffer when the geometry has changed, and
  /// re-measure the grey point from it — a crop changes which pixels the
  /// automatic exposure is derived from, which is the point of doing the
  /// geometry first.
  SceneImage _ensureWorking(Geometry geometry) {
    final scene = _scene!;
    if (_working != null && _workingGeometry == geometry) return _working!;

    final working = applyGeometry(scene, geometry);
    final zones =
        ZoneHistogram.compute(working.data, working.width, working.height);
    _working = working;
    _workingGeometry = geometry;
    _autoGrey = zones.autoGreyPoint();
    _medianEv = zones.medianEv;
    return working;
  }

  RenderResult _render(Edit edit, bool suppressCrop) {
    final wb = _wb;
    if (_scene == null || wb == null) {
      throw StateError('no frame is open');
    }
    final sw = Stopwatch()..start();

    final geometry =
        suppressCrop ? edit.geometry.withoutCrop : edit.geometry;
    final scene = _ensureWorking(geometry);

    final tone = _toneFor(edit, _autoGrey);
    final gainLut = tone.buildGainLut();
    final disp = tone.buildDisplayLut(
        outMax: 255, entries: DisplayLut.previewEntries);
    final matrix = _matrixFor(edit, wb);

    var buf = _buffer;
    if (buf == null || buf.width != scene.width || buf.height != scene.height) {
      buf?.dispose();
      buf = DisplayBuffer.allocate(scene.width, scene.height);
      _buffer = buf;
    }

    renderRgb8(scene.data, scene.width, scene.height, matrix, gainLut, disp,
        buf.pixels, saturation: edit.saturation);

    if (edit.sharpness > 0) {
      buf.unsharpMask(_previewSigma, edit.sharpness, _sharpenThreshold);
    }

    final hist = buf.histogram();
    final rgba = expandToRgba(buf.pixels, scene.width * scene.height);

    return RenderResult(
      rgba: rgba,
      width: scene.width,
      height: scene.height,
      histogram: hist,
      softLimitFactor: tone.softLimitFactor(),
      millis: sw.elapsedMilliseconds,
    );
  }

  void _release() {
    _buffer?.dispose();
    _buffer = null;
    _scene = null;
    _working = null;
    _workingGeometry = null;
    _wb = null;
  }
}

/// Radius of the unsharp mask on the preview, in pixels.
const double _previewSigma = 0.9;

/// Ignore differences smaller than this fraction of full scale, so sharpening
/// does not amplify sensor noise in flat areas.
const double _sharpenThreshold = 0.004;

Tone _toneFor(Edit edit, double autoGrey) => Tone(
      greyPoint: edit.greyPointFrom(autoGrey),
      shoulder: edit.highlightRolloff,
      contrastEv: edit.contrastEv,
      blackEv: edit.blackEv,
      shadowEv: edit.shadowEv,
      highlightEv: edit.highlightEv,
      whiteEv: edit.whiteEv,
    );

Float64List? _matrixFor(Edit edit, WhiteBalance wb) {
  final k = edit.temperatureK;
  if (k == null || wb.isNeutral(k)) return null;
  final m = wb.matrixFor(k);
  return Float64List.fromList(
      [m[0][0], m[0][1], m[0][2], m[1][0], m[1][1], m[1][2], m[2][0], m[2][1],
        m[2][2]]);
}

// ── Export ────────────────────────────────────────────────────────────────

/// Everything the export isolate needs, all of it plain data.
class ExportRequest {
  final String soPath;
  final String sourcePath;
  final String targetPath;
  final Edit edit;
  final ExportFormat format;
  final int jpegQuality;

  /// The preview's long edge, so the unsharp radius can be scaled to match
  /// what the user was looking at when they pressed Export.
  final int previewMaxEdge;

  const ExportRequest({
    required this.soPath,
    required this.sourcePath,
    required this.targetPath,
    required this.edit,
    required this.format,
    required this.jpegQuality,
    required this.previewMaxEdge,
  });
}

/// Run one export on a throwaway isolate.
///
/// Not the long-lived worker: a full-resolution decode is seconds of work and
/// several hundred megabytes, and putting it on the render worker would stall
/// the preview for the duration and leave the peak allocation resident
/// afterwards.
Future<String> runExportIsolate(ExportRequest req) =>
    Isolate.run(() => runExport(req));

/// Decode the source again at full resolution, apply the same edit, encode.
///
/// A re-decode rather than an upscale of the preview, and specifically a
/// re-decode through the same scene-linear preset: the tone engine's EV scale
/// is anchored to sensor saturation, so a full-resolution decode and the
/// preview agree about what "−2 EV" means without any renormalisation.
Future<String> runExport(ExportRequest req) async {
  Ria.libraryPathOverride = req.soPath;

  final f = RawFile.open(req.sourcePath);
  final SceneImage decoded;
  final WhiteBalance wb;
  try {
    wb = WhiteBalance.from(f.colorData());
    decoded = f.decodeSceneLinear();
  } finally {
    f.close();
  }

  // Same geometry, same code, at full resolution. The crop is expressed in
  // fractions of the frame rather than in pixels precisely so that it means
  // the same thing here as it did on the preview.
  final scene = applyGeometry(decoded, req.edit.geometry);

  // The grey point is recomputed from the full-resolution frame rather than
  // carried over. It is a percentile, and a percentile of a downsampled image
  // is not quite a percentile of the original — resampling averages away the
  // extremes that set it.
  final zones = ZoneHistogram.compute(scene.data, scene.width, scene.height);
  final tone = _toneFor(req.edit, zones.autoGreyPoint());
  final matrix = _matrixFor(req.edit, wb);
  final gainLut = tone.buildGainLut();

  // The sharpening radius has to grow with the image or an export looks
  // softer than the preview that was approved.
  final scale = scene.width > 0 && scene.height > 0
      ? (scene.width > scene.height ? scene.width : scene.height) /
          req.previewMaxEdge
      : 1.0;
  final sigma = _previewSigma * (scale < 1 ? 1 : scale);

  final Uint8List bytes;
  if (req.format == ExportFormat.tiff) {
    final disp = tone.buildDisplayLut(
        outMax: 65535, entries: DisplayLut.exportEntries);
    final out = Uint16List(scene.width * scene.height * 3);
    renderRgb16(scene.data, scene.width, scene.height, matrix, gainLut, disp,
        out, saturation: req.edit.saturation);
    // Sharpening runs through the C path, which needs the pixels in native
    // memory; 16-bit RGB has no RGBA wrapper here, so a TIFF is sharpened by
    // wrapping the same buffer as RGB16.
    if (req.edit.sharpness > 0) {
      sharpenRgb16(out, scene.width, scene.height, sigma, req.edit.sharpness,
          _sharpenThreshold);
    }
    bytes = encodeTiff16(out, scene.width, scene.height);
  } else {
    final disp = tone.buildDisplayLut(
        outMax: 255, entries: DisplayLut.previewEntries);
    final buf = DisplayBuffer.allocate(scene.width, scene.height);
    try {
      renderRgb8(scene.data, scene.width, scene.height, matrix, gainLut, disp,
          buf.pixels, saturation: req.edit.saturation);
      if (req.edit.sharpness > 0) {
        buf.unsharpMask(sigma, req.edit.sharpness, _sharpenThreshold);
      }
      bytes = encodeJpeg(buf.pixels, scene.width, scene.height,
          req.jpegQuality);
    } finally {
      buf.dispose();
    }
  }

  await writeExport(req.targetPath, bytes, req.sourcePath);
  return req.targetPath;
}
