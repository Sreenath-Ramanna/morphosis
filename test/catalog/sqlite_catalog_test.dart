// test/catalog/sqlite_catalog_test.dart
//
// The same contract, against the real store.
//
// Run against a file rather than :memory: so that closing and reopening means
// what it means in the application: a database on disk, opened again by a
// later run. An in-memory database vanishes when the connection does, which
// would make the durability case pass for the wrong reason.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:morphosis/src/catalog/sqlite/migrations.dart';
import 'package:morphosis/src/catalog/sqlite/sqlite_catalog.dart';
import 'package:sqlite3/sqlite3.dart';

import 'catalog_contract.dart';

void main() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('morphosis_catalog'));
  tearDown(() => tmp.deleteSync(recursive: true));

  catalogContract('SqliteCatalogStore', () {
    final file = '${tmp.path}/catalog.db';
    return () async {
      final store = SqliteCatalogStore(file);
      await store.open();
      return store;
    };
  });

  group('the schema', () {
    late String file;
    setUp(() => file = '${tmp.path}/schema.db');

    // This group reaches past the port to package:sqlite3 on purpose. It is
    // the one place that has to: PLAN.md section 5's forward-only rule is
    // about PRAGMA user_version, and a test that could not read it would be
    // testing nothing.
    int userVersionOf(String path) {
      final db = sqlite3.open(path);
      try {
        return db.userVersion;
      } finally {
        db.dispose();
      }
    }

    test('a fresh catalogue is stamped with the current version', () async {
      final store = SqliteCatalogStore(file);
      await store.open();
      await store.close();
      expect(userVersionOf(file), schemaVersion);
      expect(schemaVersion, greaterThan(0));
    });

    test('reopening does not migrate again', () async {
      final store = SqliteCatalogStore(file);
      await store.open();
      await store.put(entry(1, keywords: 'gull'));
      await store.close();

      // A migration that ran twice would try to CREATE TABLE an existing
      // table and throw, so simply getting here is the assertion — with the
      // data still present to show nothing was rebuilt underneath it.
      final again = SqliteCatalogStore(file);
      await again.open();
      expect((await again.byDigest(digest(1)))!.keywords.keywords, ['gull']);
      await again.close();
      expect(userVersionOf(file), schemaVersion);
    });

    test('the file survives being opened by two stores in turn', () async {
      final a = SqliteCatalogStore(file);
      await a.open();
      await a.put(entry(1, keywords: 'gull'));
      await a.close();

      final b = SqliteCatalogStore(file);
      await b.open();
      expect((await b.byDigest(digest(1)))!.keywords.keywords, ['gull']);
      await b.close();
    });

    // Forward-only, with no downgrade path: an older build refusing to open a
    // newer catalogue is better than one silently misreading it. This is the
    // case that protects a user who runs two builds against one catalogue.
    test('a catalogue written by a newer build is refused', () async {
      final store = SqliteCatalogStore(file);
      await store.open();
      await store.close();

      final db = sqlite3.open(file);
      db.userVersion = schemaVersion + 1;
      db.dispose();

      final older = SqliteCatalogStore(file);
      expect(older.open(), throwsStateError);
    });

    test('a catalogue from an older build is migrated up', () async {
      // Version 0 is what an empty file is, which is the only older version
      // there has ever been. Migrating it must reach the current version and
      // leave a working catalogue.
      File(file).createSync();
      expect(userVersionOf(file), 0);

      final store = SqliteCatalogStore(file);
      await store.open();
      await store.put(entry(1));
      expect(await store.byDigest(digest(1)), isNotNull);
      await store.close();
      expect(userVersionOf(file), schemaVersion);
    });
  });

  test('an in-memory catalogue works, for anything that wants one', () async {
    final store = SqliteCatalogStore.inMemory();
    await store.open();
    await store.put(entry(1, keywords: 'gull'));
    expect((await store.byDigest(digest(1)))!.keywords.keywords, ['gull']);
    await store.close();
  });
}
