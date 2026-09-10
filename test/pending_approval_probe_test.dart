import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/theme/hermes_theme.dart';
import 'package:hermes_android/core/utils/activity_feed.dart';
import 'package:hermes_android/core/utils/pending_approval_probe.dart';

/// Builds an [ActivityFeed] directly rather than through the journal, so this
/// suite pins the *selection* rules and cannot fail for a journal reason.
ActivityFeed _feed(Map<ActivityGroupKind, List<ActivityItem>> groups) {
  final built = <ActivityGroup>[];
  for (final kind in ActivityGroupKind.values) {
    final items = groups[kind];
    if (items == null || items.isEmpty) continue;
    built.add(
      ActivityGroup(kind: kind, items: items, totalCount: items.length),
    );
  }
  return ActivityFeed(
    groups: built,
    blockedCount: groups[ActivityGroupKind.needsYou]?.length ?? 0,
    runningCount: groups[ActivityGroupKind.running]?.length ?? 0,
  );
}

final _now = DateTime.utc(2026, 9, 7, 12, 0, 0);

ActivityItem _item({
  required String sessionId,
  String? title,
  String clientTurnId = 'turn-1',
  String label = 'Running',
  HermesStatus status = HermesStatus.running,
  Duration ago = const Duration(minutes: 1),
}) {
  return ActivityItem(
    sessionId: sessionId,
    title: title,
    clientTurnId: clientTurnId,
    label: label,
    status: status,
    updatedAt: _now.subtract(ago),
  );
}

void main() {
  group('selectApprovalProbeTargets', () {
    test('asks nothing when the timeline is empty', () {
      expect(selectApprovalProbeTargets(feed: _feed(const {})), isEmpty);
    });

    test('probes blocked work before running work', () {
      final targets = selectApprovalProbeTargets(
        feed: _feed({
          ActivityGroupKind.running: [_item(sessionId: 'running')],
          ActivityGroupKind.needsYou: [_item(sessionId: 'blocked')],
        }),
      );

      expect(
        targets.map((target) => target.sessionId),
        ['blocked', 'running'],
      );
    });

    test('probes stalled and unrecovered work, which is where an invisible '
        'approval hides', () {
      final targets = selectApprovalProbeTargets(
        feed: _feed({
          ActivityGroupKind.failed: [
            _item(sessionId: 'stalled', label: 'Stalled — no update'),
          ],
        }),
      );

      expect(targets.single.sessionId, 'stalled');
    });

    test('never probes a completed turn', () {
      final targets = selectApprovalProbeTargets(
        feed: _feed({
          ActivityGroupKind.completed: [
            _item(sessionId: 'done', label: 'Completed'),
          ],
        }),
      );

      expect(targets, isEmpty);
    });

    test('asks each chat once even when it ran several turns', () {
      final targets = selectApprovalProbeTargets(
        feed: _feed({
          ActivityGroupKind.needsYou: [
            _item(sessionId: 'chat', clientTurnId: 'turn-1'),
          ],
          ActivityGroupKind.running: [
            _item(sessionId: 'chat', clientTurnId: 'turn-2'),
          ],
          ActivityGroupKind.failed: [
            _item(sessionId: 'chat', clientTurnId: 'turn-3'),
          ],
        }),
      );

      expect(targets.length, 1);
      expect(targets.single.sessionId, 'chat');
    });

    test('carries the title the feed knew and never invents one', () {
      final targets = selectApprovalProbeTargets(
        feed: _feed({
          ActivityGroupKind.needsYou: [
            _item(sessionId: 'titled', title: 'Deploy script'),
            _item(sessionId: 'untitled', clientTurnId: 'turn-2'),
          ],
        }),
      );

      expect(targets.first.title, 'Deploy script');
      expect(targets.last.title, isNull);
    });

    test('caps the number of requests one Inbox open may spend', () {
      final targets = selectApprovalProbeTargets(
        feed: _feed({
          ActivityGroupKind.running: [
            for (var i = 0; i < 20; i++)
              _item(sessionId: 'session-$i', clientTurnId: 'turn-$i'),
          ],
        }),
        limit: 4,
      );

      expect(targets.length, 4);
    });

    test('rejects a cap that would spend no request at all', () {
      expect(
        () => selectApprovalProbeTargets(feed: _feed(const {}), limit: 0),
        throwsArgumentError,
      );
    });
  });

  group('PendingApprovalSummary', () {
    test('reads the command and description the gateway sent', () {
      final summary = PendingApprovalSummary.fromWire(
        sessionId: 'chat',
        title: 'Deploy script',
        data: const {
          'command': 'rm -rf build',
          'description': 'Hermes wants to clear the build directory.',
        },
      );

      expect(summary.sessionId, 'chat');
      expect(summary.title, 'Deploy script');
      expect(summary.command, 'rm -rf build');
      expect(summary.description, 'Hermes wants to clear the build directory.');
    });

    test('falls back to a stated default rather than an empty row', () {
      final summary = PendingApprovalSummary.fromWire(
        sessionId: 'chat',
        title: null,
        data: const {},
      );

      expect(summary.command, isEmpty);
      expect(summary.description, isNotEmpty);
    });

    test('labels an untitled chat honestly instead of naming it', () {
      final summary = PendingApprovalSummary.fromWire(
        sessionId: 'chat',
        title: null,
        data: const {'command': 'ls'},
      );

      expect(summary.chatLabel, 'Untitled chat');
    });

    test('prefers the chat title when the feed knew it', () {
      final summary = PendingApprovalSummary.fromWire(
        sessionId: 'chat',
        title: '  Deploy script  ',
        data: const {'command': 'ls'},
      );

      expect(summary.chatLabel, 'Deploy script');
    });
  });
}
