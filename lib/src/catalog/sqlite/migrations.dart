// lib/src/catalog/sqlite/migrations.dart
//
// Schema versions, forward-only, keyed on PRAGMA user_version.
//
// There is no downgrade path. An older build refusing to open a newer
// catalogue is better than one silently misreading it — the same reasoning
// Edit.fromJson applies to a stored edit.
//
// Each migration is an idempotent function and they run in order, so a
// catalogue at any version reaches the current one by running the tail of the
// list.

import 'package:sqlite3/sqlite3.dart';

/// The version this build writes. Bump it by adding to [_migrations].
int get schemaVersion => _migrations.length;

typedef Migration = void Function(Database db);

const List<Migration> _migrations = [_v1];

/// Bring a database up to [schemaVersion].
void migrate(Database db) {
  final found = db.userVersion;
  if (found > schemaVersion) {
    throw StateError(
      'This catalogue is schema version $found; this build reads up to '
      '$schemaVersion. A newer version of Morphosis has opened it.',
    );
  }
  if (found == schemaVersion) return;

  db.execute('BEGIN');
  try {
    for (var v = found; v < schemaVersion; v++) {
      _migrations[v](db);
    }
    db.userVersion = schemaVersion;
    db.execute('COMMIT');
  } catch (_) {
    db.execute('ROLLBACK');
    rethrow;
  }
}

/// Two tables, because an image and a place it has been seen are different
/// things. PLAN.md section 5, with two deviations noted below.
void _v1(Database db) {
  db.execute('''
    CREATE TABLE image (
      sha256        TEXT PRIMARY KEY,           -- lowercase hex, 64 chars
      display_name  TEXT NOT NULL,              -- the name most recently seen
      size_bytes    INTEGER NOT NULL,
      captured_at   INTEGER,                    -- NULL if the file says nothing
      camera        TEXT,
      keywords      TEXT NOT NULL DEFAULT '',   -- comma-separated, as requested
      -- Lowercased and fenced with commas: ",gull,north coast,". Searching it
      -- with instr() for ",gull," is what makes "coast" fail to match
      -- "coastal" without a LIKE pattern that would need escaping. Derived
      -- from `keywords` on every write and never read back into a value.
      keywords_fold TEXT NOT NULL DEFAULT '',
      edit_json     TEXT,                       -- NULL until first worked on
      edit_version  INTEGER,
      first_seen    INTEGER NOT NULL,
      last_edited   INTEGER NOT NULL
    )
  ''');

  db.execute('''
    CREATE TABLE location (
      -- PLAN.md section 5 has PRIMARY KEY (sha256, path). Keying on path
      -- alone instead: a path holds one file at a time, so the composite key
      -- permits a state that cannot exist — one path claimed by two digests —
      -- and the conflict rule would then have to be enforced by hand on every
      -- write instead of by the schema. It also makes the hint lookup a
      -- primary-key probe.
      path        TEXT PRIMARY KEY,
      sha256      TEXT NOT NULL REFERENCES image(sha256) ON DELETE CASCADE,
      mtime       INTEGER NOT NULL,
      size_bytes  INTEGER NOT NULL,
      last_seen   INTEGER NOT NULL
    )
  ''');

  // locationsOf() looks up every path for one image; the path side is already
  // the primary key.
  db.execute('CREATE INDEX location_sha ON location(sha256)');
  db.execute('CREATE INDEX image_captured ON image(captured_at)');
}
