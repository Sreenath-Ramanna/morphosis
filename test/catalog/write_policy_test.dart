// test/catalog/write_policy_test.dart
//
// PLAN.md section 8, as a table of cases.
//
// No widget tree and no real clock: the timer is injected, so "the timer
// expires" is something the test does rather than waits for. The thing being
// checked throughout is how many writes reach the store, because the whole
// point of the policy is that a slider drag is one write and not thirty.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:morphosis/src/catalog/catalog.dart';
import 'package:morphosis/src/catalog/catalog_writer.dart';
import 'package:morphosis/src/catalog/memory_catalog.dart';
import 'package:morphosis/src/model/edit.dart';

/// Counts what actually reaches the store.
class CountingCatalog implements CatalogStore {
  final CatalogStore _inner;
  int puts = 0;
  int locations = 0;

  CountingCatalog(this._inner);

  @override
  Future<void> put(CatalogEntry entry) {
    puts++;
    return _inner.put(entry);
  }

  @override
  Future<void> recordLocation(String sha256, SeenAt location) {
    locations++;
    return _inner.recordLocation(sha256, location);
  }

  @override
  Future<void> open() => _inner.open();
  @override
  Future<void> close() => _inner.close();
  @override
  Future<CatalogEntry?> byDigest(String sha256) => _inner.byDigest(sha256);
  @override
  Future<CatalogEntry?> byPathHint(String p, int s, DateTime m) =>
      _inner.byPathHint(p, s, m);
  @override
  Future<List<SeenAt>> locationsOf(String sha256) => _inner.locationsOf(sha256);
  @override
  Future<List<CatalogEntry>> search(
          {String? keyword, DateRange? captured, int limit = 100, int offset = 0}) =>
      _inner.search(
          keyword: keyword, captured: captured, limit: limit, offset: offset);
  @override
  Future<List<KeywordCount>> keywords() => _inner.keywords();
}

/// A timer that fires when the test says so, not when time passes.
class ManualTimer implements Timer {
  final void Function() callback;
  bool _cancelled = false;
  ManualTimer(this.callback);

  void fire() {
    if (!_cancelled) callback();
  }

  @override
  void cancel() => _cancelled = true;
  @override
  bool get isActive => !_cancelled;
  @override
  int get tick => 0;
}

const digest = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const otherDigest = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

void main() {
  late CountingCatalog store;
  late CatalogWriter writer;
  late List<ManualTimer> timers;
  late DateTime clock;

  setUp(() async {
    store = CountingCatalog(MemoryCatalog());
    await store.open();
    timers = [];
    clock = DateTime.utc(2025, 9, 4, 10);
    writer = CatalogWriter(
      store,
      schedule: (_, callback) {
        final timer = ManualTimer(callback);
        timers.add(timer);
        return timer;
      },
      // Every write gets a distinct instant, so "did lastEdited move" is
      // answerable.
      now: () => clock = clock.add(const Duration(seconds: 1)),
    );
  });

  Future<CatalogEntry?> openFrame({String sha = digest}) => writer.opened(
        sha256: sha,
        displayName: 'DSC_1436.NEF',
        sizeBytes: 29800000,
        camera: 'Nikon Z 6_2',
        capturedAt: DateTime.utc(2025, 8, 2, 20, 6, 47),
        location: SeenAt(
          path: '/photos/DSC_1436.NEF',
          sizeBytes: 29800000,
          mtime: DateTime.utc(2025, 8, 3),
          lastSeen: DateTime.utc(2025, 9, 4),
        ),
      );

  group('a frame is opened', () {
    test('the row and the location are written, but not an edit', () async {
      final entry = await openFrame();
      expect(store.puts, 1);
      expect(store.locations, 1);
      expect(entry!.edit, isNull, reason: 'opening is not editing');
      expect(entry.isWorkedOn, isFalse);
    });

    test('opening and closing untouched writes no edit', () async {
      await openFrame();
      await writer.closeFrame();
      expect(store.puts, 1, reason: 'only the row from opening');
      expect((await store.byDigest(digest))!.edit, isNull);
    });

    test('reopening keeps the original firstSeen and the stored edit',
        () async {
      await openFrame();
      writer.editChanged(const Edit(blackEv: -1.0));
      await writer.flush();
      final first = (await store.byDigest(digest))!.firstSeen;

      await writer.closeFrame();
      final again = await openFrame();
      expect(again!.firstSeen, first);
      expect(again.edit, const Edit(blackEv: -1.0),
          reason: 'the stored edit is what the editor restores from');
    });

    test('a rename is not a new image', () async {
      await openFrame();
      await writer.closeFrame();
      await writer.opened(
        sha256: digest,
        displayName: 'renamed.NEF',
        sizeBytes: 29800000,
        location: SeenAt(
            path: '/elsewhere/renamed.NEF',
            sizeBytes: 29800000,
            mtime: DateTime.utc(2025, 8, 3),
            lastSeen: DateTime.utc(2025, 9, 5)),
      );
      expect(await store.search(limit: 10), hasLength(1));
      expect((await store.byDigest(digest))!.displayName, 'renamed.NEF');
      expect(await store.locationsOf(digest), hasLength(2));
    });
  });

  group('an adjustment changes', () {
    test('nothing is written until the timer expires', () async {
      await openFrame();
      final before = store.puts;
      writer.editChanged(const Edit(blackEv: -0.5));
      expect(store.puts, before, reason: 'a slider move must not write');
      expect(writer.hasPendingWrite, isTrue);
    });

    // The case the whole class exists for.
    test('thirty changes inside the window are one write', () async {
      await openFrame();
      final before = store.puts;
      for (var i = 1; i <= 30; i++) {
        writer.editChanged(Edit(blackEv: i / 30));
      }
      expect(store.puts, before);

      timers.last.fire();
      await writer.flush();
      expect(store.puts, before + 1);
      // And the value written is the last one, not the first.
      expect((await store.byDigest(digest))!.edit!.blackEv, closeTo(1.0, 1e-9));
    });

    test('each change restarts the timer, so an earlier one cannot fire',
        () async {
      await openFrame();
      writer.editChanged(const Edit(blackEv: -0.5));
      final first = timers.last;
      writer.editChanged(const Edit(blackEv: -0.6));

      expect(first.isActive, isFalse, reason: 'the first timer was cancelled');
      first.fire();
      expect(store.puts, 1, reason: 'a cancelled timer writes nothing');
    });

    test('a slider dragged away and back costs no write', () async {
      await openFrame();
      writer.editChanged(const Edit(blackEv: -0.5));
      await writer.flush();
      final after = store.puts;

      writer.editChanged(const Edit(blackEv: -0.9));
      writer.editChanged(const Edit(blackEv: -0.5));
      await writer.flush();
      expect(store.puts, after);
      expect(writer.hasPendingWrite, isFalse);
    });

    test('lastEdited moves when an edit is written', () async {
      final opened = await openFrame();
      writer.editChanged(const Edit(blackEv: -0.5));
      await writer.flush();
      expect((await store.byDigest(digest))!.lastEdited.isAfter(
          opened!.lastEdited), isTrue);
    });
  });

  group('flushing', () {
    test('a flush writes at once and cancels the pending timer', () async {
      await openFrame();
      writer.editChanged(const Edit(shadowEv: 1.0));
      final timer = timers.last;

      await writer.flush();
      expect(store.puts, 2);
      expect(timer.isActive, isFalse);

      // The cancelled timer firing anyway must not write a second time.
      timer.fire();
      await writer.flush();
      expect(store.puts, 2);
    });

    test('a flush with nothing outstanding writes nothing', () async {
      await openFrame();
      final before = store.puts;
      await writer.flush();
      await writer.flush();
      expect(store.puts, before);
    });

    // Selecting another frame, exporting and quitting all come through here.
    test('leaving the frame flushes what was outstanding', () async {
      await openFrame();
      writer.editChanged(const Edit(contrastEv: 0.4));
      await writer.closeFrame();

      expect((await store.byDigest(digest))!.edit,
          const Edit(contrastEv: 0.4));
      expect(writer.current, isNull);
    });

    test('opening another frame flushes the one being left', () async {
      await openFrame();
      writer.editChanged(const Edit(whiteEv: 0.8));

      await openFrame(sha: otherDigest);
      expect((await store.byDigest(digest))!.edit, const Edit(whiteEv: 0.8));
    });

    test('an adjustment with no frame open is ignored, not an error', () {
      writer.editChanged(const Edit(blackEv: 1.0));
      expect(store.puts, 0);
      expect(writer.hasPendingWrite, isFalse);
    });
  });

  group('keywords', () {
    test('a keyword change is written immediately', () async {
      await openFrame();
      final before = store.puts;
      await writer.keywordsChanged(KeywordSet.parse('gull,coast'));
      expect(store.puts, before + 1);
      expect((await store.byDigest(digest))!.keywords.keywords,
          ['gull', 'coast']);
    });

    test('keywords alone make a frame worked on, with no edit', () async {
      await openFrame();
      await writer.keywordsChanged(KeywordSet.parse('gull'));
      final entry = (await store.byDigest(digest))!;
      expect(entry.edit, isNull);
      expect(entry.isWorkedOn, isTrue);
    });

    test('setting the same keywords again writes nothing', () async {
      await openFrame();
      await writer.keywordsChanged(KeywordSet.parse('gull'));
      final after = store.puts;
      await writer.keywordsChanged(KeywordSet.parse('gull'));
      expect(store.puts, after);
    });

    test('a keyword change carries a pending edit with it', () async {
      await openFrame();
      writer.editChanged(const Edit(sharpness: 0.5));
      await writer.keywordsChanged(KeywordSet.parse('gull'));

      final entry = (await store.byDigest(digest))!;
      expect(entry.keywords.keywords, ['gull']);
      expect(entry.edit, const Edit(sharpness: 0.5),
          reason: 'an immediate write must not discard the debounced one');
      expect(writer.hasPendingWrite, isFalse);
    });
  });

  group('revert', () {
    test('revert clears the stored edit rather than storing neutral', () async {
      await openFrame();
      writer.editChanged(const Edit(blackEv: -1.0));
      await writer.flush();

      await writer.revertEdit();
      final entry = (await store.byDigest(digest))!;
      expect(entry.edit, isNull, reason: 'never adjusted, not adjusted to nil');
    });

    test('choosing neutral is recorded, unlike reverting', () async {
      await openFrame();
      writer.editChanged(const Edit(blackEv: -1.0));
      await writer.flush();

      writer.editChanged(Edit.neutral);
      await writer.flush();
      expect((await store.byDigest(digest))!.edit, Edit.neutral);
    });

    test('revert keeps the keywords', () async {
      await openFrame();
      await writer.keywordsChanged(KeywordSet.parse('gull'));
      writer.editChanged(const Edit(blackEv: -1.0));
      await writer.flush();

      await writer.revertEdit();
      expect((await store.byDigest(digest))!.keywords.keywords, ['gull']);
    });
  });
}
