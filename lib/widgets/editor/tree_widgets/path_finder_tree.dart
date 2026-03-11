import 'package:flutter/material.dart';
import 'package:pathplanner/path/optimization_boundary.dart';
import 'package:pathplanner/path/pathplanner_path.dart';
import 'package:pathplanner/util/path_finder.dart';
import 'package:pathplanner/util/prefs.dart';
import 'package:pathplanner/util/wpimath/geometry.dart';
import 'package:pathplanner/widgets/editor/tree_widgets/tree_card_node.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:undo/undo.dart';

class PathFinderTree extends StatefulWidget {
  final PathPlannerPath path;
  final VoidCallback? onPathChanged;
  final ValueChanged<PathPlannerPath?>? onUpdate;
  final ChangeStack undoStack;
  final SharedPreferences prefs;
  final Size fieldSizeMeters;
  final List<OptimizationBoundary> alwaysFieldObjects;

  const PathFinderTree({
    super.key,
    required this.path,
    this.onPathChanged,
    this.onUpdate,
    required this.undoStack,
    required this.prefs,
    required this.fieldSizeMeters,
    this.alwaysFieldObjects = const [],
  });

  @override
  State<PathFinderTree> createState() => _PathFinderTreeState();
}

class _PathFinderTreeState extends State<PathFinderTree> {
  PathFinderResult? _currentResult;
  bool _running = false;
  PathFinderAlgorithm _algorithm = PathFinderAlgorithm.aStar;
  bool _keepVelocity = false;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return TreeCardNode(
      title: const Text('PathFinder'),
      leading: const Icon(Icons.alt_route),
      initiallyExpanded: widget.path.pathFinderExpanded,
      onExpansionChanged: (value) {
        if (value != null) {
          widget.path.pathFinderExpanded = value;
        }
      },
      elevation: 1.0,
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: Text(
            'Finds a route from start to finish through navgrid obstacles.',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            const Icon(Icons.route),
            const SizedBox(width: 8),
            Text(
              'Algorithm',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const Spacer(),
            DropdownButton<PathFinderAlgorithm>(
              value: _algorithm,
              onChanged: _running
                  ? null
                  : (value) {
                      if (value == null) return;
                      setState(() {
                        _algorithm = value;
                        _currentResult = null;
                      });
                      widget.onUpdate?.call(null);
                    },
              items: const [
                DropdownMenuItem(
                  value: PathFinderAlgorithm.aStar,
                  child: Text('A*'),
                ),
                DropdownMenuItem(
                  value: PathFinderAlgorithm.dijkstra,
                  child: Text('Dijkstra'),
                ),
              ],
            ),
          ],
        ),
        const SizedBox(height: 6),
        Align(
          alignment: Alignment.centerLeft,
          child: Text(
            _algorithm == PathFinderAlgorithm.aStar
                ? 'Heuristic search for faster routing.'
                : 'Uniform-cost search for exhaustive routing.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
        const SizedBox(height: 12),
        CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          title: const Text('Keep Velocity'),
          subtitle: const Text(
            'Bias the route to preserve motion direction and curve around obstacles when possible.',
          ),
          value: _keepVelocity,
          onChanged: _running
              ? null
              : (value) {
                  setState(() {
                    _keepVelocity = value ?? false;
                    _currentResult = null;
                  });
                  widget.onUpdate?.call(null);
                },
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: Text(
                'Length: ${(_currentResult?.distanceMeters ?? 0.0).toStringAsFixed(2)} m',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
            Expanded(
              child: Text(
                'Visited: ${_currentResult?.visitedNodes ?? 0}',
                style: Theme.of(context).textTheme.bodyMedium,
                textAlign: TextAlign.end,
              ),
            ),
          ],
        ),
        if (_running) ...[
          const SizedBox(height: 8),
          const LinearProgressIndicator(),
        ],
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: ElevatedButton.icon(
                icon: const Icon(Icons.play_arrow),
                label: const Text('Find Path'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: colorScheme.primaryContainer,
                  foregroundColor: colorScheme.onPrimaryContainer,
                  elevation: 4.0,
                  minimumSize: const Size(0, 56),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
                onPressed: _running ? null : _runPathFinder,
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
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
                onPressed:
                    (_running || _currentResult == null) ? null : _discardPath,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: ElevatedButton.icon(
                icon: const Icon(Icons.check),
                label: const Text('Accept'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.green[700],
                  foregroundColor: colorScheme.onSecondaryContainer,
                  elevation: 4.0,
                  minimumSize: const Size(0, 56),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
                onPressed:
                    (_running || _currentResult == null) ? null : _acceptPath,
              ),
            ),
            const SizedBox(width: 8),
          ],
        ),
      ],
    );
  }

  void _runPathFinder() async {
    setState(() {
      _running = true;
      _currentResult = null;
    });
    widget.onUpdate?.call(null);

    PathFinderResult? result;
    try {
      final robotWidth =
          widget.prefs.getDouble(PrefsKeys.robotWidth) ?? Defaults.robotWidth;
      final robotLength =
          widget.prefs.getDouble(PrefsKeys.robotLength) ?? Defaults.robotLength;

      result = await PathFinder.findPath(
        sourcePath: widget.path,
        fieldSizeMeters: widget.fieldSizeMeters,
        additionalObstacles: widget.alwaysFieldObjects,
        algorithm: _algorithm,
        robotSize: Size(robotWidth, robotLength),
        keepVelocity: _keepVelocity,
      );
    } catch (_) {
      result = null;
    }

    if (!mounted) return;

    setState(() {
      _running = false;
      _currentResult = result;
    });

    if (_currentResult == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
              'No valid path found. Move start/goal or clear some obstacles and try again.'),
        ),
      );
    }

    widget.onUpdate?.call(_currentResult?.path);
  }

  void _discardPath() {
    setState(() {
      _currentResult = null;
    });
    widget.onUpdate?.call(null);
  }

  void _acceptPath() {
    if (_currentResult == null) return;

    final points =
        PathPlannerPath.cloneWaypoints(_currentResult!.path.waypoints);
    if (points.length < 2) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content:
              Text('Cannot accept this result: generated path is invalid.'),
        ),
      );
      return;
    }

    final candidatePath = widget.path.duplicate(widget.path.name)
      ..waypoints = PathPlannerPath.cloneWaypoints(points);
    try {
      candidatePath.generatePathPoints();
    } catch (_) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
              'Cannot accept this result: path generation failed. Try finding again.'),
        ),
      );
      return;
    }

    final oldReference = PathPlannerPath.cloneOptimizationReferencePath(
      widget.path.optimizationReferencePath,
    );
    final newReference = [
      for (final point in candidatePath.pathPositions)
        Translation2d(point.x, point.y),
    ];

    widget.undoStack.add(Change(
      PathPlannerPath.cloneWaypoints(widget.path.waypoints),
      () {
        widget.path.waypoints = points;
        widget.path.optimizationReferencePath =
            PathPlannerPath.cloneOptimizationReferencePath(newReference);

        setState(() {
          _currentResult = null;
        });
        widget.onUpdate?.call(null);
        widget.onPathChanged?.call();
      },
      (oldValue) {
        widget.path.waypoints = PathPlannerPath.cloneWaypoints(oldValue);
        widget.path.optimizationReferencePath =
            PathPlannerPath.cloneOptimizationReferencePath(oldReference);

        setState(() {
          _currentResult = null;
        });
        widget.onUpdate?.call(null);
        widget.onPathChanged?.call();
      },
    ));
  }
}
