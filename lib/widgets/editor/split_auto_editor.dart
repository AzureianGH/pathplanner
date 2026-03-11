import 'dart:math';

import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:multi_split_view/multi_split_view.dart';
import 'package:pathplanner/auto/pathplanner_auto.dart';
import 'package:pathplanner/commands/command.dart';
import 'package:pathplanner/commands/command_groups.dart';
import 'package:pathplanner/commands/path_command.dart';
import 'package:pathplanner/commands/wait_command.dart';
import 'package:pathplanner/path/choreo_path.dart';
import 'package:pathplanner/services/log.dart';
import 'package:pathplanner/trajectory/config.dart';
import 'package:pathplanner/trajectory/trajectory.dart';
import 'package:pathplanner/path/pathplanner_path.dart';
import 'package:pathplanner/util/mirror_util.dart';
import 'package:pathplanner/util/path_painter_util.dart';
import 'package:pathplanner/util/prefs.dart';
import 'package:pathplanner/util/wpimath/geometry.dart';
import 'package:pathplanner/util/wpimath/kinematics.dart';
import 'package:pathplanner/widgets/dialogs/trajectory_render_dialog.dart';
import 'package:pathplanner/widgets/editor/path_painter.dart';
import 'package:pathplanner/widgets/editor/preview_seekbar.dart';
import 'package:pathplanner/widgets/editor/tree_widgets/auto_tree.dart';
import 'package:pathplanner/widgets/editor/tree_widgets/commands/command_preview_state.dart';
import 'package:pathplanner/widgets/field_image.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:undo/undo.dart';

class SplitAutoEditor extends StatefulWidget {
  final SharedPreferences prefs;
  final PathPlannerAuto auto;
  final List<PathPlannerPath> allPaths;
  final List<PathPlannerPath> autoPaths;
  final List<ChoreoPath> autoChoreoPaths;
  final List<String> allPathNames;
  final VoidCallback? onAutoChanged;
  final FieldImage fieldImage;
  final ChangeStack undoStack;
  final Function(String?)? onEditPathPressed;

  const SplitAutoEditor({
    required this.prefs,
    required this.auto,
    required this.allPaths,
    required this.autoPaths,
    required this.autoChoreoPaths,
    required this.allPathNames,
    required this.fieldImage,
    required this.undoStack,
    this.onAutoChanged,
    this.onEditPathPressed,
    super.key,
  });

  @override
  State<SplitAutoEditor> createState() => _SplitAutoEditorState();
}

class _SplitAutoEditorState extends State<SplitAutoEditor>
    with SingleTickerProviderStateMixin {
  final MultiSplitViewController _controller = MultiSplitViewController();
  String? _hoveredPath;
  late bool _treeOnRight;
  late String _layoutPreset;
  bool _commandsCollapsed = false;
  PathPlannerTrajectory? _simTraj;
  List<TimedPathRange> _timedPathRanges = [];
  List<_TimedCommandHighlight> _timedCommandHighlights = [];
  CommandPreviewState? _activeCommandPreviewState;
  bool _paused = false;
  final TransformationController _viewerController = TransformationController();
  bool _mirrorMode = false;
  bool _mirrorModeCommandsCollapsedBefore = false;
  double _mirrorAxisAngleRad = pi / 2.0;

  late AnimationController _previewController;

  @override
  void initState() {
    super.initState();

    _previewController = AnimationController(vsync: this);

    _treeOnRight =
        widget.prefs.getBool(PrefsKeys.treeOnRight) ?? Defaults.treeOnRight;
    _layoutPreset = widget.prefs.getString(PrefsKeys.editorLayoutPreset) ??
        Defaults.editorLayoutPreset;

    double treeWeight = widget.prefs.getDouble(PrefsKeys.editorTreeWeight) ??
        Defaults.editorTreeWeight;
    _controller.areas = [
      Area(
        weight: _treeOnRight ? (1.0 - treeWeight) : treeWeight,
        minimalWeight: 0.08,
      ),
      Area(
        weight: _treeOnRight ? treeWeight : (1.0 - treeWeight),
        minimalWeight: 0.08,
      ),
    ];

    _applyLayoutPreset(_layoutPreset, savePref: false);

    HardwareKeyboard.instance.addHandler(_handleKeyEvent);
    _previewController.addListener(_handlePreviewTick);

    WidgetsBinding.instance.addPostFrameCallback((_) => _simulateAuto());
  }

  void dispose() {
    HardwareKeyboard.instance.removeHandler(_handleKeyEvent);
    _previewController.removeListener(_handlePreviewTick);
    _viewerController.dispose();
    _previewController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ColorScheme colorScheme = Theme.of(context).colorScheme;

    return Stack(
      children: [
        Center(
          child: InteractiveViewer(
            maxScale: 10.0,
            transformationController: _viewerController,
            panEnabled: !_mirrorMode,
            scaleEnabled: !_mirrorMode,
            child: MouseRegion(
              onHover: (details) {
                if (_mirrorMode) {
                  _updateMirrorAxisFromLocal(details.localPosition);
                }
              },
              child: GestureDetector(
                onTapDown: (details) {
                  if (_mirrorMode) {
                    _updateMirrorAxisFromLocal(details.localPosition);
                  }
                },
                onTapUp: (details) {
                  if (_mirrorMode) {
                    _updateMirrorAxisFromLocal(details.localPosition);
                    _applyMirrorToAutoPaths();
                  }
                },
                onPanStart: (details) {
                  if (_mirrorMode) {
                    _updateMirrorAxisFromLocal(details.localPosition);
                  }
                },
                onPanUpdate: (details) {
                  if (_mirrorMode) {
                    _updateMirrorAxisFromLocal(details.localPosition);
                  }
                },
                onPanEnd: (details) {
                  if (_mirrorMode) {
                    _applyMirrorToAutoPaths();
                  }
                },
                child: Padding(
                  padding: const EdgeInsets.all(48),
                  child: Stack(
                    children: [
                      widget.fieldImage.getWidget(),
                      Positioned.fill(
                        child: CustomPaint(
                            painter: PathPainter(
                                colorScheme: colorScheme,
                                paths: widget.autoPaths,
                                choreoPaths: widget.autoChoreoPaths,
                                simple: true,
                                hideOtherPathsOnHover: widget.prefs
                                        .getBool(PrefsKeys.hidePathsOnHover) ??
                                    Defaults.hidePathsOnHover,
                                hoveredPath: _hoveredPath,
                                fieldImage: widget.fieldImage,
                                simulatedPath: _simTraj,
                                timedPathRanges: _timedPathRanges,
                                animation: _previewController.view,
                                prefs: widget.prefs)),
                      ),
                      if (_mirrorMode)
                        Positioned.fill(
                          child: IgnorePointer(
                            child: CustomPaint(
                              painter: _MirrorAxisPainter(
                                start: _mirrorAxisStartPx,
                                end: _mirrorAxisEndPx,
                                color: colorScheme.primary,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
        MultiSplitViewTheme(
          data: MultiSplitViewThemeData(
            dividerPainter: DividerPainters.grooved1(
              color: colorScheme.surfaceContainerHighest,
              highlightedColor: colorScheme.primary,
            ),
          ),
          child: MultiSplitView(
            axis: Axis.horizontal,
            controller: _controller,
            onWeightChange: () {
              if (_commandsCollapsed) return;

              double? newWeight = _treeOnRight
                  ? _controller.areas[1].weight
                  : _controller.areas[0].weight;
              widget.prefs
                  .setDouble(PrefsKeys.editorTreeWeight, newWeight ?? 0.5);
            },
            children: [
              if (_treeOnRight)
                PreviewSeekbar(
                  previewController: _previewController,
                  onPauseStateChanged: (value) => _paused = value,
                  totalPathTime: _simTraj?.states.last.timeSeconds ?? 1.0,
                ),
              if (!_commandsCollapsed)
                Card(
                  margin: const EdgeInsets.all(0),
                  elevation: 4.0,
                  color: colorScheme.surface,
                  surfaceTintColor: colorScheme.surfaceTint,
                  child: Padding(
                    padding: const EdgeInsets.all(8.0),
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        return _buildResponsiveTreeScale(
                          constraints.maxWidth,
                          AutoTree(
                            auto: widget.auto,
                            autoRuntime: _simTraj?.states.last.timeSeconds,
                            allPathNames: widget.allPathNames,
                            onRenderAuto: () {
                              if (_simTraj != null) {
                                showDialog(
                                    context: context,
                                    builder: (context) {
                                      return TrajectoryRenderDialog(
                                        fieldImage: widget.fieldImage,
                                        prefs: widget.prefs,
                                        trajectory: _simTraj!,
                                      );
                                    });
                              }
                            },
                            onPathHovered: (value) {
                              setState(() {
                                _hoveredPath = value;
                              });
                            },
                            onAutoChanged: () {
                              widget.onAutoChanged?.call();
                              Future.delayed(const Duration(milliseconds: 100))
                                  .then((_) {
                                _simulateAuto();
                              });
                            },
                            onSideSwapped: () => setState(() {
                              _treeOnRight = !_treeOnRight;
                              widget.prefs
                                  .setBool(PrefsKeys.treeOnRight, _treeOnRight);
                              _controller.areas =
                                  _controller.areas.reversed.toList();
                            }),
                            undoStack: widget.undoStack,
                            onEditPathPressed: widget.onEditPathPressed,
                            onCollapseRequested: () {
                              setState(() {
                                _commandsCollapsed = true;
                              });
                            },
                            onMirrorRequested: _startMirrorMode,
                            previewState: _activeCommandPreviewState,
                          ),
                        );
                      },
                    ),
                  ),
                ),
              if (!_treeOnRight)
                PreviewSeekbar(
                  previewController: _previewController,
                  onPauseStateChanged: (value) => _paused = value,
                  totalPathTime: _simTraj?.states.last.timeSeconds ?? 1.0,
                ),
            ],
          ),
        ),
        if (_commandsCollapsed)
          Positioned(
            top: 12,
            right: _treeOnRight ? 12 : null,
            left: _treeOnRight ? null : 12,
            child: FilledButton.icon(
              onPressed: () {
                setState(() {
                  _commandsCollapsed = false;
                });
              },
              icon: const Icon(Icons.keyboard_double_arrow_left),
              label: const Text('Commands'),
            ),
          ),
        if (_mirrorMode)
          Positioned(
            top: 12,
            left: 12,
            child: Card(
              elevation: 4,
              child: Padding(
                padding: const EdgeInsets.all(10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Mirror Mode',
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 4),
                    Text('Axis: ${_mirrorAxisDegLabel}°'),
                    const SizedBox(height: 2),
                    const Text(
                        'Left Click: apply   Shift: free spin   Esc: cancel'),
                    const SizedBox(height: 8),
                    OutlinedButton(onPressed: _cancelMirrorMode, child: const Text('Cancel'),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }

  // Marked as async so it can run from initState
  void _simulateAuto() async {
    if (widget.autoPaths.isEmpty && widget.autoChoreoPaths.isEmpty) {
      setState(() {
        _simTraj = null;
        _timedPathRanges = [];
        _timedCommandHighlights = [];
        _activeCommandPreviewState = null;
      });

      _previewController.stop();
      _previewController.reset();

      return;
    }

    PathPlannerTrajectory? simPath;
    List<TimedPathRange> pathRanges = [];
    List<_TimedCommandHighlight> commandHighlights = [];

    if (widget.auto.choreoAuto) {
      final pathMap = _buildChoreoPathCommandMap(
        widget.auto.sequence.commands,
        widget.autoChoreoPaths,
      );
      final initialPose = widget.autoChoreoPaths.isNotEmpty &&
              widget.autoChoreoPaths.first.trajectory.states.isNotEmpty
          ? widget.autoChoreoPaths.first.trajectory.states.first.pose
          : null;

      if (initialPose != null) {
        final execution = _simulateChoreoCommand(
          widget.auto.sequence,
          pathMap: pathMap,
          initialPose: initialPose,
        );
        if (execution.states.isNotEmpty) {
          simPath = PathPlannerTrajectory.fromStates(execution.states);
          pathRanges = execution.pathRanges;
          commandHighlights = execution.commandHighlights;
        }
      }
    } else {
      RobotConfig config = RobotConfig.fromPrefs(widget.prefs);

      try {
        final pathMap = _buildPathCommandMap(
          widget.auto.sequence.commands,
          widget.autoPaths,
        );
        final initialPose = Pose2d(widget.autoPaths[0].pathPoints[0].position,
            widget.autoPaths[0].idealStartingState.rotation);
        final execution = _simulatePlannerCommand(
          widget.auto.sequence,
          pathMap: pathMap,
          robotConfig: config,
          initialPose: initialPose,
          initialSpeeds: const ChassisSpeeds(),
        );

        if (execution.states.isNotEmpty) {
          simPath = PathPlannerTrajectory.fromStates(execution.states);
          pathRanges = execution.pathRanges;
          commandHighlights = execution.commandHighlights;
        }

        if (!(simPath?.getTotalTimeSeconds().isFinite ?? false)) {
          simPath = null;
          pathRanges = [];
        }
      } catch (err) {
        Log.error('Failed to simulate auto', err);
        pathRanges = [];
      }
    }

    if (simPath != null &&
        simPath.states.last.timeSeconds.isFinite &&
        !simPath.states.last.timeSeconds.isNaN) {
      setState(() {
        _simTraj = simPath;
        _timedPathRanges = pathRanges;
        _timedCommandHighlights = commandHighlights;
        _activeCommandPreviewState = _previewStateForTime(0);
      });

      try {
        if (!_paused) {
          _previewController.stop();
          _previewController.reset();
          _previewController.duration = Duration(
              milliseconds: (simPath.states.last.timeSeconds * 1000).toInt());
          _previewController.repeat();
        } else {
          double prevTime = _previewController.value *
              (_previewController.duration!.inMilliseconds / 1000.0);
          _previewController.duration = Duration(
              milliseconds: (simPath.states.last.timeSeconds * 1000).toInt());
          double newPos = prevTime / simPath.states.last.timeSeconds;
          _previewController.forward(from: newPos);
          _previewController.stop();
        }
      } catch (_) {
        _showGenerationFailedError();
      }
    } else {
      // Trajectory failed to generate. Notify the user
      setState(() {
        _timedPathRanges = [];
        _timedCommandHighlights = [];
        _activeCommandPreviewState = null;
      });
      _showGenerationFailedError();
    }
  }

  _CommandSimulation _createStationaryWait({
    required Command command,
    required num duration,
    required Pose2d? pose,
    ChassisSpeeds? speeds,
    bool highlight = true,
    CommandPreviewPhase phase = CommandPreviewPhase.running,
  }) {
    if (duration <= 0) {
      return _CommandSimulation.empty(
        pose: pose,
        speeds: speeds ?? const ChassisSpeeds(),
      );
    }

    if (pose == null) {
      return _CommandSimulation.empty(
        duration: duration,
        pose: null,
        speeds: speeds ?? const ChassisSpeeds(),
        commandHighlights: highlight
            ? [
                _TimedCommandHighlight(
                  command: command,
                  startTime: 0,
                  endTime: duration,
                  phase: phase,
                ),
              ]
            : const [],
      );
    }

    return _CommandSimulation(
      states: [
        TrajectoryState.pregen(0, const ChassisSpeeds(), pose),
        TrajectoryState.pregen(duration, const ChassisSpeeds(), pose),
      ],
      pathRanges: const [],
      commandHighlights: highlight
          ? [
              _TimedCommandHighlight(
                command: command,
                startTime: 0,
                endTime: duration,
                phase: phase,
              ),
            ]
          : const [],
      duration: duration,
      endPose: pose,
      endSpeeds: const ChassisSpeeds(),
    );
  }

  _CommandSimulation _simulatePlannerCommand(
    Command command, {
    required Map<PathCommand, PathPlannerPath> pathMap,
    required RobotConfig robotConfig,
    required Pose2d initialPose,
    required ChassisSpeeds initialSpeeds,
  }) {
    final beforeWait = _createStationaryWait(
      command: command,
      duration: command.beforeDelay,
      pose: initialPose,
      speeds: initialSpeeds,
      highlight: command.beforeDelay > 0,
      phase: CommandPreviewPhase.beforeDelay,
    );

    final bodyStartPose = beforeWait.endPose ?? initialPose;
    final bodyStartSpeeds = beforeWait.endSpeeds;

    late final _CommandSimulation body;
    if (command is WaitCommand) {
      body = _createStationaryWait(
        command: command,
        duration: command.waitTime,
        pose: bodyStartPose,
        speeds: bodyStartSpeeds,
      );
    } else if (command is PathCommand) {
      final path = pathMap[command];
      if (path == null) {
        body = _CommandSimulation.empty(
          pose: bodyStartPose,
          speeds: bodyStartSpeeds,
        );
      } else {
        final pathTraj = PathPlannerTrajectory(
          path: path,
          startingSpeeds: bodyStartSpeeds,
          startingRotation: bodyStartPose.rotation,
          robotConfig: robotConfig,
        );
        body = _simulationFromTrajectory(
          command: command,
          pathName: path.name,
          trajectory: pathTraj,
          isChoreoPath: false,
        );
      }
    } else if (command is SequentialCommandGroup) {
      body = _simulateSequentialPlannerGroup(
        command.commands,
        pathMap: pathMap,
        robotConfig: robotConfig,
        initialPose: bodyStartPose,
        initialSpeeds: bodyStartSpeeds,
      );
    } else if (command is ParallelCommandGroup) {
      body = _simulateConcurrentPlannerGroup(
        command.commands,
        pathMap: pathMap,
        robotConfig: robotConfig,
        initialPose: bodyStartPose,
        initialSpeeds: bodyStartSpeeds,
        mode: _ConcurrentGroupMode.parallel,
      );
    } else if (command is DeadlineCommandGroup) {
      body = _simulateConcurrentPlannerGroup(
        command.commands,
        pathMap: pathMap,
        robotConfig: robotConfig,
        initialPose: bodyStartPose,
        initialSpeeds: bodyStartSpeeds,
        mode: _ConcurrentGroupMode.deadline,
      );
    } else if (command is RaceCommandGroup) {
      body = _simulateConcurrentPlannerGroup(
        command.commands,
        pathMap: pathMap,
        robotConfig: robotConfig,
        initialPose: bodyStartPose,
        initialSpeeds: bodyStartSpeeds,
        mode: _ConcurrentGroupMode.race,
      );
    } else {
      body = _CommandSimulation.empty(
        pose: bodyStartPose,
        speeds: bodyStartSpeeds,
      );
    }

    final afterWait = _createStationaryWait(
      command: command,
      duration: command.afterDelay,
      pose: body.endPose ?? bodyStartPose,
      speeds: body.endSpeeds,
      highlight: command.afterDelay > 0,
      phase: CommandPreviewPhase.afterDelay,
    );

    return _joinSimulations([beforeWait, body, afterWait]);
  }

  _CommandSimulation _simulateSequentialPlannerGroup(
    List<Command> commands, {
    required Map<PathCommand, PathPlannerPath> pathMap,
    required RobotConfig robotConfig,
    required Pose2d initialPose,
    required ChassisSpeeds initialSpeeds,
  }) {
    final parts = <_CommandSimulation>[];
    Pose2d currentPose = initialPose;
    ChassisSpeeds currentSpeeds = initialSpeeds;

    for (final child in commands) {
      final childSim = _simulatePlannerCommand(
        child,
        pathMap: pathMap,
        robotConfig: robotConfig,
        initialPose: currentPose,
        initialSpeeds: currentSpeeds,
      );
      parts.add(childSim);
      currentPose = childSim.endPose ?? currentPose;
      currentSpeeds = childSim.endSpeeds;
    }

    return _joinSimulations(parts);
  }

  _CommandSimulation _simulateConcurrentPlannerGroup(
    List<Command> commands, {
    required Map<PathCommand, PathPlannerPath> pathMap,
    required RobotConfig robotConfig,
    required Pose2d initialPose,
    required ChassisSpeeds initialSpeeds,
    required _ConcurrentGroupMode mode,
  }) {
    if (commands.isEmpty) {
      return _CommandSimulation.empty(
        pose: initialPose,
        speeds: initialSpeeds,
      );
    }

    final childSims = [
      for (final child in commands)
        _simulatePlannerCommand(
          child,
          pathMap: pathMap,
          robotConfig: robotConfig,
          initialPose: initialPose,
          initialSpeeds: initialSpeeds,
        ),
    ];

    num targetDuration;
    switch (mode) {
      case _ConcurrentGroupMode.parallel:
        targetDuration = childSims.map((sim) => sim.duration).fold<num>(0, max);
        break;
      case _ConcurrentGroupMode.deadline:
        targetDuration = childSims.first.duration;
        break;
      case _ConcurrentGroupMode.race:
        targetDuration = childSims.map((sim) => sim.duration).fold<num>(
            childSims.first.duration, min);
        break;
    }

    final primary = childSims.firstWhereOrNull((sim) => sim.pathRanges.isNotEmpty);

    if (primary == null) {
      return _createStationaryWait(
        command: commands.first,
        duration: targetDuration,
        pose: initialPose,
        speeds: initialSpeeds,
        highlight: false,
      );
    }

    _CommandSimulation adjusted = primary;
    if (adjusted.duration > targetDuration) {
      adjusted = _truncateSimulation(adjusted, targetDuration);
    } else if (adjusted.duration < targetDuration) {
      adjusted = _joinSimulations([
        adjusted,
        _createStationaryWait(
          command: commands.first,
          duration: targetDuration - adjusted.duration,
          pose: adjusted.endPose,
          speeds: adjusted.endSpeeds,
          highlight: false,
        ),
      ]);
    }

    return adjusted;
  }

  _CommandSimulation _simulateChoreoCommand(
    Command command, {
    required Map<PathCommand, ChoreoPath> pathMap,
    required Pose2d initialPose,
  }) {
    final beforeWait = _createStationaryWait(
      command: command,
      duration: command.beforeDelay,
      pose: initialPose,
      highlight: command.beforeDelay > 0,
      phase: CommandPreviewPhase.beforeDelay,
    );

    final bodyStartPose = beforeWait.endPose ?? initialPose;

    late final _CommandSimulation body;
    if (command is WaitCommand) {
      body = _createStationaryWait(
        command: command,
        duration: command.waitTime,
        pose: bodyStartPose,
      );
    } else if (command is PathCommand) {
      final path = pathMap[command];
      if (path == null || path.trajectory.states.isEmpty) {
        body = _CommandSimulation.empty(pose: bodyStartPose);
      } else {
        body = _simulationFromTrajectory(
          command: command,
          pathName: path.name,
          trajectory: path.trajectory,
          isChoreoPath: true,
        );
      }
    } else if (command is SequentialCommandGroup) {
      body = _simulateSequentialChoreoGroup(
        command.commands,
        pathMap: pathMap,
        initialPose: bodyStartPose,
      );
    } else if (command is ParallelCommandGroup) {
      body = _simulateConcurrentChoreoGroup(
        command.commands,
        pathMap: pathMap,
        initialPose: bodyStartPose,
        mode: _ConcurrentGroupMode.parallel,
      );
    } else if (command is DeadlineCommandGroup) {
      body = _simulateConcurrentChoreoGroup(
        command.commands,
        pathMap: pathMap,
        initialPose: bodyStartPose,
        mode: _ConcurrentGroupMode.deadline,
      );
    } else if (command is RaceCommandGroup) {
      body = _simulateConcurrentChoreoGroup(
        command.commands,
        pathMap: pathMap,
        initialPose: bodyStartPose,
        mode: _ConcurrentGroupMode.race,
      );
    } else {
      body = _CommandSimulation.empty(pose: bodyStartPose);
    }

    final afterWait = _createStationaryWait(
      command: command,
      duration: command.afterDelay,
      pose: body.endPose ?? bodyStartPose,
      highlight: command.afterDelay > 0,
      phase: CommandPreviewPhase.afterDelay,
    );

    return _joinSimulations([beforeWait, body, afterWait]);
  }

  _CommandSimulation _simulateSequentialChoreoGroup(
    List<Command> commands, {
    required Map<PathCommand, ChoreoPath> pathMap,
    required Pose2d initialPose,
  }) {
    final parts = <_CommandSimulation>[];
    Pose2d currentPose = initialPose;

    for (final child in commands) {
      final childSim = _simulateChoreoCommand(
        child,
        pathMap: pathMap,
        initialPose: currentPose,
      );
      parts.add(childSim);
      currentPose = childSim.endPose ?? currentPose;
    }

    return _joinSimulations(parts);
  }

  _CommandSimulation _simulateConcurrentChoreoGroup(
    List<Command> commands, {
    required Map<PathCommand, ChoreoPath> pathMap,
    required Pose2d initialPose,
    required _ConcurrentGroupMode mode,
  }) {
    if (commands.isEmpty) {
      return _CommandSimulation.empty(pose: initialPose);
    }

    final childSims = [
      for (final child in commands)
        _simulateChoreoCommand(
          child,
          pathMap: pathMap,
          initialPose: initialPose,
        ),
    ];

    num targetDuration;
    switch (mode) {
      case _ConcurrentGroupMode.parallel:
        targetDuration = childSims.map((sim) => sim.duration).fold<num>(0, max);
        break;
      case _ConcurrentGroupMode.deadline:
        targetDuration = childSims.first.duration;
        break;
      case _ConcurrentGroupMode.race:
        targetDuration = childSims.map((sim) => sim.duration).fold<num>(
            childSims.first.duration, min);
        break;
    }

    final primary = childSims.firstWhereOrNull((sim) => sim.pathRanges.isNotEmpty);

    if (primary == null) {
      return _createStationaryWait(
        command: commands.first,
        duration: targetDuration,
        pose: initialPose,
        highlight: false,
      );
    }

    _CommandSimulation adjusted = primary;
    if (adjusted.duration > targetDuration) {
      adjusted = _truncateSimulation(adjusted, targetDuration);
    } else if (adjusted.duration < targetDuration) {
      adjusted = _joinSimulations([
        adjusted,
        _createStationaryWait(
          command: commands.first,
          duration: targetDuration - adjusted.duration,
          pose: adjusted.endPose,
          highlight: false,
        ),
      ]);
    }

    return adjusted;
  }

  _CommandSimulation _simulationFromTrajectory({
    required Command command,
    required String pathName,
    required PathPlannerTrajectory trajectory,
    required bool isChoreoPath,
  }) {
    if (trajectory.states.isEmpty) {
      return _CommandSimulation.empty();
    }

    final duration = trajectory.states.last.timeSeconds;
    return _CommandSimulation(
      states: [for (final state in trajectory.states) state.copyWithTime(state.timeSeconds)],
      pathRanges: [
        TimedPathRange(
          pathName: pathName,
          startTime: 0,
          endTime: duration,
          isChoreoPath: isChoreoPath,
        ),
      ],
      commandHighlights: [
        _TimedCommandHighlight(
          command: command,
          startTime: 0,
          endTime: duration,
          phase: CommandPreviewPhase.running,
        ),
      ],
      duration: duration,
      endPose: trajectory.states.last.pose,
      endSpeeds: trajectory.states.last.fieldSpeeds,
    );
  }

  _CommandSimulation _joinSimulations(List<_CommandSimulation> parts) {
    final states = <TrajectoryState>[];
    final pathRanges = <TimedPathRange>[];
    final commandHighlights = <_TimedCommandHighlight>[];
    num offset = 0;
    Pose2d? endPose;
    ChassisSpeeds endSpeeds = const ChassisSpeeds();

    for (final part in parts) {
      if (part.states.isNotEmpty) {
        final normalizedStates = _normalizedStatesForJoin(
          previousState: states.isNotEmpty ? states.last : null,
          statesToNormalize: part.states,
        );

        if (states.isNotEmpty && normalizedStates.first.timeSeconds == 0) {
          _alignBoundaryState(
            previousState: states.last,
            nextState: normalizedStates.first,
          );
        }

        for (int i = 0; i < part.states.length; i++) {
          if (states.isNotEmpty && i == 0 && normalizedStates[i].timeSeconds == 0) {
            continue;
          }
          states.add(
            normalizedStates[i]
                .copyWithTime(normalizedStates[i].timeSeconds + offset),
          );
        }
      }

      pathRanges.addAll([
        for (final range in part.pathRanges)
          TimedPathRange(
            pathName: range.pathName,
            startTime: range.startTime + offset,
            endTime: range.endTime + offset,
            isChoreoPath: range.isChoreoPath,
          ),
      ]);
      commandHighlights.addAll([
        for (final highlight in part.commandHighlights)
          _TimedCommandHighlight(
            command: highlight.command,
            startTime: highlight.startTime + offset,
            endTime: highlight.endTime + offset,
            phase: highlight.phase,
          ),
      ]);

      offset += part.duration;
      endPose = part.endPose ?? endPose;
      endSpeeds = part.endSpeeds;
    }

    return _CommandSimulation(
      states: states,
      pathRanges: pathRanges,
      commandHighlights: commandHighlights,
      duration: offset,
      endPose: endPose,
      endSpeeds: endSpeeds,
    );
  }

  void _alignBoundaryState({
    required TrajectoryState previousState,
    required TrajectoryState nextState,
  }) {
    if (previousState.fieldSpeeds.linearVel == 0 && nextState.heading != previousState.heading) {
      previousState.heading = nextState.heading;
    }

    if (previousState.moduleStates.isEmpty ||
        previousState.moduleStates.length != nextState.moduleStates.length) {
      return;
    }

    for (int i = 0; i < previousState.moduleStates.length; i++) {
      previousState.moduleStates[i].angle = nextState.moduleStates[i].angle;
      previousState.moduleStates[i].fieldAngle = nextState.moduleStates[i].fieldAngle;
    }
  }

  List<TrajectoryState> _normalizedStatesForJoin({
    required TrajectoryState? previousState,
    required List<TrajectoryState> statesToNormalize,
  }) {
    if (previousState == null || previousState.moduleStates.isEmpty) {
      return statesToNormalize;
    }

    return [
      for (final state in statesToNormalize)
        state.moduleStates.isEmpty
            ? _copyStateWithStationaryModules(state, previousState)
            : state,
    ];
  }

  TrajectoryState _copyStateWithStationaryModules(
    TrajectoryState state,
    TrajectoryState template,
  ) {
    final copied = state.copyWithTime(state.timeSeconds);
    copied.moduleStates = [
      for (final moduleState in template.moduleStates)
        _cloneStationaryModuleState(moduleState),
    ];
    copied.heading = template.heading;
    copied.deltaPos = 0;
    copied.deltaRot = const Rotation2d();
    return copied;
  }

  SwerveModuleTrajState _cloneStationaryModuleState(
    SwerveModuleTrajState moduleState,
  ) {
    final cloned = SwerveModuleTrajState();
    cloned.speedMetersPerSecond = 0;
    cloned.angle = moduleState.angle;
    cloned.fieldAngle = moduleState.fieldAngle;
    cloned.fieldPos = moduleState.fieldPos;
    cloned.deltaPos = 0;
    return cloned;
  }

  _CommandSimulation _truncateSimulation(
    _CommandSimulation simulation,
    num duration,
  ) {
    if (duration >= simulation.duration) {
      return simulation;
    }
    if (duration <= 0) {
      return _CommandSimulation.empty(
        pose: simulation.states.isNotEmpty ? simulation.states.first.pose : simulation.endPose,
      );
    }

    final states = <TrajectoryState>[];
    for (final state in simulation.states) {
      if (state.timeSeconds < duration) {
        states.add(state.copyWithTime(state.timeSeconds));
      }
    }

    if (simulation.states.isNotEmpty) {
      final sampled = PathPlannerTrajectory.fromStates(simulation.states).sample(duration);
      if (states.isEmpty || states.last.timeSeconds != duration) {
        states.add(sampled.copyWithTime(duration));
      }
    }

    return _CommandSimulation(
      states: states,
      pathRanges: [
        for (final range in simulation.pathRanges)
          if (range.startTime < duration)
            TimedPathRange(
              pathName: range.pathName,
              startTime: range.startTime,
              endTime: min(range.endTime, duration),
              isChoreoPath: range.isChoreoPath,
            ),
      ],
      commandHighlights: [
        for (final highlight in simulation.commandHighlights)
          if (highlight.startTime < duration)
            _TimedCommandHighlight(
              command: highlight.command,
              startTime: highlight.startTime,
              endTime: min(highlight.endTime, duration),
              phase: highlight.phase,
            ),
      ],
      duration: duration,
      endPose: states.isNotEmpty ? states.last.pose : simulation.endPose,
      endSpeeds:
          states.isNotEmpty ? states.last.fieldSpeeds : simulation.endSpeeds,
    );
  }

  Map<PathCommand, PathPlannerPath> _buildPathCommandMap(
    List<Command> commands,
    List<PathPlannerPath> autoPaths,
  ) {
    final map = <PathCommand, PathPlannerPath>{};
    final orderedCommands = _collectPathCommands(commands);

    for (int i = 0; i < orderedCommands.length && i < autoPaths.length; i++) {
      map[orderedCommands[i]] = autoPaths[i];
    }

    return map;
  }

  Map<PathCommand, ChoreoPath> _buildChoreoPathCommandMap(
    List<Command> commands,
    List<ChoreoPath> autoPaths,
  ) {
    final map = <PathCommand, ChoreoPath>{};
    final orderedCommands = _collectPathCommands(commands);

    for (int i = 0; i < orderedCommands.length && i < autoPaths.length; i++) {
      map[orderedCommands[i]] = autoPaths[i];
    }

    return map;
  }

  List<PathCommand> _collectPathCommands(List<Command> commands) {
    final out = <PathCommand>[];

    for (final command in commands) {
      if (command is PathCommand) {
        out.add(command);
      } else if (command is CommandGroup) {
        out.addAll(_collectPathCommands(command.commands));
      }
    }

    return out;
  }

  void _handlePreviewTick() {
    final previewState = _previewStateForTime(_currentPreviewTime());
    if (_samePreviewState(previewState, _activeCommandPreviewState) || !mounted) {
      return;
    }

    setState(() {
      _activeCommandPreviewState = previewState;
    });
  }

  num _currentPreviewTime() {
    if (_previewController.duration == null) {
      return 0;
    }

    return _previewController.value *
        (_previewController.duration!.inMilliseconds / 1000.0);
  }

  CommandPreviewState? _previewStateForTime(num previewTimeSeconds) {
    for (final range in _timedCommandHighlights) {
      final inRange = previewTimeSeconds >= range.startTime &&
          (previewTimeSeconds < range.endTime ||
              (range == _timedCommandHighlights.last &&
                  previewTimeSeconds <= range.endTime));
      if (inRange) {
        return CommandPreviewState(
          command: range.command,
          phase: range.phase,
          remainingTime: max<num>(0, range.endTime - previewTimeSeconds),
        );
      }
    }
    return null;
  }

  bool _samePreviewState(
    CommandPreviewState? a,
    CommandPreviewState? b,
  ) {
    if (a == null || b == null) {
      return a == b;
    }

    return identical(a.command, b.command) &&
        a.phase == b.phase &&
        a.countdownTenths == b.countdownTenths;
  }

  bool _handleKeyEvent(KeyEvent event) {
    if (!_mirrorMode) {
      return false;
    }

    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.escape) {
      _cancelMirrorMode();
      return true;
    }

    return false;
  }

  void _startMirrorMode() {
    _viewerController.value = Matrix4.identity();

    setState(() {
      _mirrorModeCommandsCollapsedBefore = _commandsCollapsed;
      _commandsCollapsed = true;
      _mirrorMode = true;
      _mirrorAxisAngleRad = pi / 2.0;
    });
  }

  void _cancelMirrorMode() {
    setState(() {
      _mirrorMode = false;
      _commandsCollapsed = _mirrorModeCommandsCollapsedBefore;
    });
  }

  void _applyMirrorToAutoPaths() {
    if (widget.auto.choreoAuto || widget.autoPaths.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No PathPlanner paths to mirror in auto')),
      );
      _cancelMirrorMode();
      return;
    }

    final beforeAuto = widget.auto.duplicate(widget.auto.name);
    final center = _fieldCenterMeters;
    final renameMap = <String, String>{};
    final createdMirroredPaths = <PathPlannerPath>[];
    final existingNames = widget.allPaths.map((p) => p.name).toSet();

    for (final sourcePath in widget.autoPaths) {
      if (renameMap.containsKey(sourcePath.name)) {
        continue;
      }

      final mirroredName =
          _nextMirroredPathName(sourcePath.name, existingNames);
      existingNames.add(mirroredName);

      final mirrored = sourcePath.duplicate(mirroredName);
      mirrorPathInPlace(mirrored, center, _mirrorAxisAngleRad);
      mirrored.generateAndSavePath();

      createdMirroredPaths.add(mirrored.duplicate(mirrored.name));
      renameMap[sourcePath.name] = mirroredName;
    }

    setState(() {
      for (final mirrored in createdMirroredPaths) {
        final created = mirrored.duplicate(mirrored.name);
        widget.allPaths.add(created);

        if (!widget.allPathNames.contains(created.name)) {
          widget.allPathNames.add(created.name);
        }

        created.saveFile();
      }

      for (final entry in renameMap.entries) {
        widget.auto.updatePathName(entry.key, entry.value);
      }

      _rebuildAutoPathsFromCurrentAuto();
      _simulateAuto();
      _mirrorMode = false;
      _commandsCollapsed = _mirrorModeCommandsCollapsedBefore;
    });
    widget.onAutoChanged?.call();

    final createdPathNames = createdMirroredPaths.map((p) => p.name).toList();
    widget.undoStack.add(Change(
      beforeAuto,
      () {
        setState(() {
          _restoreAutoFromSnapshot(beforeAuto);
          _applyMirroredAutoRename(renameMap);
          for (final mirrored in createdMirroredPaths) {
            _upsertPathFromSnapshot(mirrored);
          }
          _rebuildAutoPathsFromCurrentAuto();
          _simulateAuto();
        });
        widget.onAutoChanged?.call();
      },
      (oldValue) {
        setState(() {
          _restoreAutoFromSnapshot(oldValue);
          for (final pathName in createdPathNames) {
            _removePathByName(pathName);
          }
          _rebuildAutoPathsFromCurrentAuto();
          _simulateAuto();
        });
        widget.onAutoChanged?.call();
      },
    ));
  }

  void _restoreAutoFromSnapshot(PathPlannerAuto snapshot) {
    final restored = PathPlannerAuto.fromJson(
      snapshot.toJson(),
      widget.auto.name,
      widget.auto.autoDir,
      widget.auto.fs,
    );

    widget.auto.sequence = restored.sequence;
    widget.auto.resetOdom = restored.resetOdom;
    widget.auto.choreoAuto = restored.choreoAuto;
    widget.auto.saveFile();
  }

  void _applyMirroredAutoRename(Map<String, String> renameMap) {
    for (final entry in renameMap.entries) {
      widget.auto.updatePathName(entry.key, entry.value);
    }
  }

  void _rebuildAutoPathsFromCurrentAuto() {
    widget.autoPaths
      ..clear()
      ..addAll(
        widget.auto.getAllPathNames().map(
            (name) => widget.allPaths.firstWhere((path) => path.name == name)),
      );
  }

  String _nextMirroredPathName(String baseName, Set<String> existingNames) {
    String candidate = '${baseName}-mirror';
    int copyNum = 2;
    while (existingNames.contains(candidate)) {
      candidate = '${baseName}-mirror$copyNum';
      copyNum++;
    }
    return candidate;
  }

  void _removePathByName(String pathName) {
    final existing =
        widget.allPaths.firstWhereOrNull((path) => path.name == pathName);
    if (existing == null) {
      return;
    }

    existing.deletePath();
    widget.allPaths.remove(existing);
    widget.allPathNames.remove(pathName);
  }

  void _upsertPathFromSnapshot(PathPlannerPath snapshot) {
    final existing =
        widget.allPaths.firstWhereOrNull((path) => path.name == snapshot.name);
    if (existing != null) {
      copyPathContents(existing, snapshot);
    } else {
      final created = snapshot.duplicate(snapshot.name);
      widget.allPaths.add(created);
      created.saveFile();
    }

    if (!widget.allPathNames.contains(snapshot.name)) {
      widget.allPathNames.add(snapshot.name);
    }
  }

  void _updateMirrorAxisFromLocal(Offset localPosition) {
    final point = Translation2d(
      _xPixelsToMeters(localPosition.dx),
      _yPixelsToMeters(localPosition.dy),
    );

    final center = _fieldCenterMeters;
    final dx = point.x - center.x;
    final dy = point.y - center.y;
    if ((dx * dx) + (dy * dy) < 1e-6) {
      return;
    }

    double angle = atan2(dy, dx);
    final shiftHeld = HardwareKeyboard.instance.logicalKeysPressed
            .contains(LogicalKeyboardKey.shiftLeft) ||
        HardwareKeyboard.instance.logicalKeysPressed
            .contains(LogicalKeyboardKey.shiftRight);
    if (!shiftHeld) {
      const step = pi / 12.0;
      angle = (angle / step).roundToDouble() * step;
    }

    if ((angle - _mirrorAxisAngleRad).abs() > 1e-6) {
      setState(() {
        _mirrorAxisAngleRad = angle;
      });
    }
  }

  Translation2d get _fieldCenterMeters {
    final size = widget.fieldImage.getFieldSizeMeters();
    return Translation2d(size.width / 2.0, size.height / 2.0);
  }

  String get _mirrorAxisDegLabel {
    final deg = (_mirrorAxisAngleRad * 180.0 / pi);
    final normalized = ((deg % 180) + 180) % 180;
    return normalized.toStringAsFixed(1);
  }

  Offset get _mirrorAxisStartPx {
    final center = _fieldCenterMeters;
    final size = widget.fieldImage.getFieldSizeMeters();
    final axis =
        Translation2d(cos(_mirrorAxisAngleRad), sin(_mirrorAxisAngleRad));
    final radius = max(size.width, size.height) * 2.0;
    final point = center - (axis * radius);
    return PathPainterUtil.pointToPixelOffset(
      point,
      PathPainter.scale,
      widget.fieldImage,
    );
  }

  Offset get _mirrorAxisEndPx {
    final center = _fieldCenterMeters;
    final size = widget.fieldImage.getFieldSizeMeters();
    final axis =
        Translation2d(cos(_mirrorAxisAngleRad), sin(_mirrorAxisAngleRad));
    final radius = max(size.width, size.height) * 2.0;
    final point = center + (axis * radius);
    return PathPainterUtil.pointToPixelOffset(
      point,
      PathPainter.scale,
      widget.fieldImage,
    );
  }

  double _xPixelsToMeters(double pixels) {
    return (((pixels - 48) / PathPainter.scale) /
            widget.fieldImage.pixelsPerMeter) -
        widget.fieldImage.marginMeters;
  }

  double _yPixelsToMeters(double pixels) {
    return ((widget.fieldImage.defaultSize.height -
                ((pixels - 48) / PathPainter.scale)) /
            widget.fieldImage.pixelsPerMeter) -
        widget.fieldImage.marginMeters;
  }

  Widget _buildResponsiveTreeScale(double maxWidth, Widget child) {
    const referenceWidth = 420.0;

    double scale = 1.0;
    if (maxWidth < referenceWidth) {
      scale = (maxWidth / referenceWidth).clamp(0.72, 1.0);
    }

    if (scale >= 0.999) {
      return child;
    }

    return ClipRect(
      child: Align(
        alignment: Alignment.topLeft,
        child: Transform.scale(
          scale: scale,
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: maxWidth / scale,
            child: child,
          ),
        ),
      ),
    );
  }

  void _showGenerationFailedError() {
    Log.warning('Failed to generate trajectory for auto: ${widget.auto.name}');

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Failed to generate trajectory for ${widget.auto.name}. This is likely due to bad control point placement. Please adjust your control points to avoid kinks in the path.',
          style:
              TextStyle(color: Theme.of(context).colorScheme.onErrorContainer),
        ),
        backgroundColor: Theme.of(context).colorScheme.errorContainer,
        behavior: SnackBarBehavior.floating,
        action: SnackBarAction(
          label: 'Dismiss',
          textColor: Theme.of(context).colorScheme.onErrorContainer,
          onPressed: () {
            ScaffoldMessenger.of(context).hideCurrentSnackBar();
          },
        ),
      ),
    );
  }

  void _applyLayoutPreset(String preset, {bool savePref = true}) {
    double treeWeight;
    switch (preset) {
      case 'compact':
        treeWeight = 0.35;
        break;
      case 'focused':
        treeWeight = 0.65;
        break;
      case 'balanced':
      default:
        treeWeight = 0.5;
        break;
    }

    _layoutPreset = preset;
    widget.prefs.setDouble(PrefsKeys.editorTreeWeight, treeWeight);
    _controller.areas = [
      Area(
        weight: _treeOnRight ? (1.0 - treeWeight) : treeWeight,
        minimalWeight: 0.08,
      ),
      Area(
        weight: _treeOnRight ? treeWeight : (1.0 - treeWeight),
        minimalWeight: 0.08,
      ),
    ];

    if (savePref) {
      widget.prefs.setString(PrefsKeys.editorLayoutPreset, preset);
    }
  }
}

class _TimedCommandHighlight {
  final Command command;
  final num startTime;
  final num endTime;
  final CommandPreviewPhase phase;

  const _TimedCommandHighlight({
    required this.command,
    required this.startTime,
    required this.endTime,
    required this.phase,
  });
}

class _CommandSimulation {
  final List<TrajectoryState> states;
  final List<TimedPathRange> pathRanges;
  final List<_TimedCommandHighlight> commandHighlights;
  final num duration;
  final Pose2d? endPose;
  final ChassisSpeeds endSpeeds;

  const _CommandSimulation({
    required this.states,
    required this.pathRanges,
    required this.commandHighlights,
    required this.duration,
    required this.endPose,
    required this.endSpeeds,
  });

  factory _CommandSimulation.empty({
    num duration = 0,
    Pose2d? pose,
    ChassisSpeeds speeds = const ChassisSpeeds(),
    List<_TimedCommandHighlight> commandHighlights = const [],
  }) {
    return _CommandSimulation(
      states: const [],
      pathRanges: const [],
      commandHighlights: commandHighlights,
      duration: duration,
      endPose: pose,
      endSpeeds: speeds,
    );
  }
}

enum _ConcurrentGroupMode {
  parallel,
  deadline,
  race,
}

class _MirrorAxisPainter extends CustomPainter {
  final Offset start;
  final Offset end;
  final Color color;

  _MirrorAxisPainter({
    required this.start,
    required this.end,
    required this.color,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final axisPaint = Paint()
      ..color = color
      ..strokeWidth = 2.5
      ..style = PaintingStyle.stroke;

    canvas.drawLine(start, end, axisPaint);

    final centerPaint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;
    final center = Offset((start.dx + end.dx) / 2.0, (start.dy + end.dy) / 2.0);
    canvas.drawCircle(center, 4.0, centerPaint);
  }

  @override
  bool shouldRepaint(covariant _MirrorAxisPainter oldDelegate) {
    return oldDelegate.start != start ||
        oldDelegate.end != end ||
        oldDelegate.color != color;
  }
}
