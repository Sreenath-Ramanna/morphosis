// lib/src/catalog/sqlite/sqlite_catalog.dart
//
// The only file in the project that may import a SQLite package.
//
// PLAN.md section 2: nothing outside this directory may import package:sqlite3,
// and the interface must never expose SQL, a row, a connection, a transaction
// or a generated id. Everything below that line is an implementation detail —
// including, deliberately, the comma-separated keyword column, which section 5
// notes is a table scan and the wrong shape beyond a hundred thousand images.
// The port already returns List<KeywordCount>, so replacing it with a proper
// keyword table changes only this file.

import 'dart:convert';
import 'dart:ffi';

import 'package:sqlite3/open.dart';
import 'package:sqlite3/sqlite3.dart';

import '../../model/edit.dart';
import '../catalog.dart';
import 'migrations.dart';

/// Open the system libsqlite3.
///
/// package:sqlite3 asks for `libsqlite3.so`, which is the symlink a *-devel
/// package installs. A machine with only the runtime package has just
/// `libsqlite3.so.0` — which is the case on this one, and on a stock CI runner
/// — so the default throws at startup. Hence the chain, soname first.
///
/// PLAN.md section 2 chose the system library over a bundled one to match how
/// LibRaw is already handled; this is what that choice costs.
const List<String> _candidates = [
  'libsqlite3.so.0',
  'libsqlite3.so',
  '/usr/lib64/libsqlite3.so.0',
  '/usr/lib/x86_64-linux-gnu/libsqlite3.so.0',
];

DynamicLibrary _openLibsqlite() {
  final failures = <String>[];
  for (final name in _candidates) {
    try {
      return DynamicLibrary.open(name);
    } on ArgumentError catch (e) {
      failures.add('$name: ${e.message}');
    }
  }
  throw StateError(
      'Could not load libsqlite3. Tried:\n  ${failures.join('\n  ')}');
}

bool _openerInstalled = false;

void _installOpener() {
  if (_openerInstalled) return;
  _openerInstalled = true;
  open.overrideFor(OperatingSystem.linux, _openLibsqlite);
}

/// The catalogue, in SQLite.
///
/// One writer, one connection, WAL. Concurrency is not a requirement — one
/// person, one window — and pretending otherwise would add a locking design
/// nobody needs. package:sqlite3 is synchronous FFI, so this must not run on
/// the UI isolate; see CatalogService.
class SqliteCatalogStore implements CatalogStore {
  /// The file, or `:memory:` for a database that lives as long as the object.
  final String path;

  Database? _db;

  SqliteCatalogStore(this.path);

  /// An in-memory catalogue. Not a substitute for MemoryCatalog: this one is
  /// the real implementation and exercises the real schema.
  SqliteCatalogStore.inMemory() : path = ':memory:';

  Database get _open {
    final db = _db;
    if (db == null) throw StateError('The catalogue is not open.');
    return db;
  }

  @override
  Future<void> open() async {
    if (_db != null) return;
    _installOpener();
    final db = sqlite3.open(path);
    // The foreign key on location is only enforced if this is on; SQLite
    // defaults it off for backward compatibility.
    db.execute('PRAGMA foreign_keys = ON');
    if (path != ':memory:') {
      db.execute('PRAGMA journal_mode = WAL');
    }
    migrate(db);
    _db = db;
  }

  @override
  Future<void> close() async {
    _db?.dispose();
    _db = null;
  }

  // ── Reading ─────────────────────────────────────────────────────────────

  static const String _imageColumns = '''
    sha256, display_name, size_bytes, captured_at, camera, keywords,
    edit_json, first_seen, last_edited
  ''';

  /// Times are milliseconds since the epoch, held in UTC.
  ///
  /// PLAN.md section 5 says seconds. Widening costs nothing and removes a
  /// value that does not read back as it was written: a `lastEdited` of
  /// `DateTime.now()` truncated to a second is a small, permanent surprise.
  /// Nothing is lost on `captured_at`, which EXIF gives to the second anyway.
  static int? _millis(DateTime? when) => when?.toUtc().millisecondsSinceEpoch;

  static DateTime? _time(Object? millis) => millis == null
      ? null
      : DateTime.fromMillisecondsSinceEpoch(millis as int, isUtc: true);

  static CatalogEntry _entryFrom(Row row) {
    final editJson = row['edit_json'] as String?;
    return CatalogEntry(
      sha256: row['sha256'] as String,
      displayName: row['display_name'] as String,
      sizeBytes: row['size_bytes'] as int,
      capturedAt: _time(row['captured_at']),
      camera: row['camera'] as String?,
      keywords: KeywordSet.parse(row['keywords'] as String?),
      edit: editJson == null
          ? null
          : Edit.fromJson(jsonDecode(editJson) as Map<String, Object?>),
      firstSeen: _time(row['first_seen'])!,
      lastEdited: _time(row['last_edited'])!,
    );
  }

  static SeenAt _seenAtFrom(Row row) => SeenAt(
        path: row['path'] as String,
        sizeBytes: row['size_bytes'] as int,
        mtime: _time(row['mtime'])!,
        lastSeen: _time(row['last_seen'])!,
      );

  @override
  Future<CatalogEntry?> byDigest(String sha256) async {
    final rows = _open
        .select('SELECT $_imageColumns FROM image WHERE sha256 = ?', [sha256]);
    return rows.isEmpty ? null : _entryFrom(rows.first);
  }

  @override
  Future<CatalogEntry?> byPathHint(
      String path, int sizeBytes, DateTime mtime) async {
    // Both halves of the hint must match. A changed size is a different file;
    // a changed mtime is a file that may have been written to. Either way the
    // answer is "do not know", and the caller must hash rather than conclude
    // the image is uncatalogued.
    final rows = _open.select('''
      SELECT i.sha256, i.display_name, i.size_bytes, i.captured_at, i.camera,
             i.keywords, i.edit_json, i.first_seen, i.last_edited
        FROM location l
        JOIN image i ON i.sha256 = l.sha256
       WHERE l.path = ? AND l.size_bytes = ? AND l.mtime = ?
    ''', [path, sizeBytes, _millis(mtime)]);
    return rows.isEmpty ? null : _entryFrom(rows.first);
  }

  @override
  Future<List<SeenAt>> locationsOf(String sha256) async {
    final rows = _open.select('''
      SELECT path, size_bytes, mtime, last_seen
        FROM location
       WHERE sha256 = ?
       ORDER BY last_seen DESC
    ''', [sha256]);
    return rows.map(_seenAtFrom).toList();
  }

  // ── Writing ─────────────────────────────────────────────────────────────

  @override
  Future<void> put(CatalogEntry entry) async {
    final editJson = entry.edit == null ? null : jsonEncode(entry.edit!.toJson());
    // first_seen is absent from the SET list on purpose: the image was first
    // seen when it was first seen, and a later put is an update, not a chance
    // to rewrite history.
    _open.execute('''
      INSERT INTO image (sha256, display_name, size_bytes, captured_at, camera,
                         keywords, keywords_fold, edit_json, edit_version,
                         first_seen, last_edited)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(sha256) DO UPDATE SET
             display_name  = excluded.display_name,
             size_bytes    = excluded.size_bytes,
             captured_at   = excluded.captured_at,
             camera        = excluded.camera,
             keywords      = excluded.keywords,
             keywords_fold = excluded.keywords_fold,
             edit_json     = excluded.edit_json,
             edit_version  = excluded.edit_version,
             last_edited   = excluded.last_edited
    ''', [
      entry.sha256,
      entry.displayName,
      entry.sizeBytes,
      _millis(entry.capturedAt),
      entry.camera,
      entry.keywords.toStorage(),
      entry.keywords.foldedForSearch(),
      editJson,
      entry.edit == null ? null : Edit.jsonVersion,
      _millis(entry.firstSeen),
      _millis(entry.lastEdited),
    ]);
  }

  @override
  Future<void> recordLocation(String sha256, SeenAt location) async {
    final db = _open;
    // The foreign key would catch this, but as a constraint failure rather
    // than as something a caller can act on.
    final known = db.select('SELECT 1 FROM image WHERE sha256 = ?', [sha256]);
    if (known.isEmpty) {
      throw StateError('No catalogued image with digest $sha256.');
    }
    // The conflict rule is the primary key: a path holds one file, so writing
    // it under a new digest takes it away from the old one. See migrations.
    db.execute('''
      INSERT INTO location (path, sha256, mtime, size_bytes, last_seen)
           VALUES (?, ?, ?, ?, ?)
      ON CONFLICT(path) DO UPDATE SET
             sha256     = excluded.sha256,
             mtime      = excluded.mtime,
             size_bytes = excluded.size_bytes,
             last_seen  = excluded.last_seen
    ''', [
      location.path,
      sha256,
      _millis(location.mtime),
      location.sizeBytes,
      _millis(location.lastSeen),
    ]);
  }

  // ── Search ──────────────────────────────────────────────────────────────

  @override
  Future<List<CatalogEntry>> search({
    String? keyword,
    DateRange? captured,
    int limit = 100,
    int offset = 0,
  }) async {
    final where = <String>[];
    final args = <Object?>[];

    final needle = keyword == null ? '' : KeywordSet.needleFor(keyword);
    if (needle.isNotEmpty) {
      // instr() rather than LIKE: the keyword is user text and may contain %
      // or _, which LIKE would read as wildcards. Both sides are already
      // lowercased in Dart, because SQLite's own lower() is ASCII-only.
      where.add('instr(keywords_fold, ?) > 0');
      args.add(needle);
    }
    if (captured != null) {
      // An image whose file said nothing about when it was taken cannot
      // satisfy a date range; NULL fails the comparison, which is what we want.
      where.add('captured_at >= ? AND captured_at < ?');
      args.addAll([_millis(captured.start), _millis(captured.end)]);
    }

    final clause = where.isEmpty ? '' : 'WHERE ${where.join(' AND ')}';
    // The digest tie-break is what makes paging stable when several images
    // share a last_edited instant. Without it, pages repeat and skip.
    final rows = _open.select('''
      SELECT $_imageColumns FROM image
      $clause
      ORDER BY last_edited DESC, sha256 ASC
      LIMIT ? OFFSET ?
    ''', [...args, limit, offset]);
    return rows.map(_entryFrom).toList();
  }

  @override
  Future<List<KeywordCount>> keywords() async {
    // Counted in Dart rather than in SQL. The stored form is one
    // comma-separated string per image, so counting it in SQL would mean a
    // recursive CTE to split it — more machinery than the scan it saves, at
    // the size this column is the right shape for at all. When that stops
    // being true the fix is a keyword table (PLAN.md section 5), and it lands
    // here without anything outside this file noticing.
    final rows = _open.select('SELECT keywords FROM image');
    final counts = <String, int>{};
    final casing = <String, String>{};
    for (final row in rows) {
      for (final word in KeywordSet.parse(row['keywords'] as String?).keywords) {
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
