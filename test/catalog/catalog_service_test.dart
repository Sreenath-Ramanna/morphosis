// test/catalog/catalog_service_test.dart
//
// The same contract again, this time down a port.
//
// CatalogService implements CatalogStore, so if the isolate is transparent the
// suite passes untouched — and if it is not, it fails here rather than as a
// dropped frame in front of the user. It also proves every value the port
// carries can actually cross an isolate boundary, which nothing else checks.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:morphosis/src/catalog/catalog_service.dart';

import 'catalog_contract.dart';

void main() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('morphosis_service'));
  tearDown(() => tmp.deleteSync(recursive: true));

  catalogContract('CatalogService', () {
    final file = '${tmp.path}/catalog.db';
    return () async => CatalogService.start(file);
  });

  test('a catalogue that cannot be opened fails at start, not later',
      () async {
    // A directory where the file should be: sqlite3 cannot open it. The point
    // is where this surfaces — awaiting start() — rather than on some later
    // query, by which time the app has told the user everything is fine.
    final asDirectory = '${tmp.path}/wedged.db';
    Directory(asDirectory).createSync();
    expect(CatalogService.start(asDirectory), throwsA(isA<StateError>()));
  });

  test('closing twice is not an error', () async {
    final service = await CatalogService.start('${tmp.path}/twice.db');
    await service.close();
    await service.close();
  });
}
