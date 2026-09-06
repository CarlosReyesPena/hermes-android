import 'package:flutter/material.dart';

import '../theme/hermes_theme.dart';
import '../utils/pending_approval_probe.dart';
import 'hermes_components.dart';

/// Reads the approvals the gateway still has pending across chats.
///
/// Injectable so widget tests can substitute a fake. The real implementation
/// probes `approval.pending` for the sessions
/// [selectApprovalProbeTargets] picked.
///
/// Contract: the loader returns an empty list (never throws) when the gateway
/// is unreachable — an Inbox must never show an error state for a source that
/// is simply offline. Pass `null` when the connection has no Desktop Gateway
/// at all: the banner then renders nothing rather than claiming that nothing
/// is pending on a question it never asked.
typedef PendingApprovalsLoader = Future<List<PendingApprovalSummary>> Function();

/// The action-Inbox banner for approvals that outlived their chat screen.
///
/// An approval requested while no chat was open is invisible on this device:
/// the gateway queues it per session and only replays it when that exact chat
/// is reopened. This banner is the surface that makes it findable, and every
/// row is drawn from an authoritative `approval.pending` answer — never
/// inferred from a turn status, which would risk telling the user they are
/// blocked when they are not.
///
/// Tapping a row opens its chat, where the existing replay path shows the real
/// approval dialog. The banner deliberately does not offer Approve/Deny
/// inline: answering a command the user cannot see in context is exactly the
/// mistake the roadmap's notification section warns against.
class PendingApprovalsBanner extends StatefulWidget {
  const PendingApprovalsBanner({
    required this.loadApprovals,
    required this.onOpenApproval,
    super.key,
  });

  /// `null` when this connection cannot answer the question at all.
  final PendingApprovalsLoader? loadApprovals;

  final ValueChanged<PendingApprovalSummary> onOpenApproval;

  @override
  State<PendingApprovalsBanner> createState() => PendingApprovalsBannerState();
}

class PendingApprovalsBannerState extends State<PendingApprovalsBanner> {
  List<PendingApprovalSummary> _approvals = const [];

  @override
  void initState() {
    super.initState();
    refresh();
  }

  /// Re-reads the pending approvals. Public so a host can refresh the banner
  /// after the user returns from the chat that was blocked.
  Future<void> refresh() async {
    final loader = widget.loadApprovals;
    if (loader == null) return;
    List<PendingApprovalSummary> approvals;
    try {
      approvals = await loader();
    } catch (_) {
      approvals = const [];
    }
    if (!mounted) return;
    setState(() => _approvals = approvals);
  }

  @override
  Widget build(BuildContext context) {
    if (_approvals.isEmpty) return const SizedBox.shrink();
    final tokens = HermesTokens.of(context);
    final color = tokens.colorForStatus(HermesStatus.blocked);
    final heading = _approvals.length == 1
        ? '1 approval is waiting'
        : '${_approvals.length} approvals are waiting';

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        HermesSpacing.lg,
        HermesSpacing.lg,
        HermesSpacing.lg,
        0,
      ),
      child: HermesCard(
        status: HermesStatus.blocked,
        padding: const EdgeInsets.symmetric(
          horizontal: HermesSpacing.md,
          vertical: HermesSpacing.sm,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.pan_tool_alt_outlined, size: 20, color: color),
                const SizedBox(width: HermesSpacing.sm),
                Expanded(
                  child: Text(
                    heading,
                    style: tokens.typography.section.copyWith(color: color),
                  ),
                ),
              ],
            ),
            for (final approval in _approvals)
              _PendingApprovalRow(
                approval: approval,
                onTap: () => widget.onOpenApproval(approval),
              ),
          ],
        ),
      ),
    );
  }
}

class _PendingApprovalRow extends StatelessWidget {
  const _PendingApprovalRow({required this.approval, required this.onTap});

  final PendingApprovalSummary approval;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = HermesTokens.of(context);
    // A pending approval with no command still blocks the turn, so the row is
    // drawn either way and states the gateway's prose instead.
    final detail = approval.command.isEmpty
        ? approval.description
        : approval.command;

    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: HermesSpacing.sm),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(approval.chatLabel, style: tokens.typography.body),
                  const SizedBox(height: 2),
                  Text(
                    detail,
                    style: tokens.typography.mono,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            const SizedBox(width: HermesSpacing.sm),
            const Icon(Icons.chevron_right, size: 20),
          ],
        ),
      ),
    );
  }
}
