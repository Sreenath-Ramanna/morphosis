// lib/src/catalog/catalog_paths.dart
//
// Where the catalogue lives.
//
// Not under sqlite/ because it is not a SQLite concern: any store would want
// the same directory. XDG throughout, honouring XDG_DATA_HOME.
//
// The catalogue is user data — keywords typed and edits made, which nothing
// can regenerate — so it sits in the data directory, not the config one.
// It is deliberately NOT where the application bundle is installed:
// scripts/install.sh begins by deleting its own prefix, so sharing a directory
// would discard the catalogue on every install, silently. See PLAN.md
// sections 3 and 12.

import 'dart:io';

/// The application id. The same string the Wayland compositor matches a window
/// against; see the note in scripts/install.sh.
const String appId = 'com.morphosis.morphosis';

/// `$XDG_DATA_HOME/com.morphosis.morphosis`, or the spec's default.
///
/// An XDG variable that is set but empty means unset, per the specification,
/// and a relative one is to be ignored — both are worth honouring here because
/// getting it wrong writes the catalogue somewhere the user will never find.
String catalogDirectory({Map<String, String>? environment}) {
  final env = environment ?? Platform.environment;
  final configured = env['XDG_DATA_HOME'];
  final base = (configured != null &&
          configured.isNotEmpty &&
          configured.startsWith('/'))
      ? configured
      : '${env['HOME'] ?? '.'}/.local/share';
  return '$base/$appId';
}

/// The database file itself.
String catalogFile({Map<String, String>? environment}) =>
    '${catalogDirectory(environment: environment)}/catalog.db';

/// Create the directory if it is not there. Returns the file path.
Future<String> ensureCatalogFile({Map<String, String>? environment}) async {
  final dir = catalogDirectory(environment: environment);
  await Directory(dir).create(recursive: true);
  return '$dir/catalog.db';
}
