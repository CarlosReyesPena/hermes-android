import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/projects_tree_overview.dart';
import 'package:hermes_android/core/models/session.dart';
import 'package:hermes_android/core/utils/project_card_summary.dart';

/// A `projects.tree` overview node, shaped like the server sends it.
ProjectOverviewNode _node({
  String id = 'p1',
  String label = 'Hermes Android',
  int sessionCount = 0,
  double lastActive = 0,
  List<Session> previewSessions = const [],
}) => ProjectOverviewNode(
  id: id,
  label: label,
  sessionCount: sessionCount,
  lastActive: lastActive,
  previewSessions: previewSessions,
);

Session _session({
  String id = 's1',
  String title = 'Untitled',
  double lastActive = 0,
}) => Session(
  id: id,
  title: title,
  model: 'default',
  source: 'cli',
  messageCount: 1,
  isActive: false,
  preview: '',
  startedAt: lastActive,
  lastActive: lastActive,
);

void main() {
  final now = DateTime.utc(2026, 9, 8, 12, 0);
  double secondsAgo(Duration elapsed) =>
      now.subtract(elapsed).millisecondsSinceEpoch / 1000.0;

  group('chat counts', () {
    test('reports the server count and never derives it from previews', () {
      final summary = buildProjectCardSummary(
        overview: _node(sessionCount: 12, previewSessions: [_session()]),
        now: now,
      );

      expect(summary.chats, '12 chats');
    });

    test('uses the singular form for exactly one chat', () {
      expect(
        buildProjectCardSummary(
          overview: _node(sessionCount: 1),
          now: now,
        ).chats,
        '1 chat',
      );
    });

    test('says a counted-empty project has no chats yet', () {
      expect(
        buildProjectCardSummary(
          overview: _node(sessionCount: 0),
          now: now,
        ).chats,
        'No chats yet',
      );
    });

    test(
      'never claims "no chats yet" over a project the server previewed',
      () {
        // A zero count beside real preview rows is a self-contradicting card.
        // Staying quiet is honest; stating the opposite of the row below is not.
        final summary = buildProjectCardSummary(
          overview: _node(
            sessionCount: 0,
            previewSessions: [_session(title: 'Fix the notification channel')],
          ),
          now: now,
        );

        expect(summary.chats, isNull);
        expect(summary.currentFocus, 'Fix the notification channel');
      },
    );
  });

  group('last activity', () {
    test('formats through the one canonical relative-time helper', () {
      final summary = buildProjectCardSummary(
        overview: _node(
          sessionCount: 2,
          lastActive: secondsAgo(const Duration(hours: 3)),
        ),
        now: now,
      );

      expect(summary.lastActivity, '3h ago');
    });

    test('says nothing rather than 1970 when the server reported none', () {
      expect(
        buildProjectCardSummary(
          overview: _node(sessionCount: 2, lastActive: 0),
          now: now,
        ).lastActivity,
        isNull,
      );
    });

    test('drops a negative timestamp instead of rendering a fake date', () {
      expect(
        buildProjectCardSummary(
          overview: _node(sessionCount: 2, lastActive: -1),
          now: now,
        ).lastActivity,
        isNull,
      );
    });
  });

  group('current focus', () {
    test('names the first preview chat in server order', () {
      // The server ranks the previews. Re-ranking them on device is exactly
      // the duplicated-authority mistake this phase exists to avoid, so an
      // older-but-first row still wins.
      final summary = buildProjectCardSummary(
        overview: _node(
          sessionCount: 2,
          previewSessions: [
            _session(
              id: 'a',
              title: 'Server-ranked first',
              lastActive: secondsAgo(const Duration(days: 2)),
            ),
            _session(
              id: 'b',
              title: 'More recent but second',
              lastActive: secondsAgo(const Duration(minutes: 5)),
            ),
          ],
        ),
        now: now,
      );

      expect(summary.currentFocus, 'Server-ranked first');
    });

    test('skips an untitled row rather than showing a placeholder', () {
      final summary = buildProjectCardSummary(
        overview: _node(
          sessionCount: 2,
          previewSessions: [
            _session(id: 'a', title: 'Untitled'),
            _session(id: 'b', title: '   '),
            _session(id: 'c', title: 'Wire the Inbox banner'),
          ],
        ),
        now: now,
      );

      expect(summary.currentFocus, 'Wire the Inbox banner');
    });

    test('shows no focus rather than an id the user has never seen', () {
      final summary = buildProjectCardSummary(
        overview: _node(
          sessionCount: 2,
          previewSessions: [_session(id: '20260908_abc', title: 'Untitled')],
        ),
        now: now,
      );

      expect(summary.currentFocus, isNull);
      expect(summary.chats, '2 chats');
    });

    test('shows no focus when the cheap tier shipped no previews', () {
      final summary = buildProjectCardSummary(
        overview: _node(sessionCount: 9),
        now: now,
      );

      expect(summary.currentFocus, isNull);
      expect(summary.chats, '9 chats');
    });
  });

  test('an uncounted project claims nothing at all', () {
    // A gateway predating projects.tree, or a project absent from the
    // overview: rendering "No chats yet" there would state a fact nobody
    // measured.
    final summary = buildProjectCardSummary(overview: null, now: now);

    expect(summary.chats, isNull);
    expect(summary.lastActivity, isNull);
    expect(summary.currentFocus, isNull);
    expect(summary.isEmpty, isTrue);
  });

  test('a summary carrying any line is not empty', () {
    expect(
      buildProjectCardSummary(
        overview: _node(sessionCount: 0),
        now: now,
      ).isEmpty,
      isFalse,
    );
  });

  test('does not mutate or reorder the previews it was given', () {
    final previews = [
      _session(id: 'a', title: 'First'),
      _session(id: 'b', title: 'Second'),
    ];
    final node = _node(sessionCount: 2, previewSessions: previews);

    buildProjectCardSummary(overview: node, now: now);

    expect(previews.map((s) => s.id), ['a', 'b']);
    expect(node.previewSessions, hasLength(2));
  });
}
