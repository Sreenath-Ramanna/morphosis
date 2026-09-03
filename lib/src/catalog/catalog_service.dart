// lib/src/catalog/catalog_service.dart
//
// The catalogue, on its own isolate.
//
// package:sqlite3 is synchronous FFI: every call blocks the isolate it runs
// on. On the UI isolate that is a dropped frame; on the render worker it is
// worse, because that one owns 100–200 MB of pixels and a stall there is a
// canvas that stops following the slider. So the catalogue gets its own,
// long-lived, in the same request/reply shape as Processor.
//
// It implements CatalogStore, so nothing that uses it can tell that there is
// an isolate here at all — which is the same reason the port exists.

import 'dart:async';
import 'dart:isolate';

import 'catalog.dart';
import 'sqlite/sqlite_catalog.dart';

// ── Messages ──────────────────────────────────────────────────────────────
//
// Values only. Everything crossing the port is a plain value the SendPort can
// copy — never a Database, never a store.

class _Req {
  final int id;
  const _Req(this.id);
}

class _ByDigestReq extends _Req {
  final String sha256;
  const _ByDigestReq(super.id, this.sha256);
}

class _ByPathHintReq extends _Req {
  final String path;
  final int sizeBytes;
  final DateTime mtime;
  const _ByPathHintReq(super.id, this.path, this.sizeBytes, this.mtime);
}

class _PutReq extends _Req {
  final CatalogEntry entry;
  const _PutReq(super.id, this.entry);
}

class _RecordLocationReq extends _Req {
  final String sha256;
  final SeenAt location;
  const _RecordLocationReq(super.id, this.sha256, this.location);
}

class _LocationsOfReq extends _Req {
  final String sha256;
  const _LocationsOfReq(super.id, this.sha256);
}

class _SearchReq extends _Req {
  final String? keyword;
  final DateRange? captured;
  final int limit;
  final int offset;
  const _SearchReq(
      super.id, this.keyword, this.captured, this.limit, this.offset);
}

class _KeywordsReq extends _Req {
  const _KeywordsReq(super.id);
}

class _CloseReq extends _Req {
  const _CloseReq(super.id);
}

class _Reply {
  final int id;
  final Object? value;
  final Object? error;
  const _Reply(this.id, this.value, this.error);
}

class _Boot {
  final SendPort reply;
  final String path;
  const _Boot(this.reply, this.path);
}

// ── Client ────────────────────────────────────────────────────────────────

class CatalogService implements CatalogStore {
  final Isolate _isolate;
  final SendPort _commands;
  final ReceivePort _replies;
  final Map<int, Completer<Object?>> _pending;
  int _nextId = 1;
  bool _closed = false;

  CatalogService._(this._isolate, this._commands, this._replies, this._pending);

  /// Start the worker against a catalogue file, and wait until it has opened
  /// and migrated it. A failure to open — a catalogue from a newer build, a
  /// missing libsqlite3 — surfaces here rather than on the first query.
  static Future<CatalogService> start(String path) async {
    final replies = ReceivePort();
    final ready = Completer<Object>();
    final pending = <int, Completer<Object?>>{};

    // One listener for the port's whole life. The worker's first message is
    // either its command port or the error that stopped it from opening;
    // everything after that is a reply.
    replies.listen((msg) {
      if (msg is SendPort) {
        if (!ready.isCompleted) ready.complete(msg);
        return;
      }
      if (msg is _Reply && msg.id == 0) {
        if (!ready.isCompleted) ready.completeError(StateError('${msg.error}'));
        return;
      }
      if (msg is! _Reply) return;
      final c = pending.remove(msg.id);
      if (c == null) return;
      if (msg.error != null) {
        c.completeError(StateError('${msg.error}'));
      } else {
        c.complete(msg.value);
      }
    });

    final isolate = await Isolate.spawn(_workerMain, _Boot(replies.sendPort, path),
        debugName: 'morphosis-catalog');
    try {
      final port = await ready.future;
      return CatalogService._(isolate, port as SendPort, replies, pending);
    } catch (_) {
      isolate.kill(priority: Isolate.immediate);
      replies.close();
      rethrow;
    }
  }

  Future<T> _send<T>(_Req Function(int id) build) {
    if (_closed) throw StateError('The catalogue is not open.');
    final id = _nextId++;
    final c = Completer<Object?>();
    _pending[id] = c;
    _commands.send(build(id));
    return c.future.then((v) => v as T);
  }

  /// The worker opened the catalogue during [start]; there is nothing left to
  /// do. Present because the port has it, and because a caller holding a
  /// CatalogStore must not have to know which implementation it is.
  @override
  Future<void> open() async {}

  @override
  Future<CatalogEntry?> byDigest(String sha256) =>
      _send<CatalogEntry?>((id) => _ByDigestReq(id, sha256));

  @override
  Future<CatalogEntry?> byPathHint(String path, int sizeBytes, DateTime mtime) =>
      _send<CatalogEntry?>((id) => _ByPathHintReq(id, path, sizeBytes, mtime));

  @override
  Future<void> put(CatalogEntry entry) =>
      _send<void>((id) => _PutReq(id, entry));

  @override
  Future<void> recordLocation(String sha256, SeenAt location) =>
      _send<void>((id) => _RecordLocationReq(id, sha256, location));

  @override
  Future<List<SeenAt>> locationsOf(String sha256) =>
      _send<List<SeenAt>>((id) => _LocationsOfReq(id, sha256));

  @override
  Future<List<CatalogEntry>> search({
    String? keyword,
    DateRange? captured,
    int limit = 100,
    int offset = 0,
  }) =>
      _send<List<CatalogEntry>>(
          (id) => _SearchReq(id, keyword, captured, limit, offset));

  @override
  Future<List<KeywordCount>> keywords() =>
      _send<List<KeywordCount>>((id) => _KeywordsReq(id));

  /// Close the database and stop the worker.
  ///
  /// The wait matters: a pending write must reach the file before the isolate
  /// is killed, and the last thing that happens before the app quits is a
  /// flush. Two seconds is far longer than a write takes and short enough not
  /// to hang a quit if the worker is wedged.
  @override
  Future<void> close() async {
    if (_closed) return;
    try {
      await _send<void>((id) => _CloseReq(id))
          .timeout(const Duration(seconds: 2), onTimeout: () {});
    } catch (_) {
      // The worker is going away regardless.
    }
    _closed = true;
    _isolate.kill(priority: Isolate.immediate);
    _replies.close();
  }
}

// ── Worker ────────────────────────────────────────────────────────────────

Future<void> _workerMain(_Boot boot) async {
  final store = SqliteCatalogStore(boot.path);
  try {
    await store.open();
  } catch (e, st) {
    // Reply id 0 is the boot failure: there is no request to attach it to, and
    // the client is waiting on the command port that will now never arrive.
    boot.reply.send(_Reply(0, null, '$e\n$st'));
    return;
  }

  final commands = ReceivePort();
  boot.reply.send(commands.sendPort);

  commands.listen((msg) async {
    if (msg is! _Req) return;
    try {
      final value = await _handle(store, msg);
      boot.reply.send(_Reply(msg.id, value, null));
      if (msg is _CloseReq) commands.close();
    } catch (e, st) {
      boot.reply.send(_Reply(msg.id, null, '$e\n$st'));
    }
  });
}

/// A statement switch rather than an expression one: half of these return
/// nothing, and a reply carrying null is the honest answer for a write.
Future<Object?> _handle(CatalogStore store, _Req req) async {
  switch (req) {
    case _ByDigestReq r:
      return store.byDigest(r.sha256);
    case _ByPathHintReq r:
      return store.byPathHint(r.path, r.sizeBytes, r.mtime);
    case _PutReq r:
      await store.put(r.entry);
      return null;
    case _RecordLocationReq r:
      await store.recordLocation(r.sha256, r.location);
      return null;
    case _LocationsOfReq r:
      return store.locationsOf(r.sha256);
    case _SearchReq r:
      return store.search(
        keyword: r.keyword,
        captured: r.captured,
        limit: r.limit,
        offset: r.offset,
      );
    case _KeywordsReq _:
      return store.keywords();
    case _CloseReq _:
      await store.close();
      return null;
    default:
      throw StateError('Unknown request $req');
  }
}
