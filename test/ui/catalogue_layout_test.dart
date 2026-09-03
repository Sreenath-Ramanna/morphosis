// test/ui/catalogue_layout_test.dart
//
// The catalogue's two additions to the editor: the keyword panel in the left
// column, and the banner that says an edit was restored. Asserted rather than
// eyeballed — the golden renders text as boxes, so it can show that the
// column widened but not that the right words are in it.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:morphosis/src/catalog/catalog.dart';
import 'package:morphosis/src/model/edit.dart';
import 'package:morphosis/src/ui/editor_layout.dart';
import 'package:morphosis/src/ui/keyword_panel.dart';
import 'package:morphosis/src/ui/theme.dart';

CatalogEntry entryWith({String keywords = '', Edit? edit}) => CatalogEntry(
      sha256: 'f' * 64,
      displayName: 'DSC_1436.NEF',
      sizeBytes: 29800000,
      keywords: KeywordSet.parse(keywords),
      edit: edit,
      firstSeen: DateTime.utc(2025, 8, 4),
      lastEdited: DateTime.utc(2025, 9, 2, 18, 30),
    );

void main() {
  late List<KeywordSet> keywordsEmitted;
  late int reverts;

  Future<void> pump(WidgetTester tester, EditorViewState state) async {
    keywordsEmitted = [];
    reverts = 0;
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: buildTheme(),
      home: EditorLayout(
        state: state,
        onBrowse: () {},
        onExport: () {},
        onSelect: (_) {},
        onEditChanged: (_) {},
        onKeywordsChanged: keywordsEmitted.add,
        onRevertEdit: () => reverts++,
      ),
    ));
    await tester.pumpAndSettle();
  }

  group('the keyword panel', () {
    testWidgets('is in the left column and shows the frame\'s keywords',
        (tester) async {
      await pump(tester, EditorViewState(entry: entryWith(keywords: 'gull')));
      expect(find.byType(KeywordPanel), findsOneWidget);
      expect(find.text('gull'), findsOneWidget);
    });

    testWidgets('is inert with no frame open', (tester) async {
      await pump(tester, const EditorViewState());
      expect(find.byType(KeywordPanel), findsOneWidget);
      expect(find.text('Open a frame to add keywords.'), findsOneWidget);
    });

    testWidgets('changes reach the callback', (tester) async {
      await pump(tester, EditorViewState(entry: entryWith(keywords: 'gull')));
      await tester.enterText(find.byType(TextField), 'coast');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(keywordsEmitted.single.keywords, ['gull', 'coast']);
    });

    // The column was widened from 210 for exactly this: a keyword field in
    // 210 px wraps after one short word.
    testWidgets('the left column is 260 px wide', (tester) async {
      await pump(tester, const EditorViewState());
      final column = tester.getSize(find.ancestor(
        of: find.byType(KeywordPanel),
        matching: find.byType(SizedBox),
      ).last);
      expect(column.width, 260);
    });

    testWidgets('the chips, the field and the shared line all fit',
        (tester) async {
      await pump(
        tester,
        EditorViewState(
          entry: entryWith(keywords: 'gull, north coast, backlit'),
          knownKeywords: const [
            KeywordCount('north coast', 42),
            KeywordCount('gull', 18),
          ],
        ),
      );
      expect(tester.takeException(), isNull,
          reason: 'an overflow would be reported here');
      expect(find.text('gull'), findsOneWidget);
      expect(find.text('north coast'), findsOneWidget);
      expect(find.text('backlit'), findsOneWidget);
      expect(find.textContaining('42 images share'), findsOneWidget);
    });
  });

  group('the restored banner', () {
    testWidgets('is absent when the edit was made in this session',
        (tester) async {
      await pump(tester, EditorViewState(entry: entryWith()));
      expect(find.byType(RestoredBanner), findsNothing);
    });

    testWidgets('says when the frame was last edited', (tester) async {
      await pump(
        tester,
        EditorViewState(
          entry: entryWith(edit: const Edit(blackEv: -1)),
          restoredFrom: DateTime.utc(2025, 9, 2, 18, 30),
        ),
      );
      expect(find.byType(RestoredBanner), findsOneWidget);
      expect(find.textContaining('restored'), findsOneWidget);
    });

    testWidgets('revert reaches the callback', (tester) async {
      await pump(
        tester,
        EditorViewState(
          entry: entryWith(edit: const Edit(blackEv: -1)),
          restoredFrom: DateTime.utc(2025, 9, 2, 18, 30),
        ),
      );
      await tester.tap(find.text('Revert'));
      await tester.pump();
      expect(reverts, 1);
    });

    // UTC in the store, local on screen, converted in exactly one place.
    // Getting this wrong gives dates that are right for most of the year.
    testWidgets('the date shown is local, not UTC', (tester) async {
      // An instant late enough in the day that any positive offset rolls it
      // to the next date locally.
      final utc = DateTime.utc(2025, 9, 2, 23, 30);
      expect(RestoredBanner.describe(utc),
          '${utc.toLocal().day} ${[
            'January', 'February', 'March', 'April', 'May', 'June',
            'July', 'August', 'September', 'October', 'November', 'December',
          ][utc.toLocal().month - 1]}');
    });
  });
}
