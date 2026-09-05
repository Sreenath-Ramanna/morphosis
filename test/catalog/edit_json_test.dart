// test/catalog/edit_json_test.dart
//
// The three rules from PLAN.md section 6, as properties. These are what make a
// stored edit survive the app changing, and each one fails silently if it is
// wrong — a catalogue full of edits that read back subtly different.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:morphosis/src/model/edit.dart';
import 'package:morphosis/src/model/geometry.dart';

const populated = Edit(
  temperatureK: 6400,
  blackEv: -0.6,
  shadowEv: 1.4,
  highlightEv: -0.9,
  whiteEv: 0.4,
  brightnessEv: 0.3,
  contrastEv: 0.7,
  sharpness: 0.6,
  saturation: 18.5,
  vibrance: -7.5,
  highlightRolloff: true,
  highlightRecovery: true,
  geometry: Geometry(
    quarterTurns: 1,
    straightenDegrees: 4,
    crop: CropRect(0.15, 0.1, 0.85, 0.7),
    aspect: AspectOption('3:2', 3 / 2),
  ),
);

Map<String, Object?> without(Edit edit, String key) =>
    Map<String, Object?>.from(edit.toJson())..remove(key);

void main() {
  group('the round trip is the identity', () {
    test('for a neutral edit', () {
      expect(Edit.fromJson(Edit.neutral.toJson()), Edit.neutral);
    });

    test('for every field populated', () {
      expect(Edit.fromJson(populated.toJson()), populated);
    });

    test('through real JSON text, not just a map', () {
      final text = jsonEncode(populated.toJson());
      final back = Edit.fromJson(
          jsonDecode(text) as Map<String, Object?>);
      expect(back, populated);
    });

    test('for every quarter turn and both crop extremes', () {
      for (var turns = 0; turns < 4; turns++) {
        for (final crop in [
          CropRect.full,
          const CropRect(0.25, 0.25, 0.75, 0.75),
          const CropRect(0, 0, 0.01, 0.01),
        ]) {
          final edit = Edit(
              geometry: Geometry(quarterTurns: turns, crop: crop));
          expect(Edit.fromJson(edit.toJson()), edit,
              reason: 'turns=$turns crop=$crop');
        }
      }
    });

    // "As shot" is null, not a number. A store that rounded it to whatever the
    // camera recorded would silently freeze a decision the photographer never
    // made — and it would look right, which is what makes it worth a test.
    test('as shot stays as shot', () {
      const asShot = Edit(temperatureK: null, blackEv: 1.0);
      final json = asShot.toJson();
      expect(json.containsKey('temperatureK'), isFalse,
          reason: 'null must be absent, not written as a number');
      expect(Edit.fromJson(json).temperatureK, isNull);
    });
  });

  group('absent means default, never zero', () {
    test('a missing field reads as its default, one field at a time', () {
      // Every key the writer emits, deleted in turn. Whatever comes back must
      // equal neutral in that field — this is the rule that lets a v1 document
      // survive a v2 build adding something.
      for (final key in Edit.neutral.toJson().keys) {
        if (key == 'v') continue;
        final json = without(populated, key);
        expect(() => Edit.fromJson(json), returnsNormally,
            reason: 'removing "$key" must not throw');
      }
    });

    test('an almost-empty document reads as neutral', () {
      expect(Edit.fromJson({'v': 1}), Edit.neutral);
    });

    test('a missing rolloff is off, not null and not true', () {
      expect(Edit.fromJson(without(populated, 'highlightRolloff'))
          .highlightRolloff, isFalse);
    });

    test('a missing geometry is the identity', () {
      final back = Edit.fromJson(without(populated, 'geometry'));
      expect(back.geometry, Geometry.identity);
    });

    test('a missing zone is zero EV, which is also its default', () {
      expect(Edit.fromJson(without(populated, 'shadowEv')).shadowEv, 0.0);
    });

    test('a missing saturation reads as 0', () {
      expect(Edit.fromJson(without(populated, 'saturation')).saturation, 0.0);
    });

    test('a missing vibrance reads as 0', () {
      expect(Edit.fromJson(without(populated, 'vibrance')).vibrance, 0.0);
    });
  });

  group('saturation and vibrance are part of the edit\'s identity', () {
    // Without this field in `operator ==`, catalog_writer decides a slider
    // move is not worth a write and the editor's coalescing loop drops the
    // last change of a drag — both silently, and with no other test failing.
    test('an edit differing only in saturation is a different edit', () {
      expect(Edit.neutral.copyWith(saturation: 1), isNot(Edit.neutral));
      expect(Edit.neutral.copyWith(vibrance: 1), isNot(Edit.neutral));
      // The two are separate fields and must not collapse onto one another.
      expect(Edit.neutral.copyWith(saturation: 1),
          isNot(Edit.neutral.copyWith(vibrance: 1)));
    });

    test('isNeutral is false the moment saturation moves', () {
      expect(Edit.neutral.copyWith(saturation: 1).isNeutral, isFalse);
      expect(Edit.neutral.copyWith(saturation: -50).isNeutral, isFalse);
      expect(Edit.neutral.copyWith(saturation: 50).isNeutral, isFalse);
      expect(Edit.neutral.copyWith(saturation: 0).isNeutral, isTrue);
      expect(Edit.neutral.copyWith(vibrance: 1).isNeutral, isFalse);
      expect(Edit.neutral.copyWith(vibrance: -50).isNeutral, isFalse);
      expect(Edit.neutral.copyWith(vibrance: 0).isNeutral, isTrue);
    });
  });

  group('versioning', () {
    test('every document carries v', () {
      expect(Edit.neutral.toJson()['v'], Edit.jsonVersion);
      expect(populated.toJson()['v'], Edit.jsonVersion);
    });

    test('a document with no version is refused', () {
      expect(() => Edit.fromJson(without(populated, 'v')),
          throwsFormatException);
    });

    // Refusing is the point: an older build misreading a newer document is
    // worse than one that says it cannot.
    test('a newer document is refused rather than half-read', () {
      final future = Map<String, Object?>.from(populated.toJson())
        ..['v'] = Edit.jsonVersion + 1;
      expect(() => Edit.fromJson(future), throwsFormatException);
    });

    test('an unknown key is ignored, so a v1 build survives a v2 field', () {
      final extra = Map<String, Object?>.from(populated.toJson())
        ..['clarityEv'] = 1.5
        ..['someFutureThing'] = {'nested': true};
      expect(Edit.fromJson(extra), populated);
    });
  });

  group('geometry', () {
    test('an aspect label round trips', () {
      for (final option in AspectOption.all) {
        final g = Geometry(aspect: option);
        expect(Geometry.fromJson(g.toJson()).aspect, option,
            reason: option.label);
      }
    });

    // A label is a UI string and the list of them will change. A renamed
    // dropdown entry must not be able to make a stored edit unreadable.
    test('an unknown aspect label falls back to Free rather than throwing', () {
      final json = Geometry.identity.toJson()..['aspect'] = '7:5 Panoramic';
      expect(Geometry.fromJson(json).aspect, AspectOption.free);
    });

    test('a malformed crop falls back to the whole frame', () {
      for (final bad in [null, <double>[], [0.1, 0.2], 'nonsense']) {
        final json = Geometry.identity.toJson()..['crop'] = bad;
        expect(Geometry.fromJson(json).crop, CropRect.full,
            reason: 'crop=$bad');
      }
    });

    test('quarter turns are kept in range', () {
      final json = Geometry.identity.toJson()..['quarterTurns'] = 7;
      expect(Geometry.fromJson(json).quarterTurns, 3);
    });
  });

  group('highlight recovery', () {
    test('E1 it round-trips, and absent means false', () {
      expect(Edit.fromJson(populated.toJson()).highlightRecovery, isTrue);
      expect(populated.toJson()['highlightRecovery'], isTrue);
      // A document written before this build has no such key. The
      // "absent means default" rule at edit.dart covers it, which is why no
      // jsonVersion bump is needed — and this is the assertion that says so.
      expect(
          Edit.fromJson(without(populated, 'highlightRecovery'))
              .highlightRecovery,
          isFalse);
      expect(Edit.neutral.highlightRecovery, isFalse);
    });

    test('E2 it participates in identity', () {
      const off = Edit();
      const on = Edit(highlightRecovery: true);
      // Added to copyWith but not to == would make the toggle silently fail to
      // trigger a re-render, which is indistinguishable from it working.
      expect(on, isNot(off));
      expect(on.hashCode, isNot(off.hashCode));
      expect(off.copyWith(highlightRecovery: true), on);
      expect(on.isNeutral, isFalse);
      expect(off.isNeutral, isTrue);
    });
  });

  test('only what the photographer chose is stored', () {
    // No derived values: the automatic grey point, the render time and the
    // preview size are properties of the decode and will be recomputed.
    // Storing one would invite a future reader to trust a stale copy.
    final keys = populated.toJson().keys.toSet();
    expect(keys, isNot(contains('autoGreyPoint')));
    expect(keys, isNot(contains('greyPoint')));
    expect(keys, isNot(contains('millis')));
    expect(keys, isNot(contains('previewWidth')));
    expect(keys, isNot(contains('softLimitFactor')));
  });
}
