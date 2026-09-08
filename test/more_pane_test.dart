import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/theme/hermes_theme.dart';
import 'package:hermes_android/core/widgets/more_pane.dart';

Future<void> _pumpPane(
  WidgetTester tester, {
  required List<MoreSection> sections,
  ValueChanged<MoreEntry>? onSelect,
  // Tall by default so assertions are about content, not scroll position; the
  // narrow-phone tests below set a real phone height explicitly.
  Size size = const Size(360, 1600),
  double textScale = 1.0,
  Brightness brightness = Brightness.dark,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    MaterialApp(
      theme: hermesTheme(brightness),
      home: Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: Scaffold(
            body: MorePane(sections: sections, onSelect: onSelect ?? (_) {}),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('buildMoreSections', () {
    test('exposes every roadmap destination exactly once', () {
      final sections = buildMoreSections(dashboardReachable: true);
      final ids = [
        for (final section in sections)
          for (final entry in section.entries) entry.id,
      ];

      expect(ids.toSet(), hasLength(ids.length), reason: 'ids must be unique');
      expect(
        ids,
        containsAll(<String>[
          'files',
          'assets',
          'unassigned',
          'archived-quick',
          'search',
          'cron',
          'skills',
          'memory',
          'settings',
          'dashboard',
        ]),
      );
    });

    test('Unassigned chats is not mislabeled as the action Inbox', () {
      final entry = buildMoreSections(dashboardReachable: true)
          .expand((section) => section.entries)
          .firstWhere((candidate) => candidate.id == 'unassigned');

      expect(entry.title, 'Unassigned chats');
      expect(entry.subtitle, contains('not assigned to a Project'));
    });

    test('every section has a title and at least one entry', () {
      for (final section in buildMoreSections(dashboardReachable: true)) {
        expect(section.title, isNotEmpty);
        expect(section.entries, isNotEmpty);
      }
    });

    test('dashboard-backed entries are available when the dashboard is', () {
      final entries = {
        for (final section in buildMoreSections(dashboardReachable: true))
          for (final entry in section.entries) entry.id: entry,
      };

      for (final id in ['cron', 'skills', 'memory', 'dashboard', 'settings']) {
        expect(
          entries[id]!.availability,
          MoreEntryAvailability.available,
          reason: '$id must be usable on a reachable dashboard',
        );
      }
    });

    test('a missing dashboard disables its entries with a reason', () {
      final entries = {
        for (final section in buildMoreSections(dashboardReachable: false))
          for (final entry in section.entries) entry.id: entry,
      };

      for (final id in ['cron', 'skills', 'memory', 'dashboard']) {
        final entry = entries[id]!;
        expect(
          entry.availability,
          MoreEntryAvailability.unavailable,
          reason: '$id needs the dashboard',
        );
        expect(
          entry.unavailableReason,
          isNotNull,
          reason: '$id must explain why it is disabled, not just grey out',
        );
        expect(entry.unavailableReason, isNotEmpty);
      }
    });

    test('local settings stay reachable without a dashboard', () {
      final entries = {
        for (final section in buildMoreSections(dashboardReachable: false))
          for (final entry in section.entries) entry.id: entry,
      };

      expect(
        entries['settings']!.availability,
        MoreEntryAvailability.available,
      );
    });

    test('shipped organization features are available without stale gates', () {
      final entries = {
        for (final section in buildMoreSections(dashboardReachable: true))
          for (final entry in section.entries) entry.id: entry,
      };

      expect(
        entries['assets']!.availability,
        MoreEntryAvailability.unavailable,
      );
      expect(entries['assets']!.unavailableReason, contains('Gateway'));
      for (final id in ['pin-batch-undo', 'ai-filing']) {
        expect(entries[id]!.availability, MoreEntryAvailability.available);
        expect(entries[id]!.unavailableReason, isNull);
      }
    });

    test(
      'native Smart Views are available and only contract gaps are disabled',
      () {
        final entries = {
          for (final section in buildMoreSections(dashboardReachable: true))
            for (final entry in section.entries) entry.id: entry,
        };

        expect(entries['files']!.availability, MoreEntryAvailability.available);
        for (final id in ['unassigned', 'archived-quick']) {
          expect(entries[id]!.availability, MoreEntryAvailability.available);
        }
      },
    );

    test('Search is a native Smart View, not a placeholder', () {
      final entry = buildMoreSections(dashboardReachable: true)
          .expand((section) => section.entries)
          .firstWhere((candidate) => candidate.id == 'search');

      expect(entry.title, 'Search');
      expect(entry.availability, MoreEntryAvailability.available);
      expect(entry.unavailableReason, isNull);
    });

    test(
      'Search survives a dashboard outage because on-device search does',
      () {
        final entry = buildMoreSections(dashboardReachable: false)
            .expand((section) => section.entries)
            .firstWhere((candidate) => candidate.id == 'search');

        // The browser always filters the sessions it already holds; only the
        // full-text and AI modes need the dashboard, and the screen degrades to
        // on-device search by itself. Disabling the whole entry here would hide
        // a capability that still works.
        expect(entry.availability, MoreEntryAvailability.available);
      },
    );

    test('Files follows the dashboard it depends on', () {
      final entries = {
        for (final section in buildMoreSections(dashboardReachable: false))
          for (final entry in section.entries) entry.id: entry,
      };

      expect(entries['files']!.availability, MoreEntryAvailability.unavailable);
      expect(entries['files']!.unavailableReason, isNotNull);
    });
  });

  group('MorePane', () {
    List<MoreSection> sections({bool dashboardReachable = true}) =>
        buildMoreSections(dashboardReachable: dashboardReachable);

    testWidgets('renders every section title and entry', (tester) async {
      final built = sections();
      await _pumpPane(tester, sections: built);

      for (final section in built) {
        await tester.scrollUntilVisible(
          find.text(section.title),
          160,
          scrollable: find.byType(Scrollable).first,
        );
        expect(find.text(section.title), findsOneWidget);
      }
      await tester.scrollUntilVisible(
        find.text('Cron'),
        160,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('Cron'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('Settings'),
        160,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('Settings'), findsOneWidget);
    });

    testWidgets('selecting an available entry reports it once', (tester) async {
      final picked = <String>[];
      await _pumpPane(
        tester,
        sections: sections(),
        onSelect: (entry) => picked.add(entry.id),
      );

      await tester.ensureVisible(find.text('Cron'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cron'));
      await tester.pumpAndSettle();

      expect(picked, ['cron']);
    });

    testWidgets('an unavailable entry cannot be selected', (tester) async {
      final picked = <String>[];
      await _pumpPane(
        tester,
        sections: sections(dashboardReachable: false),
        onSelect: (entry) => picked.add(entry.id),
      );

      await tester.scrollUntilVisible(
        find.text('Cron'),
        160,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('Cron'), warnIfMissed: false);
      await tester.pumpAndSettle();

      expect(picked, isEmpty);
    });

    testWidgets('an unavailable entry explains why on screen', (tester) async {
      final built = sections(dashboardReachable: false);
      await _pumpPane(tester, sections: built);

      final cron = built
          .expand((section) => section.entries)
          .firstWhere((entry) => entry.id == 'cron');

      expect(find.text(cron.unavailableReason!), findsWidgets);
    });

    testWidgets(
      'a contract-gated entry explains itself and is not selectable',
      (tester) async {
        final picked = <String>[];
        await _pumpPane(
          tester,
          sections: sections(),
          onSelect: (entry) => picked.add(entry.id),
        );

        await tester.tap(find.text('Assets'), warnIfMissed: false);
        await tester.pumpAndSettle();

        expect(
          find.textContaining('server-authoritative Assets index'),
          findsOneWidget,
        );
        expect(picked, isEmpty);
      },
    );

    testWidgets('survives a large text scale on a narrow phone', (
      tester,
    ) async {
      await _pumpPane(
        tester,
        sections: sections(),
        size: const Size(320, 640),
        textScale: 1.8,
      );

      expect(tester.takeException(), isNull);
      expect(find.text('Unassigned chats'), findsOneWidget);
    });

    testWidgets('scrolls to the last entry on a real phone height', (
      tester,
    ) async {
      await _pumpPane(tester, sections: sections(), size: const Size(360, 720));

      await tester.scrollUntilVisible(
        find.text('Settings'),
        160,
        scrollable: find.byType(Scrollable).first,
      );

      expect(find.text('Settings'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('renders in the light theme', (tester) async {
      await _pumpPane(
        tester,
        sections: sections(),
        brightness: Brightness.light,
      );

      await tester.scrollUntilVisible(
        find.text('Settings'),
        160,
        scrollable: find.byType(Scrollable).first,
      );
      expect(tester.takeException(), isNull);
      expect(find.text('Settings'), findsOneWidget);
    });

    testWidgets('every entry is reachable by a screen reader', (tester) async {
      final built = sections();
      await _pumpPane(tester, sections: built);

      for (final section in built) {
        for (final entry in section.entries) {
          await tester.scrollUntilVisible(
            find.text(entry.title),
            120,
            scrollable: find.byType(Scrollable).first,
          );
          expect(
            find.bySemanticsLabel(RegExp(entry.title)),
            findsWidgets,
            reason: '${entry.title} must be announced',
          );
        }
      }
    });
  });

  // Backlog item 9 of docs/ANDROID_FUNCTIONAL_UI_AUDIT.md: "More rows expose
  // repeated labels (`Files · Files`, `Cron · Cron`) in the accessibility tree
  // because title and semantic label overlap."
  group('moreEntrySemanticsLabel', () {
    test('states the title once and then the subtitle', () {
      const entry = MoreEntry(
        id: 'files',
        title: 'Files',
        subtitle: 'Browse the miniserver folders behind your projects',
        icon: Icons.folder_outlined,
      );

      expect(
        moreEntrySemanticsLabel(entry),
        'Files. Browse the miniserver folders behind your projects',
      );
    });

    test('announces the Coming next badge the card draws', () {
      const entry = MoreEntry(
        id: 'assets',
        title: 'Assets',
        subtitle: 'Artifacts, attachments, and generated media',
        icon: Icons.auto_awesome_mosaic_outlined,
        availability: MoreEntryAvailability.comingSoon,
      );

      final label = moreEntrySemanticsLabel(entry);

      expect(label, startsWith('Assets. Coming next.'));
      expect(label, endsWith('Artifacts, attachments, and generated media'));
    });

    test('announces the reason a disabled entry cannot be opened', () {
      const entry = MoreEntry(
        id: 'cron',
        title: 'Cron',
        subtitle: 'Scheduled jobs and their last runs',
        icon: Icons.schedule,
        availability: MoreEntryAvailability.unavailable,
        unavailableReason: 'Needs a reachable Hermes dashboard.',
      );

      expect(
        moreEntrySemanticsLabel(entry),
        'Cron. Scheduled jobs and their last runs. '
        'Needs a reachable Hermes dashboard.',
      );
    });

    test('never doubles a separator after a part that ends in a period', () {
      const entry = MoreEntry(
        id: 'assets',
        title: 'Assets',
        subtitle: 'Artifacts and media.',
        icon: Icons.auto_awesome_mosaic_outlined,
      );

      expect(moreEntrySemanticsLabel(entry), 'Assets. Artifacts and media.');
    });

    test('degrades to the title alone when there is nothing else to say', () {
      const entry = MoreEntry(
        id: 'settings',
        title: 'Settings',
        subtitle: '',
        icon: Icons.settings_outlined,
      );

      expect(moreEntrySemanticsLabel(entry), 'Settings');
    });
  });

  group('MorePane accessibility', () {
    List<MoreSection> sections({bool dashboardReachable = true}) =>
        buildMoreSections(dashboardReachable: dashboardReachable);

    /// Every label in the rendered semantics tree, flattened.
    List<String> semanticsLabels(WidgetTester tester) {
      final labels = <String>[];
      void walk(SemanticsNode node) {
        final label = node.getSemanticsData().label;
        if (label.isNotEmpty) labels.add(label);
        node.visitChildren((child) {
          walk(child);
          return true;
        });
      }

      // `find.byType(MorePane)` roots the walk at the pane's own render
      // object, which avoids reaching for a binding-level pipeline owner.
      walk(tester.getSemantics(find.byType(MorePane)));
      return labels;
    }

    testWidgets('announces each row title exactly once', (tester) async {
      final handle = tester.ensureSemantics();
      final built = sections(dashboardReachable: false);
      await _pumpPane(tester, sections: built);

      for (final section in built) {
        for (final entry in section.entries) {
          // Rows below the fold are not built, so scroll each one in before
          // reading the semantics tree.
          await tester.scrollUntilVisible(
            find.text(entry.title),
            120,
            scrollable: find.byType(Scrollable).first,
          );
          final row = semanticsLabels(
            tester,
          ).where((label) => label.startsWith('${entry.title}.'));
          expect(
            row,
            hasLength(1),
            reason: '${entry.title} must produce exactly one row announcement',
          );
          // The row announces exactly the composed sentence, so the visible
          // text is never read a second time. The historical regression was
          // `Files ⏎ Files ⏎ subtitle`; a title immediately repeating itself
          // is the specific shape that must never come back.
          expect(row.single, moreEntrySemanticsLabel(entry));
          expect(
            row.single.startsWith('${entry.title}. ${entry.title}'),
            isFalse,
            reason:
                '${entry.title} must not be repeated straight after itself '
                '(got "${row.single}")',
          );
        }
      }
      handle.dispose();
    });

    testWidgets('a disabled row still announces its reason', (tester) async {
      final handle = tester.ensureSemantics();
      await _pumpPane(tester, sections: sections(dashboardReachable: false));

      final cron = semanticsLabels(
        tester,
      ).firstWhere((label) => label.startsWith('Cron.'));

      expect(cron, contains('Scheduled jobs and their last runs'));
      expect(cron, contains('Needs a reachable Hermes dashboard'));
      handle.dispose();
    });

    testWidgets('an unbuilt row announces the Coming next badge it draws', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      // No shipped entry is `comingSoon` today, but the card still renders the
      // badge for one, so the announcement must carry it whenever a future
      // surface is listed that way.
      await _pumpPane(
        tester,
        sections: const [
          MoreSection(
            title: 'Workspace',
            entries: [
              MoreEntry(
                id: 'assets',
                title: 'Assets',
                subtitle: 'Artifacts, attachments, and generated media',
                icon: Icons.image_outlined,
                availability: MoreEntryAvailability.comingSoon,
              ),
            ],
          ),
        ],
      );

      final assets = semanticsLabels(
        tester,
      ).firstWhere((label) => label.startsWith('Assets.'));

      expect(assets, contains('Coming next'));
      expect(find.text('Coming next'), findsOneWidget);
      handle.dispose();
    });
  });
}
