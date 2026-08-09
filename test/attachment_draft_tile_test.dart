import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/attachment_draft.dart';
import 'package:hermes_android/core/services/attachment_draft_service.dart';
import 'package:hermes_android/core/widgets/attachment_draft_tile.dart';

void main() {
  testWidgets(
    'move controls are semantic, disabled at edges, and reorder the list',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(320, 640);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final service = AttachmentDraftService();
      final drafts = <AttachmentDraft>[
        AttachmentDraft(
          id: 'first',
          cachedPath: 'first.bin',
          name: 'first.bin',
          byteLength: 1,
          mediaType: 'application/octet-stream',
          kind: AttachmentDraftKind.genericFile,
        ),
        AttachmentDraft(
          id: 'second',
          cachedPath: 'second.bin',
          name: 'second.bin',
          byteLength: 1,
          mediaType: 'application/octet-stream',
          kind: AttachmentDraftKind.genericFile,
        ),
      ];
      final semantics = tester.ensureSemantics();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) => Column(
                children: [
                  for (var index = 0; index < drafts.length; index++)
                    AttachmentDraftTile(
                      draft: drafts[index],
                      index: index,
                      total: drafts.length,
                      busy: false,
                      onMovePrevious: () => setState(
                        () => service.moveDraft(
                          drafts,
                          fromIndex: index,
                          offset: -1,
                        ),
                      ),
                      onMoveNext: () => setState(
                        () => service.moveDraft(
                          drafts,
                          fromIndex: index,
                          offset: 1,
                        ),
                      ),
                      onRetry: () {},
                      onRemove: () {},
                    ),
                ],
              ),
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);

      expect(find.byTooltip('Move attachment previous'), findsNWidgets(2));
      expect(find.byTooltip('Move attachment next'), findsNWidgets(2));
      final previousButtons = find.widgetWithIcon(
        IconButton,
        Icons.arrow_upward,
      );
      final nextButtons = find.widgetWithIcon(IconButton, Icons.arrow_downward);
      expect(
        tester.widget<IconButton>(previousButtons.at(0)).onPressed,
        isNull,
      );
      expect(
        tester.widget<IconButton>(previousButtons.at(1)).onPressed,
        isNotNull,
      );
      expect(tester.widget<IconButton>(nextButtons.at(0)).onPressed, isNotNull);
      expect(tester.widget<IconButton>(nextButtons.at(1)).onPressed, isNull);
      expect(tester.getSize(nextButtons.at(0)).width, greaterThanOrEqualTo(48));
      expect(tester.getSize(nextButtons.at(0)).height, greaterThanOrEqualTo(48));
      expect(
        tester
            .getSemantics(find.bySemanticsLabel('Move attachment next').first)
            .label,
        contains('Move attachment next'),
      );

      await tester.tap(nextButtons.at(0));
      await tester.pump();

      expect(drafts.map((draft) => draft.name), ['second.bin', 'first.bin']);
      expect(
        tester.widget<IconButton>(previousButtons.at(0)).onPressed,
        isNull,
      );
      expect(tester.widget<IconButton>(nextButtons.at(1)).onPressed, isNull);
      expect(tester.takeException(), isNull);
      semantics.dispose();
    },
  );
}
