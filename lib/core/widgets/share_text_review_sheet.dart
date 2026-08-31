import 'package:flutter/material.dart';

import '../theme/hermes_theme.dart';
import '../utils/new_chat_options.dart';

enum ShareFavoriteAction {
  useAsIs('Use as is', Icons.edit_note_rounded),
  summarize('Summarize', Icons.summarize_rounded),
  explain('Explain', Icons.lightbulb_outline_rounded),
  research('Research', Icons.travel_explore_rounded),
  extractTasks('Extract tasks', Icons.task_alt_rounded),
  remember('Remember', Icons.memory_rounded),
  fillFromDocument('Fill from document', Icons.description_outlined);

  final String label;
  final IconData icon;
  const ShareFavoriteAction(this.label, this.icon);
}

String buildSharedPrompt(ShareFavoriteAction action, String source) {
  final text = source.trim();
  return switch (action) {
    ShareFavoriteAction.useAsIs => text,
    ShareFavoriteAction.summarize => 'Summarize this content:\n\n$text',
    ShareFavoriteAction.explain => 'Explain this content clearly:\n\n$text',
    ShareFavoriteAction.research =>
      'Research this content, verify the important claims, and cite sources:\n\n$text',
    ShareFavoriteAction.extractTasks =>
      'Extract the decisions, deadlines, owners, and actionable action items from this content:\n\n$text',
    ShareFavoriteAction.remember =>
      'Save the durable facts from this content to memory, then confirm what was retained:\n\n$text',
    ShareFavoriteAction.fillFromDocument =>
      'Use this content to identify and fill the relevant document or form fields. Ask before submitting anything:\n\n$text',
  };
}

class ShareTextDecision {
  final ShareFavoriteAction action;
  final NewChatMode mode;

  const ShareTextDecision({required this.action, required this.mode});
}

class ShareTextReviewSheet extends StatefulWidget {
  final String sharedText;
  final bool projectChatEnabled;

  const ShareTextReviewSheet({
    required this.sharedText,
    required this.projectChatEnabled,
    super.key,
  });

  @override
  State<ShareTextReviewSheet> createState() => _ShareTextReviewSheetState();
}

class _ShareTextReviewSheetState extends State<ShareTextReviewSheet> {
  ShareFavoriteAction _action = ShareFavoriteAction.useAsIs;
  NewChatMode _mode = NewChatMode.quickChat;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          HermesSpacing.lg,
          HermesSpacing.lg,
          HermesSpacing.lg,
          HermesSpacing.lg + MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: Column(
          children: [
            Expanded(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Share to Hermes',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: HermesSpacing.sm),
                    Text(
                      widget.sharedText,
                      maxLines: 4,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    const SizedBox(height: HermesSpacing.lg),
                    Text(
                      'Action',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: HermesSpacing.sm),
                    Wrap(
                      spacing: HermesSpacing.sm,
                      runSpacing: HermesSpacing.sm,
                      children: [
                        for (final action in ShareFavoriteAction.values)
                          ChoiceChip(
                            avatar: Icon(action.icon, size: 18),
                            label: Text(action.label),
                            selected: _action == action,
                            onSelected: (_) => setState(() => _action = action),
                          ),
                      ],
                    ),
                    const SizedBox(height: HermesSpacing.lg),
                    Text(
                      'Destination',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    RadioGroup<NewChatMode>(
                      groupValue: _mode,
                      onChanged: (mode) {
                        if (mode != null) setState(() => _mode = mode);
                      },
                      child: Column(
                        children: [
                          const RadioListTile<NewChatMode>(
                            contentPadding: EdgeInsets.zero,
                            title: Text('Quick chat'),
                            subtitle: Text('Auto-archives after 72 hours'),
                            value: NewChatMode.quickChat,
                          ),
                          RadioListTile<NewChatMode>(
                            contentPadding: EdgeInsets.zero,
                            title: const Text('Project chat'),
                            subtitle: Text(
                              widget.projectChatEnabled
                                  ? 'Choose an active Project next'
                                  : 'No active Projects on this Gateway',
                            ),
                            value: NewChatMode.projectChat,
                            enabled: widget.projectChatEnabled,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: HermesSpacing.md),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Cancel'),
                ),
                const SizedBox(width: HermesSpacing.sm),
                FilledButton.icon(
                  onPressed: () => Navigator.of(
                    context,
                  ).pop(ShareTextDecision(action: _action, mode: _mode)),
                  icon: const Icon(Icons.arrow_forward_rounded),
                  label: const Text('Continue'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
