// lib/src/ui/editor_screen.dart
//
// The whole application: a folder of RAW files on the left, the frame being
// edited in the middle, the controls on the right.
//
// The source files are opened read-only and never written. Every adjustment
// changes only the `Edit` value held here; the pixels on screen are
// regenerated from the decoded scene-referred buffer each time.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../catalog/catalog.dart';
import '../catalog/catalog_paths.dart';
import '../catalog/catalog_service.dart';
import '../catalog/catalog_writer.dart';
import '../catalog/digest.dart';
import '../model/edit.dart';
import '../model/geometry.dart';
import '../pipeline/processor.dart';
import '../ria/ria.dart';
import 'canvas_zoom.dart';
import 'editor_layout.dart';
import 'export_dialog.dart';
import 'photo_list.dart';
import 'right_panel.dart';

class EditorScreen extends StatefulWidget {
  final String? initialFolder;
  final String? initialSelection;

  const EditorScreen({
    super.key,
    this.initialFolder,
    this.initialSelection,
  });

  @override
  State<EditorScreen> createState() => _EditorScreenState();
}

class _EditorScreenState extends State<EditorScreen> {
  Processor? _processor;
  String? _startupError;

  String? _folder;
  List<PhotoEntry> _photos = const [];
  final Map<String, Uint8List?> _thumbnails = {};
  int _selected = -1;

  FrameInfo? _frame;
  ui.Image? _image;
  Histogram? _histogram;
  Edit _edit = Edit.neutral;

  /// True while a decode is in flight. The canvas keeps showing the previous
  /// frame rather than flashing empty.
  bool _loading = false;
  String? _loadError;

  /// Render coalescing: at most one pass in the worker at a time, with the
  /// most recent edit queued behind it. A slider drag emits far more
  /// changes than a 100 ms pass can absorb, and queuing them all would leave
  /// the canvas seconds behind the thumb.
  bool _rendering = false;
  Edit? _queued;
  int _lastRenderMillis = 0;
  double _softLimit = 1.0;

  /// The median of the frame the last render was made from. Highlight recovery
  /// re-decodes, so this follows the render rather than the open.
  double _medianEv = 0.0;

  bool _exporting = false;
  String? _status;

  /// The catalogue, and the policy that decides when it is written to.
  ///
  /// Both are null when the catalogue could not be opened. That is not fatal:
  /// the editor works without one, and refusing to open a photograph because a
  /// database is unavailable would be a poor trade. The reason is shown once,
  /// in the status bar.
  CatalogService? _catalog;
  CatalogWriter? _writer;
  String? _catalogError;

  /// Completes when the catalogue has finished opening, successfully or not.
  ///
  /// Opening it races the first decode, and the first frame is selected before
  /// either has finished. Without something to wait on, that frame would find
  /// no catalogue and stay uncatalogued for the rest of the session — the
  /// folder given on the command line is exactly the case that hits it.
  final Completer<void> _catalogueReady = Completer<void>();

  /// What the catalogue knows about the frame on screen.
  CatalogEntry? _entry;

  /// Set when the edit on screen was restored from the catalogue rather than
  /// chosen in this session. Cleared by the first adjustment, and by revert.
  DateTime? _restoredFrom;

  /// Every keyword used so far, for autocomplete. Refreshed after a change
  /// rather than queried per keystroke.
  List<KeywordCount> _knownKeywords = const [];

  EditorTab _tab = EditorTab.colour;

  /// Shared with the canvas, so the keyboard and the mouse move the same view.
  final CanvasZoom _zoom = CanvasZoom();

  @override
  void initState() {
    super.initState();
    _startProcessor();
    unawaited(_startCatalogue());
  }

  @override
  void dispose() {
    // The last thing to happen before the window goes: whatever is sitting on
    // the debounce timer has to reach the file. Fire and forget is all a
    // synchronous dispose allows, but the service waits for the write before
    // it kills its isolate.
    final writer = _writer;
    final catalog = _catalog;
    if (writer != null) {
      unawaited(writer.flush().whenComplete(() => catalog?.close()));
    } else {
      unawaited(catalog?.close() ?? Future.value());
    }
    _processor?.dispose();
    _image?.dispose();
    _zoom.dispose();
    super.dispose();
  }

  Future<void> _startCatalogue() async {
    try {
      final service = await CatalogService.start(await ensureCatalogFile());
      if (!mounted) {
        await service.close();
        return;
      }
      final writer = CatalogWriter(service);
      final known = await service.keywords();
      if (!mounted) {
        await service.close();
        return;
      }
      setState(() {
        _catalog = service;
        _writer = writer;
        _knownKeywords = known;
      });
    } catch (e) {
      // Not fatal. The editor is still an editor without a catalogue.
      if (mounted) setState(() => _catalogError = 'Catalogue unavailable: $e');
    } finally {
      if (!_catalogueReady.isCompleted) _catalogueReady.complete();
    }
  }

  Future<void> _startProcessor() async {
    try {
      final soPath = Ria.resolveLibraryPath();
      if (!File(soPath).existsSync()) {
        throw StateError('libraw_images_api.so was not found at $soPath');
      }
      final proc = await Processor.start(soPath);
      if (!mounted) {
        await proc.dispose();
        return;
      }
      setState(() => _processor = proc);

      final start = widget.initialFolder;
      if (start != null && Directory(start).existsSync()) {
        await _loadFolder(start, select: widget.initialSelection);
      }
    } catch (e) {
      if (mounted) setState(() => _startupError = '$e');
    }
  }

  // ── Folder ──────────────────────────────────────────────────────────────

  Future<void> _browseFolder() async {
    final dir = await FilePicker.platform.getDirectoryPath(
      dialogTitle: 'Choose a folder of RAW files',
      initialDirectory: _folder,
    );
    if (dir == null) return;
    await _loadFolder(dir);
  }

  Future<void> _loadFolder(String dir, {String? select}) async {
    final entries = <PhotoEntry>[];
    try {
      final listing = await Directory(dir)
          .list(followLinks: false)
          .where((e) => e is File)
          .toList();
      for (final e in listing) {
        if (Ria.isRawFile(e.path)) {
          entries.add(PhotoEntry(e.path, p.basename(e.path)));
        }
      }
    } catch (e) {
      setState(() => _loadError = 'Could not read $dir: $e');
      return;
    }
    entries.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

    setState(() {
      _folder = dir;
      _photos = entries;
      _thumbnails.clear();
      _selected = -1;
      _loadError = entries.isEmpty ? 'No RAW files in this folder.' : null;
      _status = '${entries.length} RAW ${entries.length == 1 ? 'file' : 'files'}';
    });

    unawaited(_loadThumbnails(entries));
    if (entries.isEmpty) return;

    // A file handed over by the file manager: open its folder, but land on
    // the frame that was actually double-clicked.
    final wanted = select == null
        ? -1
        : entries.indexWhere((e) => p.equals(e.path, select));
    await _select(wanted >= 0 ? wanted : 0);
  }

  /// Fills the strip in the background, one file at a time so that opening
  /// the first frame — which the user is waiting on — gets the worker first.
  Future<void> _loadThumbnails(List<PhotoEntry> entries) async {
    final proc = _processor;
    if (proc == null) return;
    for (final e in entries) {
      if (!mounted || !identical(_photos, entries)) return;
      try {
        final bytes = await proc.thumbnail(e.path);
        if (!mounted || !identical(_photos, entries)) return;
        setState(() => _thumbnails[e.path] = bytes);
      } catch (_) {
        if (!mounted) return;
        setState(() => _thumbnails[e.path] = null);
      }
    }
  }

  // ── Frame ───────────────────────────────────────────────────────────────

  Future<void> _select(int index) async {
    final proc = _processor;
    if (proc == null || index < 0 || index >= _photos.length) return;
    if (index == _selected && _frame != null) return;

    // A new frame is shown fit-to-window. Inheriting the previous one's
    // magnification would land the viewer somewhere arbitrary in a photograph
    // they have not seen yet.
    _zoom.reset();

    setState(() {
      _selected = index;
      _loading = true;
      _loadError = null;
      // A new frame starts neutral. Carrying an edit across would apply one
      // photograph's decisions to another, and the grey point that anchors
      // the zone controls is a property of the frame, not of the session.
      // A crop especially: it names a region of one photograph.
      _edit = Edit.neutral;
      _histogram = null;
      _entry = null;
      _restoredFrom = null;
    });

    final path = _photos[index].path;

    // Started here, before the decode, and awaited long afterwards. Hashing a
    // 30 MB frame is about a third of a second against the decode's second and
    // a half, so running the two together makes it free in wall-clock terms —
    // PLAN.md section 4. It must never happen on a folder listing or a slider
    // move.
    final identifying = _identify(path);

    try {
      final info = await proc.open(path);
      if (!mounted || _selected != index) return;
      setState(() {
        _frame = info;
        _loading = false;
      });
      await _render();
      // After the first render, so that the frame is on screen at its neutral
      // rendering while the catalogue is consulted rather than after it.
      unawaited(_restoreFrom(index, path, info, identifying));
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadError = 'Could not decode ${_photos[index].name}: $e';
      });
    }
  }

  /// The digest of a file, or null if it could not be read.
  ///
  /// A failure here loses cataloguing for one frame; it must not lose the
  /// frame, so it is swallowed rather than thrown.
  Future<String?> _identify(String path) async {
    // Deliberately not gated on the catalogue being open. It is still opening
    // when the first frame is selected, and waiting here would either lose
    // that frame or serialise the hash behind the database — the point of
    // starting it now is that it overlaps the decode.
    if (_catalogError != null) return null;
    try {
      return await digestOfFileOnIsolate(path);
    } catch (_) {
      return null;
    }
  }

  /// Record that this frame was seen, and put back what was stored for it.
  ///
  /// Runs after the frame is on screen. The catalogue row wants the camera and
  /// the capture date, which arrive with the decode, so the write waits for
  /// both even though the hash was ready first.
  Future<void> _restoreFrom(
    int index,
    String path,
    FrameInfo info,
    Future<String?> identifying,
  ) async {
    // The hash and the catalogue open in parallel; this is where they meet.
    await _catalogueReady.future;
    final writer = _writer;
    if (writer == null) return;

    final sha256 = await identifying;
    if (sha256 == null || !mounted || _selected != index) return;

    try {
      final stat = await File(path).stat();
      final now = DateTime.now();
      final entry = await writer.opened(
        sha256: sha256,
        displayName: p.basename(path),
        sizeBytes: stat.size,
        capturedAt: info.metadata.capturedAt,
        camera: info.metadata.camera,
        location: SeenAt(
          path: path,
          sizeBytes: stat.size,
          mtime: stat.modified,
          lastSeen: now,
        ),
      );
      if (!mounted || _selected != index) return;

      setState(() => _entry = entry);

      // Put the stored adjustments back — the decision recorded in PLAN.md
      // section 11, with the banner that says so. Only when the photographer
      // has not already started work on this frame in the third of a second
      // the hash took; their own move wins over a stored one.
      final stored = entry?.edit;
      if (stored == null || _edit != Edit.neutral) return;
      setState(() {
        _edit = stored;
        _restoredFrom = entry!.lastEdited;
      });
      await _render();
    } catch (e) {
      if (mounted) setState(() => _catalogError = 'Catalogue: $e');
    }
  }

  /// Step to an adjacent frame, for the arrow keys.
  ///
  /// Clamped rather than wrapping: at the end of a folder, pressing on should
  /// do nothing rather than silently jump back to the start. Ignored while a
  /// decode is in flight, so holding a key does not queue up a decode per
  /// repeat — each one is a second and a half of work.
  void _step(int delta) {
    if (_loading || _photos.isEmpty) return;
    final next = (_selected + delta).clamp(0, _photos.length - 1);
    if (next != _selected) unawaited(_select(next));
  }

  void _updateEdit(Edit next) {
    setState(() {
      _edit = next;
      // The edit on screen is now the photographer's, not the catalogue's.
      _restoredFrom = null;
    });
    // Coalesced, never written per frame of a drag. See CatalogWriter.
    _writer?.editChanged(next);
    unawaited(_render());
  }

  /// Back to neutral, and forget the frame was adjusted.
  Future<void> _revertEdit() async {
    setState(() {
      _edit = Edit.neutral;
      _restoredFrom = null;
    });
    await _writer?.revertEdit();
    if (mounted) setState(() => _entry = _writer?.current);
    await _render();
  }

  Future<void> _updateKeywords(KeywordSet keywords) async {
    final writer = _writer;
    if (writer == null) return;
    await writer.keywordsChanged(keywords);
    if (!mounted) return;
    // Refreshed after a change rather than per keystroke: a new keyword has to
    // appear in the autocomplete list, and nothing else moves it.
    final known = await _catalog?.keywords() ?? const <KeywordCount>[];
    if (!mounted) return;
    setState(() {
      _entry = writer.current;
      _knownKeywords = known;
    });
  }

  void _updateGeometry(Geometry next) {
    // Straightening shrinks the region with no blank corner, so a crop placed
    // before the frame was levelled has to be pulled inside the new bounds.
    // Done here rather than in the renderer so that what the rectangle shows
    // and what gets exported cannot disagree.
    final frame = _frame;
    final bounds = frame == null
        ? CropRect.full
        : next.straightenBounds(frame.previewWidth, frame.previewHeight);
    final fitted = next.copyWith(crop: next.crop.fittedInside(bounds));
    _updateEdit(_edit.copyWith(geometry: fitted));
  }

  void _setTab(EditorTab tab) {
    if (tab == _tab) return;
    setState(() => _tab = tab);
    // The crop tool shows the uncropped frame and the editor shows the
    // cropped one, so switching between them is a re-render even though the
    // edit has not changed.
    unawaited(_render());
  }

  Future<void> _render() async {
    final proc = _processor;
    if (proc == null || _frame == null) return;
    if (_rendering) {
      _queued = _edit;
      return;
    }
    _rendering = true;
    var edit = _edit;
    try {
      while (true) {
        final result =
            await proc.render(edit, suppressCrop: _tab == EditorTab.crop);
        if (!mounted) return;

        final image = await _decodeImage(result);
        if (!mounted) {
          image.dispose();
          return;
        }
        final old = _image;
        setState(() {
          _image = image;
          _histogram = result.histogram;
          _lastRenderMillis = result.millis;
          _softLimit = result.softLimitFactor;
          _medianEv = result.medianEv;
        });
        old?.dispose();

        final next = _queued;
        _queued = null;
        if (next == null || next == edit) break;
        edit = next;
      }
    } catch (e) {
      if (mounted) setState(() => _loadError = 'Render failed: $e');
    } finally {
      _rendering = false;
    }
  }

  Future<ui.Image> _decodeImage(RenderResult r) {
    final done = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      r.rgba,
      r.width,
      r.height,
      ui.PixelFormat.rgba8888,
      done.complete,
    );
    return done.future;
  }

  // ── Export ──────────────────────────────────────────────────────────────

  Future<void> _export() async {
    final frame = _frame;
    if (frame == null || _exporting) return;

    final choice = await showDialog<ExportChoice>(
      context: context,
      builder: (_) => ExportDialog(sourceName: p.basename(frame.path)),
    );
    if (choice == null || !mounted) return;

    final base = p.basenameWithoutExtension(frame.path);
    final suggested = '$base.${choice.format.extension}';
    final target = await FilePicker.platform.saveFile(
      dialogTitle: 'Export ${choice.format.label}',
      fileName: suggested,
      initialDirectory: p.dirname(frame.path),
    );
    if (target == null || !mounted) return;

    // The picker returns whatever was typed; without this a JPEG could be
    // saved with a .CR3 extension over the file it came from.
    final path = p.extension(target).isEmpty
        ? '$target.${choice.format.extension}'
        : target;

    setState(() {
      _exporting = true;
      _status = 'Exporting ${p.basename(path)} — decoding at full resolution…';
    });

    try {
      final written = await runExportIsolate(ExportRequest(
        soPath: Ria.resolveLibraryPath(),
        sourcePath: frame.path,
        targetPath: path,
        edit: _edit,
        format: choice.format,
        jpegQuality: choice.quality,
        previewMaxEdge: previewMaxEdge,
      ));
      // An export is a deliberate act and a natural save point, so whatever
      // is sitting on the debounce timer goes to the catalogue now.
      await _writer?.flush();
      if (!mounted) return;
      final size = await File(written).length();
      setState(() {
        _exporting = false;
        _entry = _writer?.current;
        _status = 'Wrote ${p.basename(written)} — ${_bytes(size)}';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _exporting = false;
        _status = null;
        _loadError = 'Export failed: $e';
      });
    }
  }

  static String _bytes(int n) {
    if (n < 1024) return '$n B';
    if (n < 1024 * 1024) return '${(n / 1024).toStringAsFixed(0)} kB';
    return '${(n / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  // ── Build ───────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final startupError = _startupError;
    if (startupError != null) {
      return LibraryMissingScreen(detail: startupError);
    }
    return EditorLayout(
      state: EditorViewState(
        folder: _folder,
        photos: _photos,
        thumbnails: _thumbnails,
        selected: _selected,
        frame: _frame,
        image: _image,
        histogram: _histogram,
        edit: _edit,
        softLimitFactor: _softLimit,
        medianEv: _medianEv,
        tab: _tab,
        loading: _loading,
        exporting: _exporting,
        status: _status,
        error: _loadError ?? _catalogError,
        renderMillis: _lastRenderMillis,
        entry: _entry,
        knownKeywords: _knownKeywords,
        restoredFrom: _restoredFrom,
      ),
      onBrowse: _processor == null ? null : _browseFolder,
      onExport: _frame == null || _exporting ? null : _export,
      onSelect: (i) => unawaited(_select(i)),
      onEditChanged: _updateEdit,
      onPreviousImage: () => _step(-1),
      onNextImage: () => _step(1),
      onTabChanged: _setTab,
      onKeywordsChanged: (k) => unawaited(_updateKeywords(k)),
      onRevertEdit: () => unawaited(_revertEdit()),
      onGeometryChanged: _updateGeometry,
      zoom: _zoom,
    );
  }
}
