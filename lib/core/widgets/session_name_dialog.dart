import 'package:flutter/material.dart';

/// Asks for a session or project name through a small modal dialog.
///
/// Shared by the legacy session list and the new Chats browser so the rename
/// affordance does not depend on which screen hosts it. Returns the trimmed
/// name, or null when the user cancels or clears the field.
Future<String?> showSessionNameDialog({
  required BuildContext context,
  required String title,
  required String initialValue,
  required String actionLabel,
}) async {
  var draft = initialValue;
  final result = await showDialog<String>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(title),
      content: TextFormField(
        initialValue: initialValue,
        autofocus: true,
        maxLength: 120,
        decoration: const InputDecoration(border: OutlineInputBorder()),
        onChanged: (value) => draft = value,
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(dialogContext, draft.trim()),
          child: Text(actionLabel),
        ),
      ],
    ),
  );
  return result?.trim().isEmpty == true ? null : result;
}
