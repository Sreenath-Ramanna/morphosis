// test/catalog/memory_catalog_test.dart
//
// The contract, against the in-memory store.

import 'package:morphosis/src/catalog/catalog.dart';
import 'package:morphosis/src/catalog/memory_catalog.dart';

import 'catalog_contract.dart';

void main() {
  catalogContract('MemoryCatalog', () {
    // One instance per test, reconnected rather than rebuilt, so that the
    // close-and-reopen case means the same thing it does for a real database.
    final CatalogStore store = MemoryCatalog();
    return () async {
      await store.open();
      return store;
    };
  });
}
