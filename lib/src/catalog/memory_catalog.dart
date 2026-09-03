// lib/src/catalog/memory_catalog.dart
//
// The catalogue, in a map.
//
// Written before the SQLite one on purpose (PLAN.md section 13): if this is
// awkward to write, the interface is wrong, and that is much cheaper to learn
// before there is a schema. It is also what the test suite runs against, so it
// is held to exactly the same contract as the real store.

import 'catalog.dart';

class MemoryCatalog implements CatalogStore {
  final Map<String, CatalogEntry> _images = {};

  /// Locations keyed by path, because a path is in exactly one place at a
  /// time — which is what makes the conflict rule in [recordLocation] fall out
  /// rather than needing to be searched for.
  final Map<String, ({String sha256, SeenAt at})> _locations = {};

  bool _open = false;

  @override
  Future<void> open() async => _open = true;

  @override
  Future<void> close() async => _open = false;

  void _requireOpen() {
    if (!_open) throw StateError('The catalogue is not open.');
  }

  @override
  Future<CatalogEntry?> byDigest(String sha256) async {
    _requireOpen();
    return _images[sha256];
  }

  @override
  Future<CatalogEntry?> byPathHint(
      String path, int sizeBytes, DateTime mtime) async {
    _requireOpen();
    final located = _locations[path];
    if (located == null) return null;
    // Both halves matter. A changed size is a different file; a changed mtime
    // is a file that may have been written to. Either one means the hint is
    // stale, and a stale hint must answer "do not know" rather than hand back
    // an entry describing content that is no longer there.
    if (located.at.sizeBytes != sizeBytes) return null;
    if (!located.at.mtime.isAtSameMomentAs(mtime.toUtc())) return null;
    return _images[located.sha256];
  }

  @override
  Future<void> put(CatalogEntry entry) async {
    _requireOpen();
    final existing = _images[entry.sha256];
    _images[entry.sha256] = existing == null
        ? entry
        // The image was first seen when it was first seen. A later put is an
        // update, and must not be able to rewrite history.
        : entry.copyWith(firstSeen: existing.firstSeen);
  }

  @override
  Future<void> recordLocation(String sha256, SeenAt location) async {
    _requireOpen();
    if (!_images.containsKey(sha256)) {
      throw StateError('No catalogued image with digest $sha256.');
    }
    // Keying by path is the conflict rule: whatever was claiming this path is
    // replaced, so the old digest stops listing a location it no longer has.
    _locations[location.path] = (sha256: sha256, at: location);
  }

  @override
  Future<List<SeenAt>> locationsOf(String sha256) async {
    _requireOpen();
    final found = _locations.values
        .where((l) => l.sha256 == sha256)
        .map((l) => l.at)
        .toList();
    found.sort((a, b) => b.lastSeen.compareTo(a.lastSeen));
    return found;
  }

  @override
  Future<List<CatalogEntry>> search({
    String? keyword,
    DateRange? captured,
    int limit = 100,
    int offset = 0,
  }) async {
    _requireOpen();
    final needle = keyword == null ? null : KeywordSet.needleFor(keyword);

    var found = _images.values.where((e) {
      if (needle != null && needle.isNotEmpty) {
        if (!e.keywords.foldedForSearch().contains(needle)) return false;
      }
      if (captured != null) {
        final at = e.capturedAt;
        // An image whose file said nothing about when it was taken cannot
        // satisfy a date range. Treating null as "matches" would fill a search
        // for one afternoon with every undated frame in the catalogue.
        if (at == null || !captured.contains(at)) return false;
      }
      return true;
    }).toList();

    found.sort((a, b) {
      final byTime = b.lastEdited.compareTo(a.lastEdited);
      // Ties broken by digest, so that paging cannot repeat or skip an entry
      // when several were written in the same millisecond.
      return byTime != 0 ? byTime : a.sha256.compareTo(b.sha256);
    });

    if (offset >= found.length) return const [];
    return found.skip(offset).take(limit).toList();
  }

  @override
  Future<List<KeywordCount>> keywords() async {
    _requireOpen();
    // Grouped case-insensitively, reported in the casing first seen — the same
    // rule KeywordSet applies within one image, applied across the catalogue.
    final counts = <String, int>{};
    final casing = <String, String>{};
    for (final entry in _images.values) {
      for (final word in entry.keywords.keywords) {
        final fold = word.toLowerCase();
        counts[fold] = (counts[fold] ?? 0) + 1;
        casing.putIfAbsent(fold, () => word);
      }
    }
    final result = counts.entries
        .map((e) => KeywordCount(casing[e.key]!, e.value))
        .toList();
    result.sort((a, b) {
      final byCount = b.images.compareTo(a.images);
      return byCount != 0
          ? byCount
          : a.keyword.toLowerCase().compareTo(b.keyword.toLowerCase());
    });
    return result;
  }
}
