// lib/src/catalog/catalog_entry.dart
//
// The values the catalogue is made of. Plain Dart — no Flutter, no SQL, no
// generated id. A store implementation may hold rows; nothing outside it may
// know that.

import '../model/edit.dart';
import 'keyword_set.dart';

/// One catalogued image, identified by the content of the file.
///
/// The digest is the identity: two files with the same digest are the same
/// bytes, so a path is merely somewhere this image has been seen. That is why
/// there is no id here and no path either — see [SeenAt].
class CatalogEntry {
  /// Lowercase hex, 64 characters.
  final String sha256;

  /// The name most recently seen. A rename is not a new image.
  final String displayName;

  final int sizeBytes;

  /// When the photograph was taken, or null when the file says nothing.
  /// Stored as UTC; see the note on [firstSeen].
  final DateTime? capturedAt;

  /// "Canon EOS R7", for a legible catalogue. Null when unknown.
  final String? camera;

  final KeywordSet keywords;

  /// The adjustments, or null for an image that has been seen but never
  /// worked on. Null is the distinction: a frame merely opened records that it
  /// was seen without claiming an edit the photographer never made.
  final Edit? edit;

  /// Times are held in UTC throughout the catalogue and converted to local
  /// exactly once, in the UI. PLAN.md section 12: getting this wrong produces
  /// dates that are right for most of the year.
  final DateTime firstSeen;
  final DateTime lastEdited;

  CatalogEntry({
    required this.sha256,
    required this.displayName,
    required this.sizeBytes,
    DateTime? capturedAt,
    this.camera,
    this.keywords = KeywordSet.empty,
    this.edit,
    required DateTime firstSeen,
    required DateTime lastEdited,
  })  : capturedAt = capturedAt?.toUtc(),
        firstSeen = firstSeen.toUtc(),
        lastEdited = lastEdited.toUtc();

  /// True once the photographer has actually done something to this frame.
  bool get isWorkedOn => edit != null || keywords.isNotEmpty;

  CatalogEntry copyWith({
    String? displayName,
    int? sizeBytes,
    DateTime? capturedAt,
    String? camera,
    KeywordSet? keywords,
    Edit? edit,
    bool clearEdit = false,
    DateTime? firstSeen,
    DateTime? lastEdited,
  }) =>
      CatalogEntry(
        sha256: sha256,
        displayName: displayName ?? this.displayName,
        sizeBytes: sizeBytes ?? this.sizeBytes,
        capturedAt: capturedAt ?? this.capturedAt,
        camera: camera ?? this.camera,
        keywords: keywords ?? this.keywords,
        edit: clearEdit ? null : (edit ?? this.edit),
        firstSeen: firstSeen ?? this.firstSeen,
        lastEdited: lastEdited ?? this.lastEdited,
      );

  @override
  bool operator ==(Object other) =>
      other is CatalogEntry &&
      other.sha256 == sha256 &&
      other.displayName == displayName &&
      other.sizeBytes == sizeBytes &&
      other.capturedAt == capturedAt &&
      other.camera == camera &&
      other.keywords == keywords &&
      other.edit == edit &&
      other.firstSeen == firstSeen &&
      other.lastEdited == lastEdited;

  @override
  int get hashCode => Object.hash(sha256, displayName, sizeBytes, capturedAt,
      camera, keywords, edit, firstSeen, lastEdited);

  @override
  String toString() => 'CatalogEntry($displayName, ${sha256.substring(0, 8)}…)';
}

/// Somewhere an image has been seen. Many of these per image.
///
/// The triple (path, size, mtime) is the hint that lets a folder listing avoid
/// hashing. It is a cache and never an identity: a file replaced in place
/// within the same second with the same size defeats it, which is why the
/// digest is refreshed whenever a frame is actually opened.
class SeenAt {
  final String path;
  final int sizeBytes;
  final DateTime mtime;
  final DateTime lastSeen;

  SeenAt({
    required this.path,
    required this.sizeBytes,
    required DateTime mtime,
    required DateTime lastSeen,
  })  : mtime = mtime.toUtc(),
        lastSeen = lastSeen.toUtc();

  @override
  bool operator ==(Object other) =>
      other is SeenAt &&
      other.path == path &&
      other.sizeBytes == sizeBytes &&
      other.mtime == mtime &&
      other.lastSeen == lastSeen;

  @override
  int get hashCode => Object.hash(path, sizeBytes, mtime, lastSeen);

  @override
  String toString() => 'SeenAt($path)';
}

/// A keyword and how many images carry it. For autocomplete.
///
/// The interface returns this rather than a bare string so that the
/// comma-separated column in PLAN.md section 5 can be replaced by a proper
/// keyword table without anything outside the store noticing.
class KeywordCount {
  /// As first typed — the casing offered thereafter.
  final String keyword;
  final int images;

  const KeywordCount(this.keyword, this.images);

  @override
  bool operator ==(Object other) =>
      other is KeywordCount &&
      other.keyword == keyword &&
      other.images == images;

  @override
  int get hashCode => Object.hash(keyword, images);

  @override
  String toString() => 'KeywordCount($keyword, $images)';
}

/// A half-open interval, `start` inclusive and `end` exclusive.
///
/// Deliberately not Flutter's `DateTimeRange`: the catalogue runs in an
/// isolate with no widget binding, and dragging Material into it would mean
/// the store could not be opened from a plain `dart test`. Half-open because
/// "August" should be one range, not one that has to know August has 31 days.
class DateRange {
  final DateTime start;
  final DateTime end;

  DateRange(DateTime start, DateTime end)
      : start = start.toUtc(),
        end = end.toUtc();

  bool contains(DateTime when) {
    final t = when.toUtc();
    return !t.isBefore(start) && t.isBefore(end);
  }

  @override
  bool operator ==(Object other) =>
      other is DateRange && other.start == start && other.end == end;

  @override
  int get hashCode => Object.hash(start, end);

  @override
  String toString() => 'DateRange($start, $end)';
}
