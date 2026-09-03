// lib/src/catalog/keyword_set.dart
//
// The keywords on one image, as a value.
//
// Stored as the single comma-separated string PLAN.md section 5 specifies, and
// edited as chips. This class owns that round trip, which is the whole reason
// it exists: a text field where a stray comma silently creates an empty
// keyword is unpleasant to use, and a store that round trips "a,,b," into
// three keywords is worse.

/// An ordered set of keywords, deduplicated without regard to case.
///
/// Order is the order the photographer typed, not sorted — it is what they
/// will see in the panel, and reordering it under them would be surprising.
/// Equality is therefore order-sensitive: two sets holding the same words in a
/// different order are different values, and round tripping one through
/// storage must give back the same order it went in with.
class KeywordSet {
  final List<String> _keywords;

  const KeywordSet._(this._keywords);

  static const KeywordSet empty = KeywordSet._([]);

  /// The separator, and the reason nothing here may contain one.
  static const String separator = ',';

  /// Parse the stored form, or anything the user has typed into the field.
  ///
  /// Empty segments are dropped rather than becoming empty keywords, which is
  /// what makes `toStorage` safe to search against: see [foldedForSearch].
  factory KeywordSet.parse(String? text) =>
      KeywordSet.of((text ?? '').split(separator));

  /// Build from arbitrary strings, applying the same rules.
  factory KeywordSet.of(Iterable<String> words) {
    final kept = <String>[];
    final seen = <String>{};
    for (final raw in words) {
      // A keyword may contain interior spaces — "north coast" is one keyword —
      // so only the ends are trimmed.
      final word = raw.trim();
      if (word.isEmpty) continue;
      // First casing wins. Offering "Coast" thereafter is what stops a
      // catalogue splitting into "coast", "Coast" and "COAST" within a year.
      if (seen.add(word.toLowerCase())) kept.add(word);
    }
    return KeywordSet._(List.unmodifiable(kept));
  }

  List<String> get keywords => _keywords;
  bool get isEmpty => _keywords.isEmpty;
  bool get isNotEmpty => _keywords.isNotEmpty;
  int get length => _keywords.length;

  bool contains(String word) {
    final needle = word.trim().toLowerCase();
    return _keywords.any((k) => k.toLowerCase() == needle);
  }

  KeywordSet add(String word) =>
      contains(word) ? this : KeywordSet.of([..._keywords, word]);

  KeywordSet remove(String word) {
    final needle = word.trim().toLowerCase();
    return KeywordSet.of(
        _keywords.where((k) => k.toLowerCase() != needle));
  }

  /// The stored form: exactly the comma-separated string the request asks for.
  String toStorage() => _keywords.join(separator);

  /// The form a store matches against, lowercased and fenced with separators.
  ///
  /// The fencing is what makes "coast" fail to match "coastal": the needle is
  /// `,coast,` and a substring search for it cannot land inside a longer word.
  /// It only works because [KeywordSet.of] has already guaranteed there are no
  /// empty segments — `,,` in the middle would let an empty needle match.
  /// Empty stays empty, so that an image with no keywords matches nothing.
  String foldedForSearch() =>
      isEmpty ? '' : '$separator${_keywords.map((k) => k.toLowerCase()).join(separator)}$separator';

  /// The needle [foldedForSearch] is searched for. Lowercasing happens in Dart
  /// rather than in SQL because SQLite's own `lower()` is ASCII-only.
  static String needleFor(String keyword) {
    final word = keyword.trim().toLowerCase();
    return word.isEmpty ? '' : '$separator$word$separator';
  }

  @override
  bool operator ==(Object other) {
    if (other is! KeywordSet) return false;
    if (other._keywords.length != _keywords.length) return false;
    for (var i = 0; i < _keywords.length; i++) {
      if (other._keywords[i] != _keywords[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hashAll(_keywords);

  @override
  String toString() => 'KeywordSet(${toStorage()})';
}
