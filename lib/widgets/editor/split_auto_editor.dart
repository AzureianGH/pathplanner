import 'package:flutter/material.dart';
import 'package:multi_split_view/multi_split_view.dart';
import 'package:pathplanner/auto/pathplanner_auto.dart';
import 'package:pathplanner/path/choreo_path.dart';
import 'package:pathplanner/services/log.dart';
import 'package:pathplanner/trajectory/config.dart';
import 'package:pathplanner/trajectory/trajectory.dart';
import 'package:pathplanner/path/pathplanner_path.dart';
import 'package:pathplanner/util/prefs.dart';
import 'package:pathplanner/util/wpimath/geometry.dart';
import 'package:pathplanner/util/wpimath/kinematics.dart';
import 'package:pathplanner/widgets/dialogs/trajectory_render_dialog.dart';
import 'package:pathplanner/widgets/editor/path_painter.dart';
import 'package:pathplanner/widgets/editor/preview_seekbar.dart';
import 'package:pathplanner/widgets/editor/tree_widgets/auto_tree.dart';
import 'package:pathplanner/widgets/field_image.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:undo/undo.dart';

class SplitAutoEditor extends StatefulWidget {
  final SharedPreferences prefs;
  final PathPlannerAuto auto;
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
  bool _paused = false;

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

    WidgetsBinding.instance.addPostFrameCallback((_) => _simulateAuto());
  }

  @override
  void dispose() {
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
                ],
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
      ],
    );
  }

  // Marked as async so it can run from initState
  void _simulateAuto() async {
    if (widget.autoPaths.isEmpty && widget.autoChoreoPaths.isEmpty) {
      setState(() {
        _simTraj = null;
        _timedPathRanges = [];
      });

      _previewController.stop();
      _previewController.reset();

      return;
    }

    PathPlannerTrajectory? simPath;
    List<TimedPathRange> pathRanges = [];

    if (widget.auto.choreoAuto) {
      List<TrajectoryState> allStates = [];
      num timeOffset = 0.0;

      for (ChoreoPath p in widget.autoChoreoPaths) {
        if (p.trajectory.states.isNotEmpty) {
          pathRanges.add(TimedPathRange(
            pathName: p.name,
            startTime: timeOffset,
            endTime: timeOffset + p.trajectory.states.last.timeSeconds,
            isChoreoPath: true,
          ));
        }

        for (TrajectoryState s in p.trajectory.states) {
          allStates.add(s.copyWithTime(s.timeSeconds + timeOffset));
        }

        if (allStates.isNotEmpty) {
          timeOffset = allStates.last.timeSeconds;
        }
      }

      if (allStates.isNotEmpty) {
        simPath = PathPlannerTrajectory.fromStates(allStates);
      }
    } else {
      RobotConfig config = RobotConfig.fromPrefs(widget.prefs);
      List<TrajectoryState> allStates = [];
      num timeOffset = 0.0;

      try {
        Pose2d startPose = Pose2d(
            widget.autoPaths[0].pathPoints[0].position,
            widget.autoPaths[0].idealStartingState.rotation);
        ChassisSpeeds startSpeeds = const ChassisSpeeds();

        for (PathPlannerPath p in widget.autoPaths) {
          PathPlannerTrajectory pathTraj = PathPlannerTrajectory(
              path: p,
              startingSpeeds: startSpeeds,
              startingRotation: startPose.rotation,
              robotConfig: config);

          if (pathTraj.states.isNotEmpty) {
            pathRanges.add(TimedPathRange(
              pathName: p.name,
              startTime: timeOffset,
              endTime: timeOffset + pathTraj.states.last.timeSeconds,
            ));

            for (TrajectoryState s in pathTraj.states) {
              allStates.add(s.copyWithTime(s.timeSeconds + timeOffset));
            }

            timeOffset = allStates.last.timeSeconds;
            startPose = Pose2d(
              allStates.last.pose.translation,
              allStates.last.pose.rotation,
            );
            startSpeeds = allStates.last.fieldSpeeds;
          }
        }

        if (allStates.isNotEmpty) {
          simPath = PathPlannerTrajectory.fromStates(allStates);
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
      });
      _showGenerationFailedError();
    }
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
