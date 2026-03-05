import 'package:flutter/material.dart';
import 'package:multi_split_view/multi_split_view.dart';
import 'package:pathplanner/path/choreo_path.dart';
import 'package:pathplanner/util/prefs.dart';
import 'package:pathplanner/widgets/dialogs/trajectory_render_dialog.dart';
import 'package:pathplanner/widgets/editor/path_painter.dart';
import 'package:pathplanner/widgets/editor/preview_seekbar.dart';
import 'package:pathplanner/widgets/editor/tree_widgets/choreo_path_tree.dart';
import 'package:pathplanner/widgets/field_image.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:undo/undo.dart';

class SplitChoreoPathEditor extends StatefulWidget {
  final SharedPreferences prefs;
  final ChoreoPath path;
  final FieldImage fieldImage;
  final ChangeStack undoStack;
  final bool simulate;

  const SplitChoreoPathEditor({
    required this.prefs,
    required this.path,
    required this.fieldImage,
    required this.undoStack,
    this.simulate = false,
    super.key,
  });

  @override
  State<SplitChoreoPathEditor> createState() => _SplitChoreoPathEditorState();
}

class _SplitChoreoPathEditorState extends State<SplitChoreoPathEditor>
    with SingleTickerProviderStateMixin {
  final MultiSplitViewController _controller = MultiSplitViewController();
  late bool _treeOnRight;
  late String _layoutPreset;
  bool _treeCollapsed = false;
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

    _simulatePath();
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
            child: Padding(
              padding: const EdgeInsets.all(48),
              child: Stack(
                children: [
                  widget.fieldImage.getWidget(),
                  Positioned.fill(
                    child: CustomPaint(
                      painter: PathPainter(
                        colorScheme: colorScheme,
                        paths: [],
                        choreoPaths: [widget.path],
                        fieldImage: widget.fieldImage,
                        simulatedPath: widget.path.trajectory,
                        animation: _previewController.view,
                        prefs: widget.prefs,
                      ),
                    ),
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
              if (_treeCollapsed) return;

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
                  totalPathTime: widget.path.trajectory.states.last.timeSeconds,
                ),
              if (!_treeCollapsed)
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
                          ChoreoPathTree(
                            path: widget.path,
                            pathRuntime: widget.path.trajectory.states.isNotEmpty
                                ? widget.path.trajectory.states.last.timeSeconds
                                : null,
                            undoStack: widget.undoStack,
                            onSideSwapped: () => setState(() {
                              _treeOnRight = !_treeOnRight;
                              widget.prefs
                                  .setBool(PrefsKeys.treeOnRight, _treeOnRight);
                              _controller.areas =
                                  _controller.areas.reversed.toList();
                            }),
                            onCollapseRequested: () {
                              setState(() {
                                _treeCollapsed = true;
                              });
                            },
                            onRenderPath: () {
                              showDialog(
                                  context: context,
                                  builder: (context) {
                                    return TrajectoryRenderDialog(
                                      fieldImage: widget.fieldImage,
                                      prefs: widget.prefs,
                                      trajectory: widget.path.trajectory,
                                    );
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
                  totalPathTime: widget.path.trajectory.states.isNotEmpty
                      ? widget.path.trajectory.states.last.timeSeconds
                      : 1.0,
                ),
            ],
          ),
        ),
        if (_treeCollapsed)
          Positioned(
            top: 12,
            right: _treeOnRight ? 12 : null,
            left: _treeOnRight ? null : 12,
            child: FilledButton.icon(
              onPressed: () {
                setState(() {
                  _treeCollapsed = false;
                });
              },
              icon: const Icon(Icons.keyboard_double_arrow_left),
              label: const Text('Menu'),
            ),
          ),
      ],
    );
  }

  // marked as async so it can be called from initState
  void _simulatePath() async {
    if (widget.simulate) {
      if (!_paused) {
        _previewController.stop();
        _previewController.reset();
        _previewController.duration = Duration(
            milliseconds:
                (widget.path.trajectory.states.last.timeSeconds * 1000)
                    .toInt());
        _previewController.repeat();
      }
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
