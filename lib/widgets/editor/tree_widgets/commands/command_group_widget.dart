import 'package:flutter/material.dart';
import 'package:pathplanner/commands/command.dart';
import 'package:pathplanner/commands/command_groups.dart';
import 'package:pathplanner/commands/named_command.dart';
import 'package:pathplanner/commands/path_command.dart';
import 'package:pathplanner/commands/wait_command.dart';
import 'package:pathplanner/widgets/conditional_widget.dart';
import 'package:pathplanner/widgets/editor/tree_widgets/commands/add_command_button.dart';
import 'package:pathplanner/widgets/editor/tree_widgets/commands/duplicate_command_button.dart';
import 'package:pathplanner/widgets/editor/tree_widgets/commands/named_command_widget.dart';
import 'package:pathplanner/widgets/editor/tree_widgets/commands/path_command_widget.dart';
import 'package:pathplanner/widgets/editor/tree_widgets/commands/wait_command_widget.dart';
import 'package:undo/undo.dart';

class _RemovedCommandLocation {
  final Command command;
  final CommandGroup parent;
  final int index;

  const _RemovedCommandLocation({
    required this.command,
    required this.parent,
    required this.index,
  });
}

class CommandGroupWidget extends StatelessWidget {
  final CommandGroup command;
  final CommandGroup rootGroup;
  final VoidCallback? onUpdated;
  final VoidCallback? onRemoved;
  final ValueChanged<String>? onGroupTypeChanged;
  final double subCommandElevation;
  final List<String>? allPathNames;
  final ValueChanged<String?>? onPathCommandHovered;
  final ChangeStack undoStack;
  final VoidCallback? onDuplicateCommand;
  final bool showEditPathButton;
  final Function(String?)? onEditPathPressed;
  final ValueNotifier<Offset?> _groupPromptOffset = ValueNotifier(null);

  CommandGroupWidget({
    super.key,
    required this.command,
    required this.rootGroup,
    this.onUpdated,
    this.onGroupTypeChanged,
    this.onRemoved,
    this.subCommandElevation = 4.0,
    this.allPathNames,
    this.onPathCommandHovered,
    required this.undoStack,
    this.onDuplicateCommand,
    this.showEditPathButton = true,
    this.onEditPathPressed,
  });

  @override
  Widget build(BuildContext context) {
    ColorScheme colorScheme = Theme.of(context).colorScheme;

    String type =
        '${command.type[0].toUpperCase()}${command.type.substring(1)}';

    return DragTarget<Command>(
      onWillAcceptWithDetails: (details) =>
          _canDropIntoGroup(details.data, command),
      onAcceptWithDetails: (details) =>
          _moveCommandToGroup(details.data, command),
      builder: (context, candidates, rejects) {
        final highlighted = candidates.isNotEmpty;

        return AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: highlighted
                ? Border.all(color: colorScheme.primary, width: 1.5)
                : null,
            color: highlighted ? colorScheme.primary.withAlpha(20) : null,
          ),
          child: Column(
            children: [
              Row(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: Material(
                      color: Colors.transparent,
                      child: ConditionalWidget(
                        condition: onGroupTypeChanged != null,
                        falseChild: Text('$type Group',
                            style: const TextStyle(fontSize: 16)),
                        trueChild: PopupMenuButton(
                          initialValue: command.type,
                          tooltip: '',
                          elevation: 12.0,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                          onSelected: onGroupTypeChanged,
                          itemBuilder: (context) => const [
                            PopupMenuItem(
                              value: 'sequential',
                              child: Text('Sequential Group'),
                            ),
                            PopupMenuItem(
                              value: 'parallel',
                              child: Text('Parallel Group'),
                            ),
                            PopupMenuItem(
                              value: 'deadline',
                              child: Text('Deadline Group'),
                            ),
                            PopupMenuItem(
                              value: 'race',
                              child: Text('Race Group'),
                            ),
                          ],
                          child: Padding(
                            padding: const EdgeInsets.all(8.0),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text('$type Group',
                                    style: const TextStyle(fontSize: 16)),
                                const Icon(Icons.arrow_drop_down),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  Expanded(child: Container()),
                  AddCommandButton(
                    allowPathCommand: allPathNames != null,
                    onTypeChosen: (value) {
                      undoStack.add(Change(
                        CommandGroup.cloneCommandsList(command.commands),
                        () {
                          final cmd = Command.fromType(value);
                          if (cmd != null) {
                            command.commands.insert(0, cmd);
                            onUpdated?.call();
                          }
                        },
                        (oldValue) {
                          command.commands =
                              CommandGroup.cloneCommandsList(oldValue);
                          onUpdated?.call();
                        },
                      ));
                    },
                  ),
                  Visibility(
                      visible: onDuplicateCommand != null,
                      child: DuplicateCommandButton(
                        onPressed: onDuplicateCommand,
                      )),
                  Visibility(
                    visible: onRemoved != null,
                    child: Tooltip(
                      message: 'Remove Command',
                      waitDuration: const Duration(seconds: 1),
                      child: IconButton(
                        onPressed: onRemoved,
                        visualDensity: const VisualDensity(
                            horizontal: VisualDensity.minimumDensity,
                            vertical: VisualDensity.minimumDensity),
                        icon: Icon(Icons.delete, color: colorScheme.error),
                      ),
                    ),
                  ),
                ],
              ),
              _buildReorderableList(context),
            ],
          ),
        );
      },
    );
  }

  Widget _buildReorderableList(BuildContext context) {
    ColorScheme colorScheme = Theme.of(context).colorScheme;

    return Column(
      children: [
        for (int index = 0; index < command.commands.length; index++)
          Container(
            key: ObjectKey(command.commands[index]),
            child: Column(
              children: [
                _buildInsertTarget(context, index),
                if (command.commands[index] is PathCommand)
                  _buildGroupCreationTarget(
                    context: context,
                    targetCommand: command.commands[index],
                    child: MouseRegion(
                      onEnter: (event) => onPathCommandHovered
                          ?.call((command.commands[index] as PathCommand).pathName),
                      onExit: (event) => onPathCommandHovered?.call(null),
                      child: Card(
                        elevation: subCommandElevation,
                        color: colorScheme.primaryContainer,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 16.0),
                          child: Row(
                            children: [
                              _buildDragHandle(context, command.commands[index]),
                              const SizedBox(width: 8),
                              Expanded(
                                child: PathCommandWidget(
                                  command: command.commands[index] as PathCommand,
                                  allPathNames: allPathNames ?? [],
                                  onUpdated: onUpdated,
                                  onRemoved: () {
                                    onPathCommandHovered?.call(null);
                                    _removeCommand(index);
                                  },
                                  undoStack: undoStack,
                                  onDuplicateCommand: () => _duplicateCommand(index),
                                  showEditButton: showEditPathButton,
                                  onEditPathPressed: onEditPathPressed,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  )
                else
                  _buildGroupCreationTarget(
                    context: context,
                    targetCommand: command.commands[index],
                    child: Card(
                      elevation: subCommandElevation,
                      color: colorScheme.surface,
                      surfaceTintColor: colorScheme.surfaceTint,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 16.0),
                        child: Row(
                          children: [
                            _buildDragHandle(context, command.commands[index]),
                            const SizedBox(width: 8),
                            Expanded(child: _buildSubCommand(index)),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        _buildInsertTarget(context, command.commands.length),
      ],
    );
  }

  Widget _buildGroupCreationTarget({
    required BuildContext context,
    required Command targetCommand,
    required Widget child,
  }) {
    final colorScheme = Theme.of(context).colorScheme;

    return DragTarget<Command>(
      onWillAcceptWithDetails: (details) =>
          _canCreateGroupFromDrop(details.data, targetCommand),
      onMove: (details) {
        _groupPromptOffset.value = details.offset;
      },
      onLeave: (data) {
        _groupPromptOffset.value = null;
      },
      onAcceptWithDetails: (details) {
        _groupPromptOffset.value = null;
        _promptCreateGroup(
          context: context,
          dragged: details.data,
          target: targetCommand,
          dropOffset: details.offset,
        );
      },
      builder: (context, candidates, rejects) {
        final highlighted = candidates.isNotEmpty;

        return Stack(
          clipBehavior: Clip.none,
          children: [
            child,
            if (highlighted)
              Positioned.fill(
                child: IgnorePointer(
                  child: Container(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: colorScheme.primary, width: 2),
                      color: colorScheme.primary.withAlpha(16),
                    ),
                  ),
                ),
              ),
            if (highlighted)
              ValueListenableBuilder<Offset?>(
                valueListenable: _groupPromptOffset,
                builder: (context, globalOffset, _) {
                  if (globalOffset == null) {
                    return const SizedBox();
                  }

                  final renderObj = context.findRenderObject();
                  if (renderObj is! RenderBox) {
                    return const SizedBox();
                  }

                  final localOffset = renderObj.globalToLocal(globalOffset);
                  final maxX = (renderObj.size.width - 70).toDouble();
                  final maxY = (renderObj.size.height - 26).toDouble();

                  final dxMin = maxX < 6.0 ? maxX : 6.0;
                  final dxMax = maxX < 6.0 ? 6.0 : maxX;
                  final dyMin = maxY < 4.0 ? maxY : 4.0;
                  final dyMax = maxY < 4.0 ? 4.0 : maxY;

                  final dx = (localOffset.dx + 12).clamp(dxMin, dxMax);
                  final dy = (localOffset.dy - 28).clamp(dyMin, dyMax);

                  return Positioned(
                    left: dx,
                    top: dy,
                    child: IgnorePointer(
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(
                          color: colorScheme.primary,
                          borderRadius: BorderRadius.circular(6),
                          boxShadow: [
                            BoxShadow(
                              blurRadius: 6,
                              offset: const Offset(0, 2),
                              color: colorScheme.shadow.withAlpha(80),
                            ),
                          ],
                        ),
                        child: Text(
                          'Group?',
                          style: TextStyle(color: colorScheme.onPrimary),
                        ),
                      ),
                    ),
                  );
                },
              ),
          ],
        );
      },
    );
  }

  Widget _buildDragHandle(BuildContext context, Command draggedCommand) {
    return Draggable<Command>(
      data: draggedCommand,
      feedback: _buildCommandDragFeedback(context, draggedCommand),
      childWhenDragging: const Opacity(
        opacity: 0.3,
        child: Icon(Icons.drag_handle),
      ),
      child: const Icon(Icons.drag_handle),
    );
  }

  Widget _buildInsertTarget(BuildContext context, int targetIndex) {
    final colorScheme = Theme.of(context).colorScheme;

    return DragTarget<Command>(
      onWillAcceptWithDetails: (details) =>
          _canDropIntoGroup(details.data, command),
      onAcceptWithDetails: (details) => _moveCommandToGroup(
        details.data,
        command,
        targetIndex: targetIndex,
      ),
      builder: (context, candidates, rejects) {
        final highlighted = candidates.isNotEmpty;

        return AnimatedContainer(
          duration: const Duration(milliseconds: 100),
          margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
          height: highlighted ? 18 : 8,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color:
                highlighted ? colorScheme.primary.withAlpha(35) : Colors.transparent,
            borderRadius: BorderRadius.circular(4),
            border: highlighted
                ? Border.all(color: colorScheme.primary, width: 1)
                : Border.all(color: Colors.transparent, width: 1),
          ),
          child: highlighted
              ? Text(
                  'Drop here',
                  style: TextStyle(
                    fontSize: 11,
                    color: colorScheme.primary,
                    fontWeight: FontWeight.w500,
                  ),
                )
              : null,
        );
      },
    );
  }

  Widget _buildSubCommand(int cmdIndex) {
    if (command.commands[cmdIndex] is NamedCommand) {
      return NamedCommandWidget(
        command: command.commands[cmdIndex] as NamedCommand,
        onUpdated: onUpdated,
        onRemoved: () => _removeCommand(cmdIndex),
        undoStack: undoStack,
        onDuplicateCommand: () => _duplicateCommand(cmdIndex),
      );
    } else if (command.commands[cmdIndex] is WaitCommand) {
      return WaitCommandWidget(
        command: command.commands[cmdIndex] as WaitCommand,
        onUpdated: onUpdated,
        onRemoved: () => _removeCommand(cmdIndex),
        undoStack: undoStack,
        onDuplicateCommand: () => _duplicateCommand(cmdIndex),
      );
    } else if (command.commands[cmdIndex] is CommandGroup) {
      return CommandGroupWidget(
        command: command.commands[cmdIndex] as CommandGroup,
        rootGroup: rootGroup,
        undoStack: undoStack,
        subCommandElevation: (subCommandElevation == 1.0) ? 4.0 : 1.0,
        onUpdated: onUpdated,
        onRemoved: () => _removeCommand(cmdIndex),
        allPathNames: allPathNames,
        onPathCommandHovered: onPathCommandHovered,
        showEditPathButton: showEditPathButton,
        onEditPathPressed: onEditPathPressed,
        onGroupTypeChanged: (value) {
          undoStack.add(Change(
            command.commands[cmdIndex].type,
            () {
              List<Command> cmds =
                  (command.commands[cmdIndex] as CommandGroup).commands;
              final cmd = Command.fromType(value, commands: cmds);
              if (cmd != null) {
                command.commands[cmdIndex] = cmd;
                onUpdated?.call();
              }
            },
            (oldValue) {
              List<Command> cmds =
                  (command.commands[cmdIndex] as CommandGroup).commands;
              final cmd = Command.fromType(oldValue, commands: cmds);
              if (cmd != null) {
                command.commands[cmdIndex] = cmd;
                onUpdated?.call();
              }
            },
          ));
        },
        onDuplicateCommand: () => _duplicateCommand(cmdIndex),
      );
    }

    return Container();
  }

  Widget _buildCommandDragFeedback(BuildContext context, Command dragged) {
    final colorScheme = Theme.of(context).colorScheme;
    return Material(
      color: Colors.transparent,
      child: Card(
        elevation: 8,
        color: colorScheme.surface,
        surfaceTintColor: colorScheme.surfaceTint,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Text(_commandDisplayName(dragged)),
        ),
      ),
    );
  }

  String _commandDisplayName(Command cmd) {
    if (cmd is PathCommand) return 'Follow Path';
    if (cmd is WaitCommand) return 'Wait';
    if (cmd is NamedCommand) return 'Named Command';
    if (cmd is CommandGroup) {
      return '${cmd.type[0].toUpperCase()}${cmd.type.substring(1)} Group';
    }
    return 'Command';
  }

  bool _canDropIntoGroup(Command dragged, CommandGroup targetGroup) {
    if (identical(dragged, targetGroup)) {
      return false;
    }

    if (!_groupContainsCommand(rootGroup, dragged)) {
      return false;
    }

    if (dragged is CommandGroup && _groupContainsCommand(dragged, targetGroup)) {
      return false;
    }

    return true;
  }

  bool _canCreateGroupFromDrop(Command dragged, Command target) {
    if (identical(dragged, target)) {
      return false;
    }

    if (!_groupContainsCommand(rootGroup, dragged) ||
        !_groupContainsCommand(rootGroup, target)) {
      return false;
    }

    if (dragged is CommandGroup && _groupContainsCommand(dragged, target)) {
      return false;
    }

    if (target is CommandGroup && _groupContainsCommand(target, dragged)) {
      return false;
    }

    return true;
  }

  Future<void> _promptCreateGroup({
    required BuildContext context,
    required Command dragged,
    required Command target,
    required Offset dropOffset,
  }) async {
    if (!_canCreateGroupFromDrop(dragged, target)) {
      return;
    }

    final selectedType = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        dropOffset.dx,
        dropOffset.dy,
        dropOffset.dx,
        dropOffset.dy,
      ),
      items: const [
        PopupMenuItem<String>(
          enabled: false,
          child: Text('Create Group'),
        ),
        PopupMenuDivider(),
        PopupMenuItem<String>(
          value: 'sequential',
          child: Text('Sequential Group'),
        ),
        PopupMenuItem<String>(
          value: 'parallel',
          child: Text('Parallel Group'),
        ),
        PopupMenuItem<String>(
          value: 'deadline',
          child: Text('Deadline Group'),
        ),
        PopupMenuItem<String>(
          value: 'race',
          child: Text('Race Group'),
        ),
      ],
    );

    if (selectedType == null) {
      return;
    }

    _groupTwoCommands(
      target: target,
      dragged: dragged,
      groupType: selectedType,
    );
  }

  _RemovedCommandLocation? _findCommandLocation(
      CommandGroup group, Command target) {
    for (int i = 0; i < group.commands.length; i++) {
      final cmd = group.commands[i];
      if (identical(cmd, target)) {
        return _RemovedCommandLocation(command: cmd, parent: group, index: i);
      }
      if (cmd is CommandGroup) {
        final found = _findCommandLocation(cmd, target);
        if (found != null) {
          return found;
        }
      }
    }
    return null;
  }

  void _groupTwoCommands({
    required Command target,
    required Command dragged,
    required String groupType,
  }) {
    if (!_canCreateGroupFromDrop(dragged, target)) {
      return;
    }

    undoStack.add(Change(
      CommandGroup.cloneCommandsList(rootGroup.commands),
      () {
        final targetLoc = _findCommandLocation(rootGroup, target);
        final draggedLoc = _findCommandLocation(rootGroup, dragged);

        if (targetLoc == null || draggedLoc == null) {
          return;
        }

        int insertIndex = targetLoc.index;
        if (identical(targetLoc.parent, draggedLoc.parent) &&
            draggedLoc.index < targetLoc.index) {
          insertIndex -= 1;
        }

        final removedDragged = _removeCommandFromGroup(rootGroup, dragged);
        final removedTarget = _removeCommandFromGroup(rootGroup, target);

        if (removedDragged == null || removedTarget == null) {
          return;
        }

        final grouped = Command.fromType(groupType, commands: [
          removedTarget.command,
          removedDragged.command,
        ]);

        if (grouped is! CommandGroup) {
          return;
        }

        targetLoc.parent.commands.insert(insertIndex, grouped);
        onUpdated?.call();
      },
      (oldValue) {
        rootGroup.commands = CommandGroup.cloneCommandsList(oldValue);
        onUpdated?.call();
      },
    ));
  }

  bool _groupContainsCommand(CommandGroup group, Command target) {
    for (final cmd in group.commands) {
      if (identical(cmd, target)) {
        return true;
      }
      if (cmd is CommandGroup && _groupContainsCommand(cmd, target)) {
        return true;
      }
    }
    return false;
  }

  _RemovedCommandLocation? _removeCommandFromGroup(CommandGroup group, Command target) {
    for (int i = 0; i < group.commands.length; i++) {
      final cmd = group.commands[i];

      if (identical(cmd, target)) {
        return _RemovedCommandLocation(
          command: group.commands.removeAt(i),
          parent: group,
          index: i,
        );
      }

      if (cmd is CommandGroup) {
        final removed = _removeCommandFromGroup(cmd, target);
        if (removed != null) {
          return removed;
        }
      }
    }

    return null;
  }

  void _moveCommandToGroup(
    Command dragged,
    CommandGroup targetGroup, {
    int? targetIndex,
  }) {
    if (!_canDropIntoGroup(dragged, targetGroup)) {
      return;
    }

    undoStack.add(Change(
      CommandGroup.cloneCommandsList(rootGroup.commands),
      () {
        final removed = _removeCommandFromGroup(rootGroup, dragged);
        if (removed != null) {
          int insertIndex = targetIndex ?? targetGroup.commands.length;

          if (identical(removed.parent, targetGroup) &&
              removed.index < insertIndex) {
            insertIndex -= 1;
          }

            final int finalIndex =
              insertIndex.clamp(0, targetGroup.commands.length);

          if (identical(removed.parent, targetGroup) &&
              finalIndex == removed.index) {
            return;
          }

          targetGroup.commands.insert(finalIndex, removed.command);
          onUpdated?.call();
        }
      },
      (oldValue) {
        rootGroup.commands = CommandGroup.cloneCommandsList(oldValue);
        onUpdated?.call();
      },
    ));
  }

  void _removeCommand(int idx) {
    undoStack.add(Change(
      CommandGroup.cloneCommandsList(command.commands),
      () {
        command.commands.removeAt(idx);
        onUpdated?.call();
      },
      (oldValue) {
        command.commands = CommandGroup.cloneCommandsList(oldValue);
        onUpdated?.call();
      },
    ));
  }

  void _duplicateCommand(int idx) {
    undoStack.add(Change(
      CommandGroup.cloneCommandsList(command.commands),
      () {
        Command commandToDuplicate = command.commands.elementAt(idx).clone();
        command.commands.insert(idx + 1, commandToDuplicate);
        onUpdated?.call();
      },
      (oldValue) {
        command.commands = CommandGroup.cloneCommandsList(oldValue);
        onUpdated?.call();
      },
    ));
  }
}
