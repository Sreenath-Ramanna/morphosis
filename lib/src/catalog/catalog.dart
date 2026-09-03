// lib/src/catalog/catalog.dart
//
// The port. Everything the application is allowed to ask the catalogue.
//
// The requirement is that SQLite can be swapped out later, and it is met by
// one rule, from PLAN.md section 2:
//
//   Nothing outside lib/src/catalog/sqlite/ may import a SQLite package, and
//   the interface must never expose SQL, a row, a connection, a transaction,
//   or a generated id.
//
// Notice what is absent below: no execute, no query, no id column, no cursor.
// A replacement backed by Postgres, a document store or a flat file on a NAS
// implements the same ten methods.
//
// MemoryCatalog is not a throwaway. It is what the tests run against, and
// keeping it correct is what proves this interface is not secretly
// SQLite-shaped — test/catalog/catalog_contract_test.dart runs one suite
// against both.

import 'catalog_entry.dart';

export 'catalog_entry.dart';
export 'keyword_set.dart';

abstract interface class CatalogStore {
  Future<void> open();
  Future<void> close();

  /// The catalogued image with this content, wherever it lives.
  Future<CatalogEntry?> byDigest(String sha256);

  /// The fast path: has this exact file been seen before, at this size and
  /// modification time? Answers without hashing.
  ///
  /// **Null means "do not know" — never "no".** A folder listing uses this to
  /// avoid hashing three hundred files; a miss only ever means the hint did
  /// not hit, and the caller must fall back to hashing rather than concluding
  /// the image is uncatalogued.
  Future<CatalogEntry?> byPathHint(String path, int sizeBytes, DateTime mtime);

  /// Record or update an image. Idempotent on the digest.
  ///
  /// A second put of the same digest takes the new mutable values but keeps
  /// the original [CatalogEntry.firstSeen]: the image was first seen when it
  /// was first seen, whatever a later caller passes.
  Future<void> put(CatalogEntry entry);

  /// Note that this image was seen at this location, adding it or refreshing
  /// what is already there.
  ///
  /// A path that was recorded against a *different* digest moves to this one.
  /// That is the conflict case in PLAN.md section 11 — the file at that path
  /// has been replaced — and the catalogue must not go on claiming the old
  /// content is still there. The same digest at a second path is not a
  /// conflict at all; a card and a NAS holding one photograph is normal.
  ///
  /// Throws [StateError] if no image with this digest has been put.
  Future<void> recordLocation(String sha256, SeenAt location);

  /// Every path this content has been seen at, most recently seen first.
  Future<List<SeenAt>> locationsOf(String sha256);

  /// Most recently edited first, ties broken by digest so that paging is
  /// stable. A [keyword] matches whole keywords only and ignores case:
  /// "coast" does not match "coastal".
  Future<List<CatalogEntry>> search({
    String? keyword,
    DateRange? captured,
    int limit = 100,
    int offset = 0,
  });

  /// Every keyword used so far, with the number of images carrying it — for
  /// autocomplete. Commonest first, then alphabetical, so the list is stable.
  Future<List<KeywordCount>> keywords();
}
