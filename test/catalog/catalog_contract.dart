// test/catalog/catalog_contract.dart
//
// One suite, run against every CatalogStore there is.
//
// This is the enforcement of PLAN.md section 2's rule, not its documentation.
// If MemoryCatalog and SqliteCatalogStore ever need different assertions, the
// interface has leaked SQLite and the swap-out requirement is already lost.
// Nothing in here may mention a row, a connection or a schema.

import 'package:flutter_test/flutter_test.dart';
import 'package:morphosis/src/catalog/catalog.dart';
import 'package:morphosis/src/model/edit.dart';
import 'package:morphosis/src/model/geometry.dart';

/// Opens a store. Called more than once within a test, it must come back to
/// the same storage, so that close-and-reopen can be exercised.
typedef Connect = Future<CatalogStore> Function();

/// Makes a fresh, empty storage and returns the way to connect to it.
typedef MakeFixture = Connect Function();

// Fixed instants, so that ordering assertions cannot depend on how fast the
// suite runs.
final t0 = DateTime.utc(2025, 1, 1, 12);
final t1 = DateTime.utc(2025, 6, 1, 12);
final t2 = DateTime.utc(2025, 9, 1, 12);

String digest(int n) => n.toRadixString(16).padLeft(64, '0');

CatalogEntry entry(
  int n, {
  String? name,
  int sizeBytes = 1000,
  DateTime? capturedAt,
  String? camera,
  String keywords = '',
  Edit? edit,
  DateTime? firstSeen,
  DateTime? lastEdited,
}) =>
    CatalogEntry(
      sha256: digest(n),
      displayName: name ?? 'DSC_$n.NEF',
      sizeBytes: sizeBytes,
      capturedAt: capturedAt,
      camera: camera,
      keywords: KeywordSet.parse(keywords),
      edit: edit,
      firstSeen: firstSeen ?? t0,
      lastEdited: lastEdited ?? t0,
    );

SeenAt seenAt(String path,
        {int sizeBytes = 1000, DateTime? mtime, DateTime? lastSeen}) =>
    SeenAt(
      path: path,
      sizeBytes: sizeBytes,
      mtime: mtime ?? t0,
      lastSeen: lastSeen ?? t0,
    );

void catalogContract(String name, MakeFixture makeFixture) {
  group(name, () {
    late Connect connect;
    late CatalogStore store;

    setUp(() async {
      connect = makeFixture();
      store = await connect();
    });

    tearDown(() async => store.close());

    // ── Identity ────────────────────────────────────────────────────────

    test('an entry comes back as it went in', () async {
      final e = entry(1,
          capturedAt: t1,
          camera: 'Canon EOS R7',
          keywords: 'gull,north coast');
      await store.put(e);
      expect(await store.byDigest(digest(1)), e);
    });

    test('an unknown digest is null', () async {
      expect(await store.byDigest(digest(99)), isNull);
    });

    test('put is idempotent on the digest', () async {
      await store.put(entry(1, name: 'first.NEF'));
      await store.put(entry(1, name: 'second.NEF'));

      final found = await store.byDigest(digest(1));
      expect(found!.displayName, 'second.NEF');
      // One image, not two: the digest is the identity.
      expect(await store.search(limit: 100), hasLength(1));
    });

    test('a later put cannot rewrite when the image was first seen', () async {
      await store.put(entry(1, firstSeen: t0, lastEdited: t0));
      await store.put(entry(1, firstSeen: t2, lastEdited: t2));

      final found = await store.byDigest(digest(1));
      expect(found!.firstSeen, t0, reason: 'firstSeen must be the earliest');
      expect(found.lastEdited, t2, reason: 'lastEdited must be the latest');
    });

    test('the adjustments survive a round trip', () async {
      const edit = Edit(
        temperatureK: 6400,
        blackEv: -0.6,
        shadowEv: 1.4,
        highlightEv: -0.9,
        whiteEv: 0.4,
        brightnessEv: 0.3,
        contrastEv: 0.7,
        sharpness: 0.6,
        saturation: -22.5,
        vibrance: 9.5,
        highlightRolloff: true,
        geometry: Geometry(
          quarterTurns: 1,
          straightenDegrees: 4,
          crop: CropRect(0.15, 0.1, 0.85, 0.7),
        ),
      );
      await store.put(entry(1, edit: edit));
      expect((await store.byDigest(digest(1)))!.edit, edit);
    });

    test('a frame seen but never worked on has no adjustments', () async {
      await store.put(entry(1));
      final found = await store.byDigest(digest(1));
      expect(found!.edit, isNull);
      expect(found.isWorkedOn, isFalse);
    });

    test('as shot comes back as as-shot, not as a number', () async {
      // Edit.temperatureK is null for "whatever the camera recorded". A store
      // that rounds that to a Kelvin value would silently change the picture.
      await store.put(entry(1, edit: const Edit(temperatureK: null)));
      expect((await store.byDigest(digest(1)))!.edit!.temperatureK, isNull);
    });

    // ── The path hint ───────────────────────────────────────────────────

    group('the path hint', () {
      setUp(() async {
        await store.put(entry(1, sizeBytes: 1000));
        await store.recordLocation(
            digest(1), seenAt('/photos/a.NEF', sizeBytes: 1000, mtime: t1));
      });

      test('hits on an exact triple', () async {
        final found = await store.byPathHint('/photos/a.NEF', 1000, t1);
        expect(found?.sha256, digest(1));
      });

      test('a changed size does not hit', () async {
        expect(await store.byPathHint('/photos/a.NEF', 2000, t1), isNull);
      });

      test('a changed mtime does not hit', () async {
        expect(await store.byPathHint('/photos/a.NEF', 1000, t2), isNull);
      });

      test('an unrecorded path does not hit', () async {
        expect(await store.byPathHint('/photos/z.NEF', 1000, t1), isNull);
      });

      // The hint is a cache, never an identity. A miss means "do not know",
      // so the same content must still be findable the honest way.
      test('a miss does not mean the image is uncatalogued', () async {
        expect(await store.byPathHint('/photos/a.NEF', 2000, t1), isNull);
        expect(await store.byDigest(digest(1)), isNotNull);
      });
    });

    // ── Locations ───────────────────────────────────────────────────────

    group('locations', () {
      test('one image seen in two places has two locations', () async {
        await store.put(entry(1));
        await store.recordLocation(digest(1), seenAt('/card/a.NEF'));
        await store.recordLocation(digest(1), seenAt('/nas/a.NEF'));

        expect(await store.locationsOf(digest(1)), hasLength(2));
        expect(await store.search(limit: 100), hasLength(1));
      });

      test('locations come back most recently seen first', () async {
        await store.put(entry(1));
        await store.recordLocation(digest(1), seenAt('/old', lastSeen: t0));
        await store.recordLocation(digest(1), seenAt('/new', lastSeen: t2));
        await store.recordLocation(digest(1), seenAt('/mid', lastSeen: t1));

        final found = await store.locationsOf(digest(1));
        expect(found.map((l) => l.path), ['/new', '/mid', '/old']);
      });

      test('re-recording a path refreshes it rather than duplicating', () async {
        await store.put(entry(1));
        await store.recordLocation(digest(1), seenAt('/a', lastSeen: t0));
        await store.recordLocation(digest(1), seenAt('/a', lastSeen: t2));

        final found = await store.locationsOf(digest(1));
        expect(found, hasLength(1));
        expect(found.single.lastSeen, t2);
      });

      // The conflict case: the file at that path has been replaced. The
      // catalogue must stop claiming the old content is still there.
      test('a path re-seen with different content moves to it', () async {
        await store.put(entry(1));
        await store.put(entry(2));
        await store.recordLocation(digest(1), seenAt('/a.NEF'));
        await store.recordLocation(digest(2), seenAt('/a.NEF'));

        expect(await store.locationsOf(digest(1)), isEmpty);
        expect(await store.locationsOf(digest(2)), hasLength(1));
        // Both images are still catalogued; only the location moved.
        expect(await store.byDigest(digest(1)), isNotNull);
      });

      test('a location needs an image to belong to', () async {
        expect(() => store.recordLocation(digest(7), seenAt('/a.NEF')),
            throwsStateError);
      });

      test('an image seen nowhere has no locations', () async {
        await store.put(entry(1));
        expect(await store.locationsOf(digest(1)), isEmpty);
      });
    });

    // ── Search ──────────────────────────────────────────────────────────

    group('search', () {
      test('finds by whole keyword, ignoring case', () async {
        await store.put(entry(1, keywords: 'Coast,gull'));
        final found = await store.search(keyword: 'coast');
        expect(found.map((e) => e.sha256), [digest(1)]);
      });

      // The property that would break silently under a schema swap, and the
      // reason the stored form is fenced with separators.
      test('"coast" does not match "coastal"', () async {
        await store.put(entry(1, keywords: 'coastal'));
        expect(await store.search(keyword: 'coast'), isEmpty);
      });

      test('a keyword nobody used finds nothing', () async {
        await store.put(entry(1, keywords: 'gull'));
        expect(await store.search(keyword: 'heron'), isEmpty);
      });

      test('a date range is inclusive of start and exclusive of end', () async {
        await store.put(entry(1, capturedAt: DateTime.utc(2025, 6, 1)));
        await store.put(entry(2, capturedAt: DateTime.utc(2025, 6, 30)));
        await store.put(entry(3, capturedAt: DateTime.utc(2025, 7, 1)));

        final june = await store.search(
            captured: DateRange(
                DateTime.utc(2025, 6, 1), DateTime.utc(2025, 7, 1)));
        expect(june.map((e) => e.sha256).toSet(), {digest(1), digest(2)});
      });

      test('an undated image is absent from a dated search', () async {
        await store.put(entry(1, capturedAt: null));
        await store.put(entry(2, capturedAt: DateTime.utc(2025, 6, 15)));

        final dated = await store.search(
            captured: DateRange(
                DateTime.utc(2025, 6, 1), DateTime.utc(2025, 7, 1)));
        expect(dated.map((e) => e.sha256), [digest(2)]);
        // ...but present when nothing is asked about dates.
        expect(await store.search(limit: 100), hasLength(2));
      });

      test('keyword and date narrow together', () async {
        await store.put(entry(1,
            keywords: 'gull', capturedAt: DateTime.utc(2025, 6, 15)));
        await store.put(entry(2,
            keywords: 'gull', capturedAt: DateTime.utc(2025, 8, 15)));

        final found = await store.search(
            keyword: 'gull',
            captured: DateRange(
                DateTime.utc(2025, 6, 1), DateTime.utc(2025, 7, 1)));
        expect(found.map((e) => e.sha256), [digest(1)]);
      });

      test('most recently edited first', () async {
        await store.put(entry(1, lastEdited: t0));
        await store.put(entry(2, lastEdited: t2));
        await store.put(entry(3, lastEdited: t1));

        final found = await store.search(limit: 100);
        expect(found.map((e) => e.sha256), [digest(2), digest(3), digest(1)]);
      });

      test('paging covers everything once, with no gap and no repeat', () async {
        // All written at the same instant, so the tie-break is what carries
        // the ordering. Without one, paging repeats and skips entries.
        for (var i = 1; i <= 10; i++) {
          await store.put(entry(i, lastEdited: t1));
        }
        final seen = <String>[];
        for (var offset = 0; offset < 10; offset += 3) {
          seen.addAll(
              (await store.search(limit: 3, offset: offset)).map((e) => e.sha256));
        }
        expect(seen, hasLength(10));
        expect(seen.toSet(), hasLength(10));
      });

      test('an offset past the end is empty, not an error', () async {
        await store.put(entry(1));
        expect(await store.search(limit: 10, offset: 50), isEmpty);
      });
    });

    // ── Keywords ────────────────────────────────────────────────────────

    group('keywords()', () {
      test('counts images, not occurrences', () async {
        await store.put(entry(1, keywords: 'gull,coast'));
        await store.put(entry(2, keywords: 'gull'));

        final counts = await store.keywords();
        expect(counts, contains(const KeywordCount('gull', 2)));
        expect(counts, contains(const KeywordCount('coast', 1)));
      });

      test('groups case-insensitively and offers the first casing', () async {
        await store.put(entry(1, keywords: 'Coast'));
        await store.put(entry(2, keywords: 'coast'));

        final counts = await store.keywords();
        expect(counts, hasLength(1));
        expect(counts.single.images, 2);
        expect(counts.single.keyword.toLowerCase(), 'coast');
      });

      test('commonest first, then alphabetical', () async {
        await store.put(entry(1, keywords: 'rare,common'));
        await store.put(entry(2, keywords: 'common,also'));
        await store.put(entry(3, keywords: 'common'));

        final counts = await store.keywords();
        expect(counts.first, const KeywordCount('common', 3));
        expect(counts.skip(1).map((k) => k.keyword), ['also', 'rare']);
      });

      test('an empty catalogue offers nothing', () async {
        expect(await store.keywords(), isEmpty);
      });
    });

    // ── Durability ──────────────────────────────────────────────────────

    test('what was written is there after closing and reopening', () async {
      await store.put(entry(1,
          keywords: 'gull', capturedAt: t1, edit: const Edit(blackEv: -1.5)));
      await store.recordLocation(digest(1), seenAt('/photos/a.NEF'));
      await store.close();

      store = await connect();
      final found = await store.byDigest(digest(1));
      expect(found, isNotNull);
      expect(found!.keywords.keywords, ['gull']);
      expect(found.capturedAt, t1);
      expect(found.edit!.blackEv, -1.5);
      expect(await store.locationsOf(digest(1)), hasLength(1));
    });

    test('a closed store refuses to answer', () async {
      await store.close();
      expect(() => store.byDigest(digest(1)), throwsStateError);
    });
  });
}
