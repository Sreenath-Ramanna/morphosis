// lib/src/ui/keyword_panel.dart
//
// The keyword editor, in the bottom third of the left column.
//
// Stored as one comma-separated string, exactly as the request asks, and
// edited as chips. The two are not in tension: KeywordSet owns the round trip,
// so what is typed, what is shown and what is stored cannot drift apart. A
// plain text field would be simpler and worse — a stray comma there silently
// creates an empty keyword, and nothing tells the photographer it happened.
//
// Autocomplete matters more than it looks. A catalogue that accumulates
// "coast", "Coast" and "coastal" as three separate keywords is useless within
// a year, and offering what has already been used is what prevents it.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../catalog/catalog.dart';
import 'theme.dart';

class KeywordPanel extends StatefulWidget {
  final KeywordSet keywords;

  /// Every keyword in the catalogue, commonest first. Drives both the
  /// suggestions and the "12 images share this" line.
  final List<KeywordCount> known;

  /// Null disables the control — no frame open, or no catalogue.
  final ValueChanged<KeywordSet>? onChanged;

  const KeywordPanel({
    super.key,
    required this.keywords,
    required this.known,
    this.onChanged,
  });

  @override
  State<KeywordPanel> createState() => _KeywordPanelState();
}

class _KeywordPanelState extends State<KeywordPanel> {
  final TextEditingController _field = TextEditingController();
  final FocusNode _focus = FocusNode();

  @override
  void dispose() {
    _field.dispose();
    _focus.dispose();
    super.dispose();
  }

  bool get _enabled => widget.onChanged != null;

  /// Commit whatever is in the field.
  ///
  /// The text is parsed rather than appended, so "gull, coast," in one paste
  /// becomes two keywords and no empty one — the same rule that applies to the
  /// stored string.
  void _commit([String? text]) {
    final typed = text ?? _field.text;
    if (typed.trim().isEmpty) {
      _field.clear();
      return;
    }
    var next = widget.keywords;
    for (final word in KeywordSet.parse(typed).keywords) {
      // Offer the casing already in the catalogue, so that typing "coast"
      // where "Coast" exists does not split the two.
      next = next.add(_knownCasing(word));
    }
    _field.clear();
    if (next != widget.keywords) widget.onChanged!(next);
  }

  String _knownCasing(String word) {
    final fold = word.toLowerCase();
    for (final k in widget.known) {
      if (k.keyword.toLowerCase() == fold) return k.keyword;
    }
    return word;
  }

  void _remove(String word) => widget.onChanged!(widget.keywords.remove(word));

  /// Keywords already in the catalogue that start with what is being typed and
  /// are not on this frame yet.
  List<KeywordCount> get _suggestions {
    final typed = _field.text.trim().toLowerCase();
    if (typed.isEmpty) return const [];
    return widget.known
        .where((k) =>
            k.keyword.toLowerCase().startsWith(typed) &&
            !widget.keywords.contains(k.keyword))
        .take(4)
        .toList();
  }

  /// How many other images share the keywords on this frame — the line at the
  /// bottom. Shown for the commonest one, which is the useful one.
  String? get _sharedLine {
    if (widget.keywords.isEmpty) return null;
    KeywordCount? best;
    for (final word in widget.keywords.keywords) {
      for (final k in widget.known) {
        if (k.keyword.toLowerCase() != word.toLowerCase()) continue;
        if (best == null || k.images > best.images) best = k;
      }
    }
    if (best == null || best.images < 2) return null;
    return '${best.images} images share “${best.keyword}”';
  }

  @override
  Widget build(BuildContext context) {
    final shared = _sharedLine;
    final suggestions = _suggestions;

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('KEYWORDS', style: Chrome.heading),
          const SizedBox(height: 8),

          Expanded(
            child: SingleChildScrollView(
              child: Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final word in widget.keywords.keywords)
                    _Chip(
                      label: word,
                      onRemove: _enabled ? () => _remove(word) : null,
                    ),
                  if (widget.keywords.isEmpty)
                    Text(
                      _enabled ? 'None yet.' : 'Open a frame to add keywords.',
                      style: Chrome.label,
                    ),
                ],
              ),
            ),
          ),

          if (suggestions.isNotEmpty) ...[
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final k in suggestions)
                  _Suggestion(
                    count: k,
                    onTap: () => _commit(k.keyword),
                  ),
              ],
            ),
          ],

          const SizedBox(height: 8),
          // Enter commits, and so does a comma — typing "gull," should not
          // leave a dangling separator in the field.
          Shortcuts(
            // Every editor binding, neutralised for as long as this field has
            // focus. They are all keys a photographer types: the arrows move
            // the caret rather than stepping through the folder, and the
            // hyphen belongs in "back-lit" rather than zooming the canvas out
            // from under them. A key handled here never reaches the editor's
            // Shortcuts, because resolution walks up from the focused node and
            // stops at the first match.
            shortcuts: const <ShortcutActivator, Intent>{
              SingleActivator(LogicalKeyboardKey.arrowLeft):
                  DoNothingAndStopPropagationTextIntent(),
              SingleActivator(LogicalKeyboardKey.arrowRight):
                  DoNothingAndStopPropagationTextIntent(),
              SingleActivator(LogicalKeyboardKey.minus):
                  DoNothingAndStopPropagationTextIntent(),
              SingleActivator(LogicalKeyboardKey.equal):
                  DoNothingAndStopPropagationTextIntent(),
              SingleActivator(LogicalKeyboardKey.equal, shift: true):
                  DoNothingAndStopPropagationTextIntent(),
              SingleActivator(LogicalKeyboardKey.add):
                  DoNothingAndStopPropagationTextIntent(),
              SingleActivator(LogicalKeyboardKey.numpadAdd):
                  DoNothingAndStopPropagationTextIntent(),
              SingleActivator(LogicalKeyboardKey.numpadSubtract):
                  DoNothingAndStopPropagationTextIntent(),
            },
            child: TextField(
              controller: _field,
              focusNode: _focus,
              enabled: _enabled,
              style: Chrome.value,
              cursorColor: Chrome.accent,
              decoration: InputDecoration(
                isDense: true,
                hintText: 'add keyword…',
                hintStyle: Chrome.label,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                filled: true,
                fillColor: Chrome.panelRaised,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(4),
                  borderSide: const BorderSide(color: Chrome.divider),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(4),
                  borderSide: const BorderSide(color: Chrome.divider),
                ),
              ),
              onChanged: (text) {
                if (text.endsWith(',')) {
                  _commit();
                } else {
                  setState(() {});
                }
              },
              onSubmitted: (_) {
                _commit();
                // Keep the focus: adding several keywords in a row is the
                // normal case, and having to click back each time is not.
                _focus.requestFocus();
              },
            ),
          ),

          if (shared != null) ...[
            const SizedBox(height: 8),
            Text(shared, style: Chrome.label),
          ],
        ],
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  final String label;
  final VoidCallback? onRemove;

  const _Chip({required this.label, this.onRemove});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.only(left: 8, right: 4, top: 3, bottom: 3),
        decoration: BoxDecoration(
          color: Chrome.panelRaised,
          borderRadius: BorderRadius.circular(3),
          border: Border.all(color: Chrome.divider),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(label, style: Chrome.value),
            const SizedBox(width: 2),
            InkWell(
              onTap: onRemove,
              borderRadius: BorderRadius.circular(2),
              child: Padding(
                padding: const EdgeInsets.all(2),
                child: Icon(Icons.close,
                    size: 12,
                    color: onRemove == null ? Chrome.divider : Chrome.textDim),
              ),
            ),
          ],
        ),
      );
}

class _Suggestion extends StatelessWidget {
  final KeywordCount count;
  final VoidCallback onTap;

  const _Suggestion({required this.count, required this.onTap});

  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(3),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(3),
            border: Border.all(color: Chrome.accent.withValues(alpha: 0.5)),
          ),
          child: Text('${count.keyword}  ${count.images}',
              style: const TextStyle(fontSize: 11, color: Chrome.accent)),
        ),
      );
}
