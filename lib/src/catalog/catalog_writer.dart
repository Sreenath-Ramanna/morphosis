// lib/src/catalog/catalog_writer.dart
//
// When a row is written.
//
// The request says "each time a RAW image is manipulated". Taken literally
// that is every frame of every slider drag — ten writes a second, most of them
// superseded a moment later. PLAN.md section 8 says what it should mean, and
// this class is that table:
//
//   a frame is opened        look up, record the location, do NOT write an edit
//   an adjustment changes    mark dirty; start a timer, restarted on each change
//   the timer expires        one write
//   another frame selected   flush immediately, cancel the timer
//   an export completes      flush immediately
//   the app is closing       flush immediately
//   keywords change          flush immediately — typing is deliberate and rare
//
// A frame opened and closed with nothing touched does not create an edit. It
// records that the image was seen.

import 'dart:async';

import '../model/edit.dart';
import 'catalog.dart';

class CatalogWriter {
  /// Long enough that a slider drag is one write, short enough that quitting
  /// straight after a change does not depend on the flush.
  static const Duration defaultDebounce = Duration(seconds: 2);

  final CatalogStore store;
  final Duration debounce;

  /// Injected so the policy can be tested without waiting two seconds a case.
  /// The default is the real thing.
  final Timer Function(Duration, void Function()) _schedule;
  final DateTime Function() _now;

  CatalogWriter(
    this.store, {
    this.debounce = defaultDebounce,
    Timer Function(Duration, void Function())? schedule,
    DateTime Function()? now,
  })  : _schedule = schedule ?? Timer.new,
        _now = now ?? DateTime.now;

  /// The frame being worked on, as last written. Null between frames.
  CatalogEntry? _entry;
  CatalogEntry? get current => _entry;

  Edit? _dirtyEdit;
  bool _clearEdit = false;
  KeywordSet? _dirtyKeywords;
  Timer? _timer;

  /// Writes are chained rather than overlapped: the store is one connection
  /// and a flush racing a debounced write could otherwise land out of order.
  Future<void> _inFlight = Future.value();

  bool get hasPendingWrite => _dirtyEdit != null || _dirtyKeywords != null || _clearEdit;

  /// A frame has been opened. Returns what the catalogue already knows about
  /// it, which is what the editor restores from.
  ///
  /// This writes the image row — the decision recorded in PLAN.md section 11 —
  /// but never an edit: `edit` stays whatever was already stored, which for a
  /// frame never worked on is null. A location is always recorded, which is
  /// what makes "where have I seen this file" answerable.
  Future<CatalogEntry?> opened({
    required String sha256,
    required String displayName,
    required int sizeBytes,
    required SeenAt location,
    DateTime? capturedAt,
    String? camera,
  }) async {
    // The frame being left may have an edit waiting on its timer.
    await flush();

    final existing = await store.byDigest(sha256);
    final now = _now();
    final entry = existing == null
        ? CatalogEntry(
            sha256: sha256,
            displayName: displayName,
            sizeBytes: sizeBytes,
            capturedAt: capturedAt,
            camera: camera,
            firstSeen: now,
            lastEdited: now,
          )
        // Opening is not editing, so lastEdited is left alone. The name and
        // the size are refreshed because a rename is not a new image, and a
        // size that has changed is worth having recorded when it is noticed.
        : existing.copyWith(
            displayName: displayName,
            sizeBytes: sizeBytes,
            capturedAt: capturedAt,
            camera: camera,
          );

    await store.put(entry);
    await store.recordLocation(sha256, location);
    // Read back rather than trusting the value just built: put preserves the
    // original firstSeen, so the store's copy is the canonical one.
    _entry = await store.byDigest(sha256);
    return _entry;
  }

  /// An adjustment moved. Coalesced — this is the one that must not write.
  void editChanged(Edit edit) {
    final entry = _entry;
    if (entry == null) return;
    // Nothing to write when the value is already what is stored: a slider
    // dragged away and back should not cost a write.
    if (edit == entry.edit && _dirtyKeywords == null) {
      _dirtyEdit = null;
      _clearEdit = false;
      _timer?.cancel();
      _timer = null;
      return;
    }
    _dirtyEdit = edit;
    _clearEdit = false;
    _timer?.cancel();
    _timer = _schedule(debounce, () {
      _timer = null;
      unawaited(_write());
    });
  }

  /// Back to neutral, and forget that this frame was ever adjusted.
  ///
  /// Distinct from `editChanged(Edit.neutral)`, which records that the
  /// photographer chose neutral. This says they never chose anything.
  Future<void> revertEdit() {
    if (_entry == null) return Future.value();
    _clearEdit = true;
    _dirtyEdit = null;
    _timer?.cancel();
    _timer = null;
    return _write();
  }

  /// Keywords changed. Written at once: typing is deliberate and rare, and a
  /// keyword lost to a crash is one the photographer thought they had saved.
  Future<void> keywordsChanged(KeywordSet keywords) {
    final entry = _entry;
    if (entry == null || keywords == entry.keywords) return Future.value();
    _dirtyKeywords = keywords;
    _timer?.cancel();
    _timer = null;
    return _write();
  }

  /// Write anything outstanding now. Safe to call when there is nothing.
  Future<void> flush() {
    _timer?.cancel();
    _timer = null;
    return _write();
  }

  /// Leave the current frame, writing whatever is outstanding first.
  Future<void> closeFrame() async {
    await flush();
    _entry = null;
  }

  Future<void> _write() {
    final entry = _entry;
    if (entry == null || !hasPendingWrite) return _inFlight;

    final next = entry.copyWith(
      edit: _dirtyEdit,
      clearEdit: _clearEdit,
      keywords: _dirtyKeywords,
      lastEdited: _now(),
    );
    _dirtyEdit = null;
    _dirtyKeywords = null;
    _clearEdit = false;
    _entry = next;

    final write = _inFlight.then((_) => store.put(next));
    // The chain must survive a failed write, or one error would wedge every
    // later one. The error still reaches the caller through the returned
    // future.
    _inFlight = write.catchError((_) {});
    return write;
  }
}
