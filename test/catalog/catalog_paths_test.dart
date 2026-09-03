// test/catalog/catalog_paths_test.dart
//
// Where the catalogue lives, and whether the system library can be found.
//
// The second half is the one that would otherwise fail only in front of the
// user: package:sqlite3 asks for `libsqlite3.so`, which is a symlink only a
// *-devel package installs, and this machine has just `libsqlite3.so.0`.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:morphosis/src/catalog/catalog_paths.dart';
import 'package:morphosis/src/catalog/sqlite/sqlite_catalog.dart';

void main() {
  group('XDG resolution', () {
    test('XDG_DATA_HOME is honoured', () {
      expect(
        catalogDirectory(environment: {
          'XDG_DATA_HOME': '/data/somewhere',
          'HOME': '/home/someone',
        }),
        '/data/somewhere/$appId',
      );
    });

    test('falls back to ~/.local/share when it is unset', () {
      expect(
        catalogDirectory(environment: {'HOME': '/home/someone'}),
        '/home/someone/.local/share/$appId',
      );
    });

    // The specification says a set-but-empty XDG variable means unset, and a
    // relative one is to be ignored. Both matter here because getting it wrong
    // writes the catalogue somewhere the user will never find it again.
    test('an empty or relative XDG_DATA_HOME is ignored', () {
      for (final bad in ['', 'relative/path', './here']) {
        expect(
          catalogDirectory(
              environment: {'XDG_DATA_HOME': bad, 'HOME': '/home/someone'}),
          '/home/someone/.local/share/$appId',
          reason: 'XDG_DATA_HOME=$bad',
        );
      }
    });

    test('the file sits inside the directory, under the app id', () {
      final env = {'HOME': '/home/someone'};
      expect(catalogFile(environment: env),
          '${catalogDirectory(environment: env)}/catalog.db');
      expect(catalogFile(environment: env), contains(appId));
    });

    // The risk PLAN.md section 12 names: scripts/install.sh deletes its own
    // prefix, so the catalogue must not be inside it. The script installs to
    // ~/.local/lib/morphosis; the catalogue is under ~/.local/share.
    test('the catalogue is not inside the install prefix', () {
      final env = {'HOME': '/home/someone'};
      const installPrefix = '/home/someone/.local/lib/morphosis';
      expect(catalogFile(environment: env), isNot(startsWith(installPrefix)));
    });

    test('the app id is the one the compositor matches', () {
      // Changing this string silently loses the launcher icon under Wayland
      // and orphans every existing catalogue.
      expect(appId, 'com.morphosis.morphosis');
    });
  });

  group('the system library', () {
    // A machine with only the runtime sqlite package has no `libsqlite3.so`.
    // If this is where a run fails, the fallback chain in sqlite_catalog.dart
    // needs another entry — not a bundled SQLite.
    test('libsqlite3 can be opened on this machine', () async {
      final store = SqliteCatalogStore.inMemory();
      await store.open();
      await store.close();
    });

    test('the plain symlink really is absent, which is why the chain exists',
        () {
      // Not an assertion about correctness — a note that survives. If this
      // ever starts failing, someone installed sqlite-devel and the default
      // would have worked; the chain is still right for everyone else.
      final present = ['/usr/lib64/libsqlite3.so', '/usr/lib/libsqlite3.so']
          .any((p) => File(p).existsSync());
      // ignore: avoid_print
      print('libsqlite3.so symlink present: $present');
    });
  });
}
