import 'package:flutter/material.dart';
import 'package:pathplanner/path/optimization_boundary.dart';
import 'package:pathplanner/path/pathplanner_path.dart';
import 'package:pathplanner/trajectory/config.dart';
import 'package:pathplanner/util/path_optimizer.dart';
import 'package:pathplanner/util/prefs.dart';
import 'package:pathplanner/widgets/number_text_field.dart';
import 'package:pathplanner/widgets/editor/tree_widgets/tree_card_node.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:undo/undo.dart';

class PathOptimizationTree extends StatefulWidget {
  final PathPlannerPath path;
  final VoidCallback? onPathChanged;
  final ValueChanged<PathPlannerPath?>? onUpdate;
  final ChangeStack undoStack;
  final SharedPreferences prefs;
  final Size fieldSizeMeters;
  final List<OptimizationBoundary> alwaysFieldObjects;
  final VoidCallback? onStartBoundaryDraw;
  final VoidCallback? onStartReferencePathDraw;
  final VoidCallback? onClearReferencePath;

  const PathOptimizationTree({
    super.key,
    required this.path,
    this.onPathChanged,
    this.onUpdate,
    required this.undoStack,
    required this.prefs,
    required this.fieldSizeMeters,
    this.alwaysFieldObjects = const [],
    this.onStartBoundaryDraw,
    this.onStartReferencePathDraw,
    this.onClearReferencePath,
  });

  @override
  State<PathOptimizationTree> createState() => _PathOptimizationTreeState();
}

class _PathOptimizationTreeState extends State<PathOptimizationTree> {
  OptimizationResult? _currentResult;
  bool _running = false;

  late final Size _robotSize;

  @override
  void initState() {
    super.initState();

    var width =
        widget.prefs.getDouble(PrefsKeys.robotWidth) ?? Defaults.robotWidth;
    var length =
        widget.prefs.getDouble(PrefsKeys.robotLength) ?? Defaults.robotLength;
    _robotSize = Size(width, length);
  }

  @override
  Widget build(BuildContext context) {
    ColorScheme colorScheme = Theme.of(context).colorScheme;
    final hasFeasibleResult = (_currentResult?.runtime.isFinite ?? false) &&
        ((_currentResult?.runtime ?? -1) > 0) &&
        ((_currentResult?.score ?? double.infinity) < 1.0e9);
    final hasOptimizationResult = _currentResult != null;

    return TreeCardNode(
      title: const Text('Path Optimizer'),
      leading: const Icon(Icons.query_stats),
      initiallyExpanded: widget.path.pathOptimizationExpanded,
      onExpansionChanged: (value) {
        if (value != null) {
          widget.path.pathOptimizationExpanded = value;
        }
      },
      elevation: 1.0,
      children: [
        Center(
          child: Text(
            'Optimized Runtime: ${(_currentResult?.runtime ?? 0.0).toStringAsFixed(2)}s',
            style: Theme.of(context).textTheme.bodyLarge,
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            const Icon(Icons.timeline),
            const SizedBox(width: 8),
            Text(
              'Reference Path',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const Spacer(),
            FilledButton.icon(
              onPressed: _drawReferencePath,
              icon: const Icon(Icons.gesture),
              label: const Text('Draw Ref'),
            ),
            const SizedBox(width: 8),
            OutlinedButton.icon(
              onPressed: widget.path.optimizationReferencePath.isEmpty
                  ? null
                  : _clearReferencePath,
              icon: const Icon(Icons.delete_sweep),
              label: const Text('Clear'),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Align(
          alignment: Alignment.centerLeft,
          child: Text(
            widget.path.optimizationReferencePath.isEmpty
                ? 'No reference path set.'
                : 'Reference points: ${widget.path.optimizationReferencePath.length}',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            Expanded(
              child: Text(
                'Reference adherence: ${(widget.path.optimizationReferenceAdherence * 100).round()}%',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
            SizedBox(
              width: 110,
              child: NumberTextField(
                initialValue: widget.path.optimizationReferenceAdherence * 100,
                minValue: 0,
                maxValue: 100,
                precision: 0,
                label: 'Adherence %',
                onSubmitted: (value) {
                  if (value != null) {
                    setState(() {
                      widget.path.optimizationReferenceAdherence =
                          (value / 100.0).clamp(0.0, 1.0);
                      _currentResult = null;
                    });
                    widget.onPathChanged?.call();
                    widget.onUpdate?.call(null);
                  }
                },
              ),
            ),
          ],
        ),
        Slider(
          value: widget.path.optimizationReferenceAdherence,
          min: 0.0,
          max: 1.0,
          divisions: 100,
          label:
              '${(widget.path.optimizationReferenceAdherence * 100).round()}%',
          onChanged: (value) {
            setState(() {
              widget.path.optimizationReferenceAdherence = value;
              _currentResult = null;
            });
            widget.onPathChanged?.call();
            widget.onUpdate?.call(null);
          },
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            const Icon(Icons.crop_free),
            const SizedBox(width: 8),
            Text(
              'Boundary Boxes',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const Spacer(),
            FilledButton.icon(
              onPressed: _addBoundary,
              icon: const Icon(Icons.add_box_outlined),
              label: const Text('Draw'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (widget.path.optimizationBoundaries.isEmpty)
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              'No boundaries yet. Add a box to block optimizer travel.',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
        for (int i = 0; i < widget.path.optimizationBoundaries.length; i++)
          _buildBoundaryEditor(i),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: ElevatedButton.icon(
                icon: const Icon(Icons.play_arrow),
                label: const Text('Optimize'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: colorScheme.primaryContainer,
                  foregroundColor: colorScheme.onPrimaryContainer,
                  elevation: 4.0,
                  minimumSize: const Size(0, 56),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16)),
                ),
                onPressed: _running ? null : _runOptimization,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: ElevatedButton.icon(
                icon: Icon(
                  Icons.close,
                  color: colorScheme.onErrorContainer,
                ),
                label: const Text('Discard'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: colorScheme.errorContainer,
                  foregroundColor: colorScheme.onErrorContainer,
                  elevation: 4.0,
                  minimumSize: const Size(0, 56),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16)),
                ),
                onPressed: (_running || _currentResult == null)
                    ? null
                    : _discardOptimization,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: ElevatedButton.icon(
                icon: Icon(
                  Icons.check,
                  color: hasFeasibleResult
                      ? colorScheme.onSecondaryContainer
                      : colorScheme.onTertiaryContainer,
                ),
                label: const Text('Accept'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: hasFeasibleResult
                      ? Colors.green[700]
                      : colorScheme.tertiaryContainer,
                  foregroundColor: hasFeasibleResult
                      ? colorScheme.onSecondaryContainer
                      : colorScheme.onTertiaryContainer,
                  elevation: 4.0,
                  minimumSize: const Size(0, 56),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16)),
                ),
                onPressed: (_running || !hasOptimizationResult)
                    ? null
                    : _acceptOptimization,
              ),
            ),
            const SizedBox(width: 8),
          ],
        ),
        const SizedBox(height: 16),
        Padding(
          padding: const EdgeInsets.only(right: 8.0),
          child: LinearProgressIndicator(
            value:
                (_currentResult?.generation ?? 0) / PathOptimizer.generations,
          ),
        ),
      ],
    );
  }

  void _runOptimization() async {
    setState(() {
      _running = true;
      _currentResult = null;
    });

    RobotConfig config = RobotConfig.fromPrefs(widget.prefs);
    final optimizationPath = widget.path.duplicate(widget.path.name)
      ..optimizationBoundaries = [
        ...PathPlannerPath.cloneOptimizationBoundaries(
            widget.path.optimizationBoundaries),
        ...PathPlannerPath.cloneOptimizationBoundaries(
            widget.alwaysFieldObjects),
      ];

    widget.onUpdate?.call(_currentResult?.path);

    final result = await PathOptimizer.optimizePath(
      optimizationPath,
      config,
      widget.fieldSizeMeters,
      _robotSize,
      onUpdate: (result) {
        if (mounted) {
          setState(() {
            _currentResult = result;
            widget.onUpdate?.call(_currentResult?.path);
          });
        }
      },
    );

    if (mounted) {
      setState(() {
        _running = false;
        _currentResult = result;
      });

      widget.onUpdate?.call(_currentResult?.path);
    }
  }

  void _discardOptimization() {
    setState(() {
      _currentResult = null;
    });
    widget.onUpdate?.call(_currentResult?.path);
  }

  void _acceptOptimization() async {
    if (_currentResult == null) return;

    final hasFeasibleResult = _currentResult!.runtime.isFinite &&
        _currentResult!.runtime > 0 &&
        _currentResult!.score < 1.0e9;

    if (!hasFeasibleResult) {
      final shouldContinue = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Invalid Optimization Result'),
          content: const Text(
              'The optimized path is invalid and may not be drivable. Do you still want to accept it?'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Accept Anyway'),
            ),
          ],
        ),
      );

      if (shouldContinue != true) {
        return;
      }
    }

    final points =
        PathPlannerPath.cloneWaypoints(_currentResult!.path.waypoints);

    widget.undoStack.add(Change(
      PathPlannerPath.cloneWaypoints(widget.path.waypoints),
      () {
        setState(() {
          _currentResult = null;
        });
        widget.onUpdate?.call(_currentResult?.path);

        widget.path.waypoints = points;
        widget.onPathChanged?.call();
      },
      (oldValue) {
        setState(() {
          _currentResult = null;
        });
        widget.onUpdate?.call(_currentResult?.path);

        widget.path.waypoints = PathPlannerPath.cloneWaypoints(oldValue);
        widget.onPathChanged?.call();
      },
    ));
  }

  Widget _buildBoundaryEditor(int idx) {
    final boundary = widget.path.optimizationBoundaries[idx];

    return Card(
      elevation: 0,
      margin: const EdgeInsets.symmetric(vertical: 6),
      child: Padding(
        padding: const EdgeInsets.all(10.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text('Box ${idx + 1}'),
                const Spacer(),
                IconButton(
                  tooltip: 'Delete Boundary',
                  onPressed: () => _deleteBoundary(idx),
                  icon: const Icon(Icons.delete_forever),
                ),
              ],
            ),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                SizedBox(
                  width: 140,
                  child: NumberTextField(
                    initialValue: boundary.x,
                    label: 'X (m)',
                    onSubmitted: (value) {
                      if (value != null) {
                        boundary.x = value.toDouble();
                        _notifyBoundaryChanged();
                      }
                    },
                  ),
                ),
                SizedBox(
                  width: 140,
                  child: NumberTextField(
                    initialValue: boundary.y,
                    label: 'Y (m)',
                    onSubmitted: (value) {
                      if (value != null) {
                        boundary.y = value.toDouble();
                        _notifyBoundaryChanged();
                      }
                    },
                  ),
                ),
                SizedBox(
                  width: 140,
                  child: NumberTextField(
                    initialValue: boundary.width,
                    minValue: 0.05,
                    label: 'Width (m)',
                    onSubmitted: (value) {
                      if (value != null) {
                        boundary.width = value.toDouble().abs().clamp(0.05, 54);
                        _notifyBoundaryChanged();
                      }
                    },
                  ),
                ),
                SizedBox(
                  width: 140,
                  child: NumberTextField(
                    initialValue: boundary.height,
                    minValue: 0.05,
                    label: 'Height (m)',
                    onSubmitted: (value) {
                      if (value != null) {
                        boundary.height =
                            value.toDouble().abs().clamp(0.05, 27);
                        _notifyBoundaryChanged();
                      }
                    },
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'Tolerance (${boundary.tolerance.toStringAsFixed(2)}m)',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            Row(
              children: [
                Expanded(
                  child: Slider(
                    value: boundary.tolerance,
                    min: 0.0,
                    max: 2.0,
                    divisions: 200,
                    label: boundary.tolerance.toStringAsFixed(2),
                    onChanged: (value) {
                      setState(() {
                        boundary.tolerance = value;
                        _currentResult = null;
                      });
                      widget.onPathChanged?.call();
                      widget.onUpdate?.call(null);
                    },
                  ),
                ),
                SizedBox(
                  width: 110,
                  child: NumberTextField(
                    initialValue: boundary.tolerance,
                    minValue: 0.0,
                    maxValue: 2.0,
                    precision: 2,
                    label: 'Tolerance',
                    onSubmitted: (value) {
                      if (value != null) {
                        boundary.tolerance = value.toDouble().clamp(0.0, 2.0);
                        _notifyBoundaryChanged();
                      }
                    },
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  void _addBoundary() {
    if (widget.onStartBoundaryDraw != null) {
      widget.onStartBoundaryDraw!.call();
      return;
    }

    final newBoundary = OptimizationBoundary(
      x: widget.fieldSizeMeters.width * 0.35,
      y: widget.fieldSizeMeters.height * 0.35,
      width: 1.0,
      height: 1.0,
      tolerance: 0.0,
    );

    setState(() {
      widget.path.optimizationBoundaries.add(newBoundary);
      _currentResult = null;
    });

    widget.onPathChanged?.call();
    widget.onUpdate?.call(null);
  }

  void _deleteBoundary(int idx) {
    setState(() {
      widget.path.optimizationBoundaries.removeAt(idx);
      _currentResult = null;
    });

    widget.onPathChanged?.call();
    widget.onUpdate?.call(null);
  }

  void _notifyBoundaryChanged() {
    setState(() {
      _currentResult = null;
    });
    widget.onPathChanged?.call();
    widget.onUpdate?.call(null);
  }

  void _drawReferencePath() {
    widget.onStartReferencePathDraw?.call();
  }

  void _clearReferencePath() {
    setState(() {
      widget.path.optimizationReferencePath.clear();
      _currentResult = null;
    });
    widget.onPathChanged?.call();
    widget.onClearReferencePath?.call();
    widget.onUpdate?.call(null);
  }
}
