// test/ui/keyword_panel_test.dart
//
// The control's job is the round trip between what is typed and what is
// stored, so these drive the field and assert on the KeywordSet that comes
// out — not on pixels.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:morphosis/src/catalog/catalog.dart';
import 'package:morphosis/src/ui/keyword_panel.dart';
import 'package:morphosis/src/ui/theme.dart';

void main() {
  late List<KeywordSet> emitted;

  Future<void> pump(
    WidgetTester tester, {
    String keywords = '',
    List<KeywordCount> known = const [],
    bool enabled = true,
  }) async {
    emitted = [];
    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(),
      home: Scaffold(
        body: SizedBox(
          width: 260,
          height: 400,
          child: KeywordPanel(
            keywords: KeywordSet.parse(keywords),
            known: known,
            onChanged: enabled ? emitted.add : null,
          ),
        ),
      ),
    ));
  }

  Future<void> type(WidgetTester tester, String text) async {
    await tester.enterText(find.byType(TextField), text);
    await tester.pump();
  }

  Future<void> submit(WidgetTester tester, String text) async {
    await type(tester, text);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
  }

  testWidgets('Enter commits a keyword', (tester) async {
    await pump(tester);
    await submit(tester, 'gull');
    expect(emitted.single.keywords, ['gull']);
  });

  testWidgets('a comma commits without leaving a dangling separator',
      (tester) async {
    await pump(tester);
    await type(tester, 'gull,');
    expect(emitted.single.keywords, ['gull']);
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text,
        isEmpty);
  });

  // The case a plain text field gets wrong silently.
  testWidgets('"a,b," commits two keywords and no empty one', (tester) async {
    await pump(tester);
    await submit(tester, 'a,b,');
    expect(emitted.single.keywords, ['a', 'b']);
  });

  testWidgets('committing nothing emits nothing', (tester) async {
    await pump(tester);
    await submit(tester, '   ');
    expect(emitted, isEmpty);
  });

  testWidgets('a keyword already present is not added twice', (tester) async {
    await pump(tester, keywords: 'gull');
    await submit(tester, 'gull');
    expect(emitted, isEmpty);
  });

  testWidgets('an existing keyword is shown as a chip and can be removed',
      (tester) async {
    await pump(tester, keywords: 'gull,coast');
    expect(find.text('gull'), findsOneWidget);
    expect(find.text('coast'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.close).first);
    await tester.pump();
    expect(emitted.single.keywords, ['coast']);
  });

  group('autocomplete', () {
    const known = [KeywordCount('Coast', 12), KeywordCount('coastal', 3)];

    testWidgets('offers a matching keyword on a case-insensitive prefix',
        (tester) async {
      await pump(tester, known: known);
      await type(tester, 'coa');
      expect(find.textContaining('Coast'), findsWidgets);
    });

    testWidgets('offers nothing for an empty field', (tester) async {
      await pump(tester, known: known);
      expect(find.textContaining('12'), findsNothing);
    });

    testWidgets('does not offer a keyword the frame already has',
        (tester) async {
      await pump(tester, keywords: 'Coast', known: known);
      await type(tester, 'coas');
      // "coastal" is still on offer; "Coast" is already a chip.
      expect(find.text('Coast  12'), findsNothing);
      expect(find.text('coastal  3'), findsOneWidget);
    });

    // The whole reason autocomplete is here: a catalogue that splits into
    // "coast" and "Coast" is useless within a year.
    testWidgets('typing a known keyword in another casing stores the stored '
        'casing', (tester) async {
      await pump(tester, known: known);
      await submit(tester, 'COAST');
      expect(emitted.single.keywords, ['Coast']);
    });

    testWidgets('tapping a suggestion commits it', (tester) async {
      await pump(tester, known: known);
      await type(tester, 'coas');
      await tester.tap(find.text('Coast  12'));
      await tester.pump();
      expect(emitted.single.keywords, ['Coast']);
    });
  });

  testWidgets('the shared line names the commonest keyword', (tester) async {
    await pump(tester,
        keywords: 'gull,coast',
        known: const [KeywordCount('coast', 12), KeywordCount('gull', 2)]);
    expect(find.textContaining('12 images share'), findsOneWidget);
  });

  testWidgets('a keyword on one image alone says nothing', (tester) async {
    await pump(tester,
        keywords: 'gull', known: const [KeywordCount('gull', 1)]);
    expect(find.textContaining('images share'), findsNothing);
  });

  testWidgets('with no frame open the control is inert', (tester) async {
    await pump(tester, enabled: false);
    expect(find.text('Open a frame to add keywords.'), findsOneWidget);
    expect(tester.widget<TextField>(find.byType(TextField)).enabled, isFalse);
  });
}
