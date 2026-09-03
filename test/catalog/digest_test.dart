// test/catalog/digest_test.dart
//
// The digest is the identity of a photograph, so the properties worth testing
// are the ones that would let two different files claim to be the same one, or
// one file claim to be two.

import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:morphosis/src/catalog/digest.dart';

late Directory tmp;

File write(String name, List<int> bytes) =>
    File('${tmp.path}/$name')..writeAsBytesSync(bytes);

void main() {
  setUp(() => tmp = Directory.systemTemp.createTempSync('morphosis_digest'));
  tearDown(() => tmp.deleteSync(recursive: true));

  // The property that matters: streaming must give the same answer as hashing
  // the file whole. Streaming is what keeps 30 MB out of memory, and a chunk
  // boundary bug here would be invisible until two frames collided.
  test('streaming equals hashing the bytes whole', () async {
    final random = Random(20250904);
    for (final size in [0, 1, 63, 64, 65, 4095, 4096, 4097, 200000]) {
      final bytes =
          Uint8List.fromList(List.generate(size, (_) => random.nextInt(256)));
      final file = write('sample_$size.bin', bytes);
      expect(await digestOfFile(file.path), sha256.convert(bytes).toString(),
          reason: 'size $size');
    }
  });

  test('the empty file has the known empty digest', () async {
    final file = write('empty.bin', const []);
    expect(await digestOfFile(file.path),
        'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855');
  });

  test('the form is 64 lowercase hex characters', () async {
    final file = write('a.bin', List.filled(1000, 7));
    final digest = await digestOfFile(file.path);
    expect(digest, hasLength(64));
    expect(RegExp(r'^[0-9a-f]{64}$').hasMatch(digest), isTrue,
        reason: digest);
  });

  test('the same bytes at two paths give the same digest', () async {
    final bytes = List.generate(5000, (i) => i % 251);
    final a = write('card.NEF', bytes);
    final b = write('nas.NEF', bytes);
    expect(await digestOfFile(a.path), await digestOfFile(b.path));
  });

  test('one byte different is a different digest', () async {
    final bytes = List.generate(5000, (i) => i % 251);
    final a = write('a.NEF', bytes);
    final b = write('b.NEF', [...bytes.sublist(0, 4999), 0]);
    expect(await digestOfFile(a.path), isNot(await digestOfFile(b.path)));
  });

  // A frame silently identified as the empty file would collide with every
  // other unreadable frame in the catalogue.
  test('a missing file throws rather than returning a digest', () async {
    expect(digestOfFile('${tmp.path}/nothing.NEF'),
        throwsA(isA<FileSystemException>()));
  });

  test('the isolate gives the same answer as the direct call', () async {
    final file = write('iso.bin', List.generate(100000, (i) => i % 256));
    expect(await digestOfFileOnIsolate(file.path),
        await digestOfFile(file.path));
  });
}
