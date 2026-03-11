import 'package:flutter/material.dart';
import 'package:pathplanner/commands/wait_command.dart';
import 'package:pathplanner/widgets/editor/tree_widgets/commands/command_actions_button.dart';
import 'package:pathplanner/widgets/editor/tree_widgets/commands/command_preview_state.dart';
import 'package:pathplanner/widgets/number_text_field.dart';
import 'package:undo/undo.dart';

class WaitCommandWidget extends StatelessWidget {
  final WaitCommand command;
  final VoidCallback? onUpdated;
  final VoidCallback? onRemoved;
  final ChangeStack undoStack;
  final VoidCallback? onDuplicateCommand;
  final bool highlighted;
  final CommandPreviewState? previewState;

  const WaitCommandWidget({
    super.key,
    required this.command,
    this.onUpdated,
    this.onRemoved,
    required this.undoStack,
    this.onDuplicateCommand,
    this.highlighted = false,
    this.previewState,
  });

  void _updateWaitTime(num newValue) {
    if (newValue >= 0) {
      undoStack.add(Change(
        command.waitTime,
        () {
          command.waitTime = newValue;
          onUpdated?.call();
        },
        (oldValue) {
          command.waitTime = oldValue;
          onUpdated?.call();
        },
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        if (highlighted)
          const Padding(
            padding: EdgeInsets.only(right: 8),
            child: Icon(Icons.play_arrow, color: Colors.pinkAccent, size: 18),
          ),
        CommandDelayStatus(
          command: command,
          previewState: previewState,
          activeColor: Colors.pinkAccent,
        ),
        if (command.hasExecutionDelays) const SizedBox(width: 8),
        const SizedBox(width: 8),
        Expanded(
          child: NumberTextField(
            initialValue: command.waitTime,
            label: 'Wait Time (S)',
            minValue: 0.0,
            onSubmitted: (value) {
              if (value != null) {
                _updateWaitTime(value);
              }
            },
            arrowKeyIncrement: 0.1,
          ),
        ),
        const SizedBox(width: 12),
        CommandActionsButton(
          onDuplicate: onDuplicateCommand,
          onRemove: onRemoved,
          onEditDelays: () => showCommandDelaysDialog(
            context: context,
            command: command,
            undoStack: undoStack,
            onUpdated: onUpdated,
          ),
        ),
      ],
    );
  }
}
