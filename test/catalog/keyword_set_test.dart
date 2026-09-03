// test/catalog/keyword_set_test.dart
//
// Properties of the keyword round trip. These are the rules the panel and the
// store both rely on, so they are stated once here rather than being assumed
// twice.

import 'package:flutter_test/flutter_test.dart';
import 'package:morphosis/src/catalog/keyword_set.dart';

void main() {
  group('parsing', () {
    test('a stray comma does not become an empty keyword', () {
      expect(KeywordSet.parse('a,,b,').keywords, ['a', 'b']);
      expect(KeywordSet.parse(',').keywords, isEmpty);
      expect(KeywordSet.parse('').keywords, isEmpty);
      expect(KeywordSet.parse(null).keywords, isEmpty);
    });

    test('the ends are trimmed and the middle is left alone', () {
      expect(KeywordSet.parse('  gull , north coast ').keywords,
          ['gull', 'north coast']);
    });

    test('whitespace alone is not a keyword', () {
      expect(KeywordSet.parse('a,   ,b').keywords, ['a', 'b']);
    });

    test('duplicates collapse without regard to case, first casing wins', () {
      expect(KeywordSet.parse('Coast, coast, COAST').keywords, ['Coast']);
      expect(KeywordSet.parse('coast, Coast').keywords, ['coast']);
    });

    test('order is the order typed, not sorted', () {
      expect(KeywordSet.parse('zebra,apple,mongoose').keywords,
          ['zebra', 'apple', 'mongoose']);
    });
  });

  group('storage', () {
    // The property that matters: normalising an already-normalised string
    // changes nothing. Without it a value could drift a little on each save.
    test('normalisation is idempotent', () {
      const nasty = [
        'a,,b,',
        '  spaced  ,  out  ',
        'Coast,coast',
        ',,,',
        '',
        'one',
        'a,b,c,a,B',
        'north coast,gull',
      ];
      for (final input in nasty) {
        final once = KeywordSet.parse(input).toStorage();
        final twice = KeywordSet.parse(once).toStorage();
        expect(twice, once, reason: 'not idempotent for "$input"');
      }
    });

    test('a set survives a round trip through storage exactly', () {
      final set = KeywordSet.parse('gull, north coast, Tide');
      expect(KeywordSet.parse(set.toStorage()), set);
    });

    test('storage never contains an empty segment', () {
      // An empty set stores as "", which splits to one empty segment and has
      // no keywords in it. Everything else must split cleanly — that is what
      // the fenced search form in KeywordSet relies on.
      for (final input in ['a,,b,', ',', 'a, ,b', '']) {
        final set = KeywordSet.parse(input);
        final stored = set.toStorage();
        if (set.isEmpty) {
          expect(stored, '', reason: 'no keywords should store as ""');
          continue;
        }
        expect(stored.split(',').where((s) => s.isEmpty), isEmpty,
            reason: 'empty segment in "$stored"');
      }
    });
  });

  group('the search form', () {
    // This is why toStorage may not contain an empty segment: the fencing is
    // what stops a needle landing inside a longer word, and ",,"  in the
    // middle would let an empty needle match everything.
    test('a keyword is fenced, so it cannot match inside a longer word', () {
      final set = KeywordSet.parse('coastal,gull');
      expect(set.foldedForSearch().contains(KeywordSet.needleFor('coast')),
          isFalse);
      expect(set.foldedForSearch().contains(KeywordSet.needleFor('coastal')),
          isTrue);
    });

    test('matching ignores case on both sides', () {
      final set = KeywordSet.parse('Coast');
      expect(set.foldedForSearch().contains(KeywordSet.needleFor('COAST')),
          isTrue);
    });

    test('an image with no keywords matches nothing', () {
      expect(KeywordSet.empty.foldedForSearch(), '');
      expect(KeywordSet.empty.foldedForSearch()
          .contains(KeywordSet.needleFor('coast')), isFalse);
    });
  });

  group('editing', () {
    test('add is a no-op when the keyword is already there in any case', () {
      final set = KeywordSet.parse('Coast');
      expect(set.add('coast'), set);
      expect(set.add('gull').keywords, ['Coast', 'gull']);
    });

    test('remove ignores case and leaves the rest in order', () {
      final set = KeywordSet.parse('a,B,c');
      expect(set.remove('b').keywords, ['a', 'c']);
      expect(set.remove('missing'), set);
    });

    test('contains ignores case and surrounding space', () {
      expect(KeywordSet.parse('Coast').contains(' coast '), isTrue);
    });
  });

  test('equality is order-sensitive, because order is shown to the user', () {
    expect(KeywordSet.parse('a,b'), KeywordSet.parse('a,b'));
    expect(KeywordSet.parse('a,b'), isNot(KeywordSet.parse('b,a')));
    expect(KeywordSet.parse('a,b').hashCode, KeywordSet.parse('a,b').hashCode);
  });
}
