/// What a Projects card says beyond the project's own name.
///
/// Backlog item 6 of `docs/ANDROID_FUNCTIONAL_UI_AUDIT.md`: the card showed
/// name/description/path but not the counts and current focus the roadmap
/// promises, so the Projects list read as sparse next to the operationally
/// dense Home cards.
///
/// Every line comes from the server's own `projects.tree` overview — the cheap
/// tier that already loads on entry — so this costs **no new request and no
/// new gateway contract**, and a legacy gateway that predates `projects.tree`
/// simply gets a card with no summary rather than a broken one.
///
/// The rule that shapes the whole file: a card may stay quiet, but it may
/// never state something nobody measured. An uncounted project claims nothing;
/// a zero count beside real preview rows claims nothing either, because
/// "No chats yet" printed above a chat title is a self-contradiction the user
/// cannot resolve from the phone.
library;

import '../models/projects_tree_overview.dart';
import 'relative_time.dart';

/// The three optional summary lines of one project card.
class ProjectCardSummary {
  /// `12 chats` / `1 chat` / `No chats yet`, or null when nothing counted it.
  final String? chats;

  /// Relative time of the project's most recent activity, or null when the
  /// server reported none.
  final String? lastActivity;

  /// The title of the chat the server ranked first, or null when the overview
  /// shipped no usable preview row.
  final String? currentFocus;

  const ProjectCardSummary({this.chats, this.lastActivity, this.currentFocus});

  /// True when the card has nothing extra to show and should render as before.
  bool get isEmpty =>
      chats == null && lastActivity == null && currentFocus == null;
}

/// Builds the summary lines for one project card.
///
/// [overview] is the project's node in the `projects.tree` payload, or null
/// when the overview does not describe it (unsupported gateway, failed cheap
/// read, or a project created since the last refresh).
ProjectCardSummary buildProjectCardSummary({
  required ProjectOverviewNode? overview,
  required DateTime now,
}) {
  if (overview == null) return const ProjectCardSummary();

  final focus = _firstNamedPreview(overview);

  return ProjectCardSummary(
    chats: _chats(overview.sessionCount, hasFocus: focus != null),
    lastActivity: overview.lastActive > 0
        ? formatRelativeTime(now, overview.lastActive)
        : null,
    currentFocus: focus,
  );
}

/// Words the chat count, or stays silent when it would contradict the card.
String? _chats(int count, {required bool hasFocus}) {
  if (count == 1) return '1 chat';
  if (count > 1) return '$count chats';
  // count == 0: only claim emptiness when no preview row disproves it.
  return hasFocus ? null : 'No chats yet';
}

/// The first preview row carrying a real title, in server order.
///
/// Server order is preserved verbatim: the overview is already ranked, and
/// re-ranking it on device is the duplicated-authority mistake this phase
/// exists to avoid. `Untitled` is the parser's own fallback for a chat with no
/// title, so it names nothing and is skipped rather than rendered.
String? _firstNamedPreview(ProjectOverviewNode overview) {
  for (final session in overview.previewSessions) {
    final title = session.title.trim();
    if (title.isEmpty || title == 'Untitled') continue;
    return title;
  }
  return null;
}
