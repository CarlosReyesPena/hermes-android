/// Which chats the Inbox should ask the gateway about, and what it got back.
///
/// An approval requested while no chat screen was open has no live
/// `approval.request` event anywhere on the device: the gateway holds it in a
/// per-session pending queue and only replays it when that exact chat is
/// reopened (see `_replayPendingApprovals` in `chat_screen.dart`). So a user
/// who never reopens the right chat can be blocked indefinitely with nothing
/// on screen saying so — precisely the gap the roadmap's "approvals that
/// outlive an open chat" slice exists to close.
///
/// The gateway offers no aggregate "list every pending approval" RPC; the only
/// contract is the session-scoped `approval.pending`. This file owns the
/// *decision* half of asking it responsibly, as pure functions, so the policy
/// is assertable without a socket:
///
/// 1. **Never ask about every chat.** Probing is one request per session, so
///    the candidate set is restricted to work that could plausibly be waiting
///    and then capped.
/// 2. **Completed work is never probed.** A finished turn holds no approval,
///    and spending a request on it would only make the Inbox slower.
/// 3. **One request per chat, not per turn.** The Activity feed emits a row
///    per turn; approvals are session-keyed, so three turns of one chat are
///    one question.
/// 4. **Never invent prose.** A chat whose title the feed did not know stays
///    labelled as untitled rather than being given a fabricated name.
library;

import 'activity_feed.dart';

/// How many sessions one Inbox open may probe.
///
/// Each probe is a separate round trip on the gateway socket, so this is a
/// deliberate budget rather than a page size: the banner exists to catch the
/// forgotten approval, and the blocked/running/failed ranking already puts the
/// likeliest candidates first.
const int kPendingApprovalProbeLimit = 8;

/// One chat the Inbox will ask `approval.pending` about.
class ApprovalProbeTarget {
  /// The local chat id, which is what `approval.pending` is keyed by.
  final String sessionId;

  /// The chat's title when the Activity feed knew it, `null` otherwise.
  final String? title;

  const ApprovalProbeTarget({required this.sessionId, this.title});
}

/// Picks the chats worth probing, in descending likelihood.
///
/// Blocked work comes first (it is by definition waiting on the user), then
/// running work (a turn can request approval at any moment), then failed work
/// — a turn reported as *stalled* is very often a turn sitting behind an
/// approval whose event was never delivered. Completed work is excluded.
///
/// Never mutates [feed]. Throws [ArgumentError] when [limit] would allow no
/// request at all, since a silently empty probe would look identical to
/// "nothing is pending".
List<ApprovalProbeTarget> selectApprovalProbeTargets({
  required ActivityFeed feed,
  int limit = kPendingApprovalProbeLimit,
}) {
  if (limit <= 0) {
    throw ArgumentError.value(
      limit,
      'limit',
      'An approval probe must be allowed to ask about at least one chat',
    );
  }

  const probeOrder = <ActivityGroupKind>[
    ActivityGroupKind.needsYou,
    ActivityGroupKind.running,
    ActivityGroupKind.failed,
  ];

  final targets = <ApprovalProbeTarget>[];
  final seen = <String>{};
  for (final kind in probeOrder) {
    for (final group in feed.groups) {
      if (group.kind != kind) continue;
      for (final item in group.items) {
        if (targets.length >= limit) return List.unmodifiable(targets);
        if (item.sessionId.isEmpty || !seen.add(item.sessionId)) continue;
        targets.add(
          ApprovalProbeTarget(sessionId: item.sessionId, title: item.title),
        );
      }
    }
  }
  return List.unmodifiable(targets);
}

/// One approval the gateway reported as still pending, as the Inbox shows it.
class PendingApprovalSummary {
  /// The chat that will replay the real approval dialog when opened.
  final String sessionId;

  /// The chat's title when known. Never fabricated.
  final String? title;

  /// The command Hermes wants to run, verbatim. May be empty when the gateway
  /// sent none — the row still renders, because a pending approval with no
  /// command is still blocking.
  final String command;

  /// The gateway's own prose, or a stated default.
  final String description;

  const PendingApprovalSummary({
    required this.sessionId,
    required this.command,
    required this.description,
    this.title,
  });

  /// Parses one raw `approval.pending` entry.
  factory PendingApprovalSummary.fromWire({
    required String sessionId,
    required String? title,
    required Map<String, dynamic> data,
  }) {
    final trimmedTitle = title?.trim();
    final description = data['description']?.toString().trim() ?? '';
    return PendingApprovalSummary(
      sessionId: sessionId,
      title: (trimmedTitle == null || trimmedTitle.isEmpty)
          ? null
          : trimmedTitle,
      command: data['command']?.toString().trim() ?? '',
      description: description.isEmpty
          ? 'Hermes is waiting for your approval.'
          : description,
    );
  }

  /// What the row calls this chat. Honest about an unknown title rather than
  /// naming it after its id, which the user has never seen.
  String get chatLabel => title ?? 'Untitled chat';
}
