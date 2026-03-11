import 'package:flutter/material.dart';
import 'package:pathplanner/auto/pathplanner_auto.dart';
import 'package:pathplanner/widgets/editor/tree_widgets/commands/command_group_widget.dart';
import 'package:pathplanner/widgets/editor/tree_widgets/commands/command_preview_state.dart';
import 'package:pathplanner/widgets/editor/tree_widgets/editor_settings_tree.dart';
import 'package:pathplanner/widgets/editor/tree_widgets/reset_odom_tree.dart';
import 'package:undo/undo.dart';

class AutoTree extends StatefulWidget {
  final PathPlannerAuto auto;
  final List<String> allPathNames;
  final ValueChanged<String?>? onPathHovered;
  final VoidCallback? onSideSwapped;
  final VoidCallback? onAutoChanged;
  final ChangeStack undoStack;
  final num? autoRuntime;
  final Function(String?)? onEditPathPressed;
  final VoidCallback? onRenderAuto;
  final VoidCallback? onCollapseRequested;
  final VoidCallback? onMirrorRequested;
  final CommandPreviewState? previewState;

  const AutoTree({
    super.key,
    required this.auto,
    required this.allPathNames,
    this.onPathHovered,
    this.onSideSwapped,
    this.onAutoChanged,
    required this.undoStack,
    this.autoRuntime,
    this.onEditPathPressed,
    this.onRenderAuto,
    this.onCollapseRequested,
    this.onMirrorRequested,
    this.previewState,
  });

  @override
  State<AutoTree> createState() => _AutoTreeState();
}

class _AutoTreeState extends State<AutoTree> {
  @override
  Widget build(BuildContext context) {
    ColorScheme colorScheme = Theme.of(context).colorScheme;
    final tabs = [
      const Tab(text: 'Commands'),
      const Tab(text: 'Settings'),
    ];

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8.0),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Flexible(
                child: Text(
                  'Simulated Driving Time: ~${(widget.autoRuntime ?? 0).toStringAsFixed(2)}s',
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 18),
                ),
              ),
              Row(
                children: [
                  Tooltip(
                    message: 'Mirror Paths in Auto',
                    waitDuration: const Duration(milliseconds: 500),
                    child: IconButton(
                      onPressed: widget.onMirrorRequested,
                      icon: const Icon(Icons.flip),
                    ),
                  ),
                  Tooltip(
                    message: 'Collapse Commands Menu',
                    waitDuration: const Duration(milliseconds: 500),
                    child: IconButton(
                      onPressed: widget.onCollapseRequested,
                      icon: const Icon(Icons.keyboard_double_arrow_right),
                    ),
                  ),
                  Tooltip(
                    message: 'Export Auto to Image',
                    waitDuration: const Duration(milliseconds: 500),
                    child: IconButton(
                      onPressed: widget.onRenderAuto,
                      icon: const Icon(Icons.ios_share),
                    ),
                  ),
                  Tooltip(
                    message: 'Move to Other Side',
                    waitDuration: const Duration(seconds: 1),
                    child: IconButton(
                      onPressed: widget.onSideSwapped,
                      icon: const Icon(Icons.swap_horiz),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 4.0),
        Expanded(
          child: DefaultTabController(
            length: tabs.length,
            child: Column(
              children: [
                TabBar(isScrollable: true, tabs: tabs),
                const SizedBox(height: 4.0),
                Expanded(
                  child: TabBarView(
                    children: [
                      SingleChildScrollView(
                        child: Column(
                          children: [
                            Card(
                              elevation: 1.0,
                              color: colorScheme.surface,
                              surfaceTintColor: colorScheme.surfaceTint,
                              child: Padding(
                                padding: const EdgeInsets.all(8.0),
                                child: CommandGroupWidget(
                                  command: widget.auto.sequence,
                                  rootGroup: widget.auto.sequence,
                                  allPathNames: widget.allPathNames,
                                  onPathCommandHovered: widget.onPathHovered,
                                  onUpdated: widget.onAutoChanged,
                                  undoStack: widget.undoStack,
                                  showEditPathButton: !widget.auto.choreoAuto,
                                  onEditPathPressed: widget.onEditPathPressed,
                                  previewState: widget.previewState,
                                ),
                              ),
                            ),
                            ResetOdomTree(
                              auto: widget.auto,
                              onAutoChanged: widget.onAutoChanged,
                              undoStack: widget.undoStack,
                            ),
                          ],
                        ),
                      ),
                      const SingleChildScrollView(
                        child: Column(
                          children: [
                            EditorSettingsTree(),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
