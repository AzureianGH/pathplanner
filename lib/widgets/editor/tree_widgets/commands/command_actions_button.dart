import 'package:flutter/material.dart';
import 'package:function_tree/function_tree.dart';
import 'package:pathplanner/commands/command.dart';
import 'package:pathplanner/widgets/number_text_field.dart';
import 'package:undo/undo.dart';

class CommandActionsButton extends StatelessWidget {
  final VoidCallback? onDuplicate;
  final VoidCallback? onRemove;
  final VoidCallback? onEditDelays;

  const CommandActionsButton({
    super.key,
    this.onDuplicate,
    this.onRemove,
    this.onEditDelays,
  });

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<_CommandAction>(
      tooltip: 'Command Actions',
      onSelected: (value) {
        switch (value) {
          case _CommandAction.duplicate:
            onDuplicate?.call();
            break;
          case _CommandAction.delays:
            onEditDelays?.call();
            break;
          case _CommandAction.remove:
            onRemove?.call();
            break;
        }
      },
      itemBuilder: (context) => [
        if (onDuplicate != null)
          const PopupMenuItem(
            value: _CommandAction.duplicate,
            child: ListTile(
              leading: Icon(Icons.copy_all_rounded),
              title: Text('Duplicate'),
              contentPadding: EdgeInsets.zero,
              dense: true,
            ),
          ),
        if (onEditDelays != null)
          const PopupMenuItem(
            value: _CommandAction.delays,
            child: ListTile(
              leading: Icon(Icons.schedule),
              title: Text('Delays'),
              contentPadding: EdgeInsets.zero,
              dense: true,
            ),
          ),
        if (onRemove != null)
          const PopupMenuItem(
            value: _CommandAction.remove,
            child: ListTile(
              leading: Icon(Icons.delete_forever),
              title: Text('Delete'),
              contentPadding: EdgeInsets.zero,
              dense: true,
            ),
          ),
      ],
      child: const Padding(
        padding: EdgeInsets.all(4.0),
        child: Icon(Icons.more_vert),
      ),
    );
  }
}

enum _CommandAction {
  duplicate,
  delays,
  remove,
}

Future<void> showCommandDelaysDialog({
  required BuildContext context,
  required Command command,
  required ChangeStack undoStack,
  VoidCallback? onUpdated,
}) async {
  final beforeController = TextEditingController(
    text: command.beforeDelay.toStringAsFixed(3),
  );
  final afterController = TextEditingController(
    text: command.afterDelay.toStringAsFixed(3),
  );

  try {
    final delays = await showDialog<({num before, num after})>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('Command Delays'),
          content: SizedBox(
            width: 280,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                NumberTextField(
                  controller: beforeController,
                  initialValue: command.beforeDelay,
                  label: 'Before (s)',
                  minValue: 0.0,
                  arrowKeyIncrement: 0.1,
                ),
                const SizedBox(height: 12),
                NumberTextField(
                  controller: afterController,
                  initialValue: command.afterDelay,
                  label: 'After (s)',
                  minValue: 0.0,
                  arrowKeyIncrement: 0.1,
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                Navigator.of(dialogContext).pop((
                  before: _parseDelayValue(beforeController.text),
                  after: _parseDelayValue(afterController.text),
                ));
              },
              child: const Text('Save'),
            ),
          ],
        );
      },
    );

    if (delays == null) {
      return;
    }

    undoStack.add(Change(
      (before: command.beforeDelay, after: command.afterDelay),
      () {
        command.beforeDelay = delays.before;
        command.afterDelay = delays.after;
        onUpdated?.call();
      },
      (oldValue) {
        command.beforeDelay = oldValue.before;
        command.afterDelay = oldValue.after;
        onUpdated?.call();
      },
    ));
  } finally {
    beforeController.dispose();
    afterController.dispose();
  }
}

num _parseDelayValue(String value) {
  if (value.trim().isEmpty) {
    return 0;
  }

  final parsed = value.interpret();
  if (parsed.isNaN || parsed.isInfinite || parsed < 0) {
    return 0;
  }
  return parsed;
}