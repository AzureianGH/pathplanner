import 'dart:collection';
import 'dart:convert';
import 'dart:math';
import 'dart:ui';

import 'package:collection/collection.dart';
import 'package:path/path.dart' as p;
import 'package:pathplanner/path/optimization_boundary.dart';
import 'package:pathplanner/path/pathplanner_path.dart';
import 'package:pathplanner/path/waypoint.dart';
import 'package:pathplanner/pathfinding/nav_grid.dart';
import 'package:pathplanner/util/wpimath/geometry.dart';

enum PathFinderAlgorithm { aStar, dijkstra }

class PathFinderResult {
  final PathPlannerPath path;
  final num distanceMeters;
  final int visitedNodes;

  const PathFinderResult({
    required this.path,
    required this.distanceMeters,
    required this.visitedNodes,
  });
}

class PathFinder {
  static const double _defaultNodeSizeMeters = 0.2;
  static const double _keepVelocityTurnPenaltyScale = 2.4;
  static const double _keepVelocityHeadingPenaltyScale = 1.6;

  static Future<PathFinderResult?> findPath({
    required PathPlannerPath sourcePath,
    required Size fieldSizeMeters,
    required List<OptimizationBoundary> additionalObstacles,
    PathFinderAlgorithm algorithm = PathFinderAlgorithm.aStar,
    Size robotSize = const Size(0.9, 0.9),
    bool keepVelocity = false,
  }) async {
    if (sourcePath.waypoints.length < 2) {
      return null;
    }

    final startPos = sourcePath.waypoints.first.anchor;
    final goalPos = sourcePath.waypoints.last.anchor;
    final boundaries = [
      ...sourcePath.optimizationBoundaries,
      ...additionalObstacles,
    ];
    final robotRadius = _robotRadiusForSize(robotSize);

    final navGrid = _loadNavGrid(sourcePath, fieldSizeMeters);
    final primaryResult = _findPathOnGrid(
      sourcePath: sourcePath,
      navGrid: navGrid,
      fieldSizeMeters: fieldSizeMeters,
      boundaries: boundaries,
      robotRadius: robotRadius,
      startPos: startPos,
      goalPos: goalPos,
      algorithm: algorithm,
      keepVelocity: keepVelocity,
    );
    if (primaryResult != null) {
      return primaryResult;
    }

    final fallbackGrid = NavGrid.blankGrid(
      nodeSizeMeters: navGrid.nodeSizeMeters,
      fieldSize: fieldSizeMeters,
    );
    return _findPathOnGrid(
      sourcePath: sourcePath,
      navGrid: fallbackGrid,
      fieldSizeMeters: fieldSizeMeters,
      boundaries: boundaries,
      robotRadius: robotRadius,
      startPos: startPos,
      goalPos: goalPos,
      algorithm: algorithm,
      keepVelocity: keepVelocity,
    );
  }

  static PathFinderResult? _findPathOnGrid({
    required PathPlannerPath sourcePath,
    required NavGrid navGrid,
    required Size fieldSizeMeters,
    required List<OptimizationBoundary> boundaries,
    required double robotRadius,
    required Translation2d startPos,
    required Translation2d goalPos,
    required PathFinderAlgorithm algorithm,
    required bool keepVelocity,
  }) {
    final blocked = _buildBlockedGrid(
      navGrid,
      fieldSizeMeters,
      boundaries,
      robotRadius,
    );

    final startCell = _findClosestFreeCell(
      _toCell(startPos, navGrid),
      blocked,
    );
    final goalCell = _findClosestFreeCell(
      _toCell(goalPos, navGrid),
      blocked,
    );

    if (startCell == null || goalCell == null) {
      return null;
    }

    final solveResult = _solveGrid(
      startCell,
      goalCell,
      blocked,
      algorithm,
      keepVelocity: keepVelocity,
      startHeading: keepVelocity ? sourcePath.waypoints.first.heading : null,
      goalHeading: keepVelocity ? sourcePath.waypoints.last.heading : null,
    );
    if (solveResult == null || solveResult.pathCells.isEmpty) {
      return null;
    }

    final rawPoints = <Translation2d>[startPos];
    for (int i = 1; i < solveResult.pathCells.length - 1; i++) {
      rawPoints.add(_cellCenter(solveResult.pathCells[i], navGrid));
    }
    rawPoints.add(goalPos);

    final simplified = _simplifyPath(
      rawPoints,
      blocked,
      navGrid,
      keepVelocity: keepVelocity,
    );
    if (simplified.length < 2) {
      return null;
    }

    final smoothed = _smoothPath(
      simplified,
      blocked,
      navGrid,
      iterations: keepVelocity ? 6 : 2,
    );
    final reducedPoints = _reducePointCount(
      smoothed,
      keepVelocity: keepVelocity,
    );
    if (reducedPoints.length < 2) {
      return null;
    }

    final guidedPoints = _minimizeBezierAnchors(
      reducedPoints,
      sourcePath,
      navGrid,
      blocked,
      keepVelocity: keepVelocity,
    );

    final waypoints = _waypointsFromPoints(
      guidedPoints,
      sourcePath,
      navGrid,
      blocked,
      keepVelocity: keepVelocity,
    );
    if (waypoints.length < 2) {
      return null;
    }

    final generatedPath = sourcePath.duplicate(sourcePath.name)
      ..waypoints = waypoints
      ..generatePathPoints();

    return PathFinderResult(
      path: generatedPath,
      distanceMeters: _pathDistance(guidedPoints),
      visitedNodes: solveResult.visitedNodes,
    );
  }

  static NavGrid _loadNavGrid(
      PathPlannerPath sourcePath, Size fieldSizeMeters) {
    try {
      final navGridPath = p.join(p.dirname(sourcePath.pathDir), 'navgrid.json');
      final file = sourcePath.fs.file(navGridPath);
      if (file.existsSync()) {
        final decoded = jsonDecode(file.readAsStringSync());
        if (decoded is Map<String, dynamic>) {
          return NavGrid.fromJson(decoded);
        }
      }
    } catch (_) {}

    return NavGrid.blankGrid(
      nodeSizeMeters: _defaultNodeSizeMeters,
      fieldSize: fieldSizeMeters,
    );
  }

  static List<List<bool>> _buildBlockedGrid(
    NavGrid navGrid,
    Size fieldSizeMeters,
    List<OptimizationBoundary> boundaries,
    double robotRadius,
  ) {
    final blocked = [
      for (final row in navGrid.grid) [...row],
    ];

    for (int row = 0; row < blocked.length; row++) {
      for (int col = 0; col < blocked[row].length; col++) {
        final center = Translation2d(
          (col + 0.5) * navGrid.nodeSizeMeters,
          (row + 0.5) * navGrid.nodeSizeMeters,
        );

        if (center.x < robotRadius ||
            center.y < robotRadius ||
            center.x > fieldSizeMeters.width - robotRadius ||
            center.y > fieldSizeMeters.height - robotRadius) {
          blocked[row][col] = true;
          continue;
        }

        for (final boundary in boundaries) {
          if (boundary.containsPoint(
            center,
            inflate: boundary.tolerance + robotRadius,
          )) {
            blocked[row][col] = true;
            break;
          }
        }
      }
    }

    return blocked;
  }

  static _GridCell _toCell(Translation2d point, NavGrid navGrid) {
    final row = (point.y / navGrid.nodeSizeMeters)
        .floor()
        .clamp(0, navGrid.grid.length - 1);
    final col = (point.x / navGrid.nodeSizeMeters)
        .floor()
        .clamp(0, navGrid.grid[0].length - 1);
    return _GridCell(row, col);
  }

  static _GridCell? _findClosestFreeCell(
      _GridCell cell, List<List<bool>> blocked) {
    final rows = blocked.length;
    final cols = blocked[0].length;

    if (!_isBlocked(cell, blocked)) {
      return cell;
    }

    final visited = <int>{};
    final queue = Queue<_GridCell>()..add(cell);
    visited.add(cell.key(cols));

    while (queue.isNotEmpty) {
      final current = queue.removeFirst();
      if (!_isBlocked(current, blocked)) {
        return current;
      }

      for (final neighbor in _neighbors4(current, rows, cols)) {
        final key = neighbor.key(cols);
        if (visited.add(key)) {
          queue.add(neighbor);
        }
      }
    }

    return null;
  }

  static _GridSolveResult? _solveGrid(
    _GridCell start,
    _GridCell goal,
    List<List<bool>> blocked,
    PathFinderAlgorithm algorithm,
    {
    required bool keepVelocity,
    Rotation2d? startHeading,
    Rotation2d? goalHeading,
  }
  ) {
    final rows = blocked.length;
    final cols = blocked[0].length;

    final gScore = <int, double>{};
    final cameFrom = <int, int>{};
    final open = PriorityQueue<_QueueEntry>((a, b) => a.f.compareTo(b.f));
    final closed = <int>{};

    final startKey = start.key(cols);
    final goalKey = goal.key(cols);

    gScore[startKey] = 0.0;
    open.add(_QueueEntry(startKey, _heuristic(start, goal, algorithm)));

    int visitedNodes = 0;

    while (open.isNotEmpty) {
      final currentEntry = open.removeFirst();
      final currentKey = currentEntry.key;
      if (closed.contains(currentKey)) {
        continue;
      }
      closed.add(currentKey);
      visitedNodes++;

      if (currentKey == goalKey) {
        final pathKeys = <int>[goalKey];
        var walk = goalKey;
        while (cameFrom.containsKey(walk)) {
          walk = cameFrom[walk]!;
          pathKeys.add(walk);
        }
        final cells = pathKeys.reversed
            .map((key) => _GridCell.fromKey(key, cols))
            .toList(growable: false);
        return _GridSolveResult(cells, visitedNodes);
      }

      final current = _GridCell.fromKey(currentKey, cols);
      final currentG = gScore[currentKey] ?? double.infinity;
      final parentKey = cameFrom[currentKey];
      final parentCell =
          parentKey != null ? _GridCell.fromKey(parentKey, cols) : null;

      for (final edge in _neighbors8(current, rows, cols, blocked)) {
        final neighborKey = edge.cell.key(cols);
        if (closed.contains(neighborKey)) {
          continue;
        }

        final turnPenalty = _turnPenalty(
          parentCell,
          current,
          edge.cell,
          keepVelocity: keepVelocity,
        );
        final headingPenalty = _headingPenalty(
          parent: parentCell,
          current: current,
          neighbor: edge.cell,
          start: start,
          goal: goal,
          startHeading: startHeading,
          goalHeading: goalHeading,
          keepVelocity: keepVelocity,
        );
        final tentativeG = currentG + edge.cost + turnPenalty + headingPenalty;
        final neighborG = gScore[neighborKey] ?? double.infinity;
        if (tentativeG >= neighborG) {
          continue;
        }

        cameFrom[neighborKey] = currentKey;
        gScore[neighborKey] = tentativeG;
        final neighborF = tentativeG + _heuristic(edge.cell, goal, algorithm);
        open.add(_QueueEntry(neighborKey, neighborF));
      }
    }

    return null;
  }

  static double _heuristic(
      _GridCell a, _GridCell b, PathFinderAlgorithm algorithm) {
    if (algorithm == PathFinderAlgorithm.dijkstra) {
      return 0.0;
    }

    final dx = (a.col - b.col).abs().toDouble();
    final dy = (a.row - b.row).abs().toDouble();
    return sqrt(dx * dx + dy * dy);
  }

  static List<_GridEdge> _neighbors8(
    _GridCell cell,
    int rows,
    int cols,
    List<List<bool>> blocked,
  ) {
    final edges = <_GridEdge>[];

    for (int dr = -1; dr <= 1; dr++) {
      for (int dc = -1; dc <= 1; dc++) {
        if (dr == 0 && dc == 0) continue;

        final nr = cell.row + dr;
        final nc = cell.col + dc;
        if (nr < 0 || nc < 0 || nr >= rows || nc >= cols) {
          continue;
        }

        final neighbor = _GridCell(nr, nc);
        if (_isBlocked(neighbor, blocked)) {
          continue;
        }

        if (dr != 0 && dc != 0) {
          final sideA = _GridCell(cell.row + dr, cell.col);
          final sideB = _GridCell(cell.row, cell.col + dc);
          if (_isBlocked(sideA, blocked) || _isBlocked(sideB, blocked)) {
            continue;
          }
        }

        edges.add(_GridEdge(neighbor, (dr != 0 && dc != 0) ? sqrt2 : 1.0));
      }
    }

    return edges;
  }

  static Iterable<_GridCell> _neighbors4(_GridCell cell, int rows, int cols) {
    final deltas = [
      const _GridCell(-1, 0),
      const _GridCell(1, 0),
      const _GridCell(0, -1),
      const _GridCell(0, 1),
    ];

    return deltas
        .map((d) => _GridCell(cell.row + d.row, cell.col + d.col))
        .where((c) => c.row >= 0 && c.col >= 0 && c.row < rows && c.col < cols);
  }

  static bool _isBlocked(_GridCell cell, List<List<bool>> blocked) {
    return blocked[cell.row][cell.col];
  }

  static Translation2d _cellCenter(_GridCell cell, NavGrid navGrid) {
    return Translation2d(
      (cell.col + 0.5) * navGrid.nodeSizeMeters,
      (cell.row + 0.5) * navGrid.nodeSizeMeters,
    );
  }

  static List<Translation2d> _simplifyPath(
    List<Translation2d> points,
    List<List<bool>> blocked,
    NavGrid navGrid,
    {
    required bool keepVelocity,
  }
  ) {
    if (points.length <= 2) {
      return points;
    }

    final simplified = <Translation2d>[points.first];
    int anchorIdx = 0;

    while (anchorIdx < points.length - 1) {
      int targetIdx = keepVelocity
          ? min(points.length - 1, anchorIdx + 5)
          : points.length - 1;
      while (targetIdx > anchorIdx + 1 &&
          _isLineBlocked(
              points[anchorIdx], points[targetIdx], blocked, navGrid)) {
        targetIdx--;
      }

      if (keepVelocity) {
        final maxJumpMeters = navGrid.nodeSizeMeters * 3.0;
        while (targetIdx > anchorIdx + 1 &&
            points[anchorIdx].getDistance(points[targetIdx]) > maxJumpMeters) {
          targetIdx--;
        }
      }

      simplified.add(points[targetIdx]);
      anchorIdx = targetIdx;
    }

    return simplified;
  }

  static List<Translation2d> _smoothPath(
    List<Translation2d> points,
    List<List<bool>> blocked,
    NavGrid navGrid,
    {
    required int iterations,
  }
  ) {
    if (points.length < 3) {
      return points;
    }

    var current = <Translation2d>[...points];

    for (int iter = 0; iter < iterations; iter++) {
      if (current.length < 3) {
        break;
      }

      final next = <Translation2d>[current.first];
      for (int i = 0; i < current.length - 1; i++) {
        final a = current[i];
        final b = current[i + 1];

        final q = Translation2d(
          (0.75 * a.x) + (0.25 * b.x),
          (0.75 * a.y) + (0.25 * b.y),
        );
        final r = Translation2d(
          (0.25 * a.x) + (0.75 * b.x),
          (0.25 * a.y) + (0.75 * b.y),
        );

        next.add(q);
        next.add(r);
      }
      next.add(current.last);

      bool valid = true;
      for (int i = 1; i < next.length; i++) {
        if (_isLineBlocked(next[i - 1], next[i], blocked, navGrid)) {
          valid = false;
          break;
        }
      }

      if (!valid) {
        break;
      }

      current = next;
    }

    return current;
  }

  static List<Translation2d> _reducePointCount(
    List<Translation2d> points, {
    required bool keepVelocity,
  }) {
    if (points.length <= 2) {
      return points;
    }

    final maxPoints = keepVelocity ? 28 : 20;
    if (points.length <= maxPoints) {
      return points;
    }

    final totalDistance = _pathDistance(points).toDouble();
    if (totalDistance <= 1.0e-9) {
      return [points.first, points.last];
    }

    final targetSpacing = totalDistance / (maxPoints - 1);
    final reduced = <Translation2d>[points.first];
    double accumulated = 0.0;
    double nextSampleDistance = targetSpacing;

    for (int i = 1; i < points.length; i++) {
      final segmentDistance = points[i - 1].getDistance(points[i]).toDouble();
      accumulated += segmentDistance;

      if (accumulated + 1.0e-9 >= nextSampleDistance) {
        reduced.add(points[i]);
        nextSampleDistance += targetSpacing;
      }
    }

    if (reduced.last != points.last) {
      reduced.add(points.last);
    }

    return reduced;
  }

  static bool _isLineBlocked(
    Translation2d start,
    Translation2d end,
    List<List<bool>> blocked,
    NavGrid navGrid,
  ) {
    final distance = start.getDistance(end);
    if (distance <= 1.0e-9) {
      return false;
    }

    final rows = blocked.length;
    final cols = blocked[0].length;
    final steps = max(2, (distance / (navGrid.nodeSizeMeters * 0.35)).ceil());

    for (int i = 0; i <= steps; i++) {
      final t = i / steps;
      final x = start.x + ((end.x - start.x) * t);
      final y = start.y + ((end.y - start.y) * t);
      final row = (y / navGrid.nodeSizeMeters).floor().clamp(0, rows - 1);
      final col = (x / navGrid.nodeSizeMeters).floor().clamp(0, cols - 1);
      if (blocked[row][col]) {
        return true;
      }
    }

    return false;
  }

  static List<Waypoint> _waypointsFromPoints(
    List<Translation2d> points,
    PathPlannerPath sourcePath,
    NavGrid navGrid,
    List<List<bool>> blocked,
    {
    required bool keepVelocity,
  }
  ) {
    if (points.length < 2) {
      return [];
    }

    final collisionFreeWaypoints = _findCollisionFreeWaypoints(
      points,
      sourcePath,
      navGrid,
      blocked,
      keepVelocity: keepVelocity,
    );
    if (collisionFreeWaypoints != null) {
      return collisionFreeWaypoints;
    }

    final endpointHeadingHints = keepVelocity
        ? _EndpointHeadingHints(
            startHeading: sourcePath.waypoints.first.heading,
            goalHeading: sourcePath.waypoints.last.heading,
          )
        : null;
    return _buildWaypointsWithScale(
      points,
      controlScale: 0.05,
      endpointScale: keepVelocity ? 0.28 : 1.0,
      headingHints: endpointHeadingHints,
    );
  }

  static List<Translation2d> _minimizeBezierAnchors(
    List<Translation2d> points,
    PathPlannerPath sourcePath,
    NavGrid navGrid,
    List<List<bool>> blocked,
    {
    required bool keepVelocity,
  }
  ) {
    if (points.length <= 2) {
      return points;
    }

    final maxDeviation = max(
      navGrid.nodeSizeMeters * (keepVelocity ? 1.15 : 0.85),
      0.18,
    );
    final anchors = [...points];

    while (anchors.length > 2) {
      int bestRemovalIndex = -1;
      double bestDeviation = double.infinity;

      for (int i = 1; i < anchors.length - 1; i++) {
        final candidateAnchors = [...anchors]..removeAt(i);
        final fit = _evaluateWaypointFit(
          candidateAnchors,
          points,
          sourcePath,
          navGrid,
          blocked,
          keepVelocity: keepVelocity,
        );
        if (fit == null || fit.maxDeviation > maxDeviation) {
          continue;
        }

        if (fit.maxDeviation < bestDeviation) {
          bestDeviation = fit.maxDeviation;
          bestRemovalIndex = i;
        }
      }

      if (bestRemovalIndex < 0) {
        break;
      }

      anchors.removeAt(bestRemovalIndex);
    }

    return _regularizeBezierAnchors(
      anchors,
      points,
      sourcePath,
      navGrid,
      blocked,
      keepVelocity: keepVelocity,
      maxDeviation: maxDeviation,
    );
  }

  static List<Translation2d> _regularizeBezierAnchors(
    List<Translation2d> anchors,
    List<Translation2d> referencePoints,
    PathPlannerPath sourcePath,
    NavGrid navGrid,
    List<List<bool>> blocked,
    {
    required bool keepVelocity,
    required double maxDeviation,
  }
  ) {
    if (anchors.length <= 3) {
      return anchors;
    }

    final evenlySpaced = _resamplePointsByDistance(
      referencePoints,
      anchors.length,
    );
    final candidates = <List<Translation2d>>[
      anchors,
      evenlySpaced,
      _blendAnchorLayouts(anchors, evenlySpaced, 0.25),
      _blendAnchorLayouts(anchors, evenlySpaced, 0.5),
      _blendAnchorLayouts(anchors, evenlySpaced, 0.75),
    ];

    List<Translation2d> bestAnchors = anchors;
    double bestScore = double.infinity;

    for (final candidate in candidates) {
      final fit = _evaluateWaypointFit(
        candidate,
        referencePoints,
        sourcePath,
        navGrid,
        blocked,
        keepVelocity: keepVelocity,
      );
      if (fit == null || fit.maxDeviation > maxDeviation) {
        continue;
      }

      final score = fit.maxDeviation +
          (_anchorSpacingImbalance(candidate) * navGrid.nodeSizeMeters * 0.4);
      if (score < bestScore) {
        bestScore = score;
        bestAnchors = candidate;
      }
    }

    return bestAnchors;
  }

  static List<Translation2d> _resamplePointsByDistance(
    List<Translation2d> points,
    int targetCount,
  ) {
    if (points.length <= 2 || targetCount >= points.length) {
      return [...points];
    }
    if (targetCount <= 2) {
      return [points.first, points.last];
    }

    final totalDistance = _pathDistance(points).toDouble();
    if (totalDistance <= 1.0e-9) {
      return [points.first, points.last];
    }

    final targetSpacing = totalDistance / (targetCount - 1);
    final resampled = <Translation2d>[points.first];
    double traversed = 0.0;
    double nextTarget = targetSpacing;

    for (int i = 1; i < points.length && resampled.length < targetCount - 1; i++) {
      final segmentStart = points[i - 1];
      final segmentEnd = points[i];
      final segmentDistance = segmentStart.getDistance(segmentEnd).toDouble();
      if (segmentDistance <= 1.0e-9) {
        continue;
      }

      while (traversed + segmentDistance >= nextTarget - 1.0e-9 &&
          resampled.length < targetCount - 1) {
        final t = (nextTarget - traversed) / segmentDistance;
        resampled.add(Translation2d(
          segmentStart.x + ((segmentEnd.x - segmentStart.x) * t),
          segmentStart.y + ((segmentEnd.y - segmentStart.y) * t),
        ));
        nextTarget += targetSpacing;
      }

      traversed += segmentDistance;
    }

    if (resampled.length < targetCount) {
      resampled.add(points.last);
    }

    return resampled;
  }

  static List<Translation2d> _blendAnchorLayouts(
    List<Translation2d> original,
    List<Translation2d> normalized,
    double normalizedWeight,
  ) {
    if (original.length != normalized.length || original.length <= 2) {
      return original;
    }

    final blended = <Translation2d>[original.first];
    final originalWeight = 1.0 - normalizedWeight;
    for (int i = 1; i < original.length - 1; i++) {
      blended.add(Translation2d(
        (original[i].x * originalWeight) + (normalized[i].x * normalizedWeight),
        (original[i].y * originalWeight) + (normalized[i].y * normalizedWeight),
      ));
    }
    blended.add(original.last);
    return blended;
  }

  static double _anchorSpacingImbalance(List<Translation2d> anchors) {
    if (anchors.length <= 2) {
      return 0.0;
    }

    final segmentLengths = <double>[
      for (int i = 1; i < anchors.length; i++)
        anchors[i - 1].getDistance(anchors[i]).toDouble(),
    ];
    final averageLength =
        segmentLengths.reduce((a, b) => a + b) / segmentLengths.length;
    if (averageLength <= 1.0e-9) {
      return 0.0;
    }

    final meanAbsoluteDeviation = segmentLengths
            .map((length) => (length - averageLength).abs())
            .reduce((a, b) => a + b) /
        segmentLengths.length;
    return meanAbsoluteDeviation / averageLength;
  }

  static _WaypointFit? _evaluateWaypointFit(
    List<Translation2d> anchors,
    List<Translation2d> referencePoints,
    PathPlannerPath sourcePath,
    NavGrid navGrid,
    List<List<bool>> blocked,
    {
    required bool keepVelocity,
  }
  ) {
    final waypoints = _findCollisionFreeWaypoints(
      anchors,
      sourcePath,
      navGrid,
      blocked,
      keepVelocity: keepVelocity,
    );
    if (waypoints == null) {
      return null;
    }

    final candidatePath = sourcePath.duplicate(sourcePath.name)
      ..waypoints = PathPlannerPath.cloneWaypoints(waypoints);

    try {
      candidatePath.generatePathPoints();
    } catch (_) {
      return null;
    }

    return _WaypointFit(
      waypoints: waypoints,
      maxDeviation: _maxDistanceToPath(
        referencePoints,
        candidatePath.pathPositions,
      ),
    );
  }

  static List<Waypoint>? _findCollisionFreeWaypoints(
    List<Translation2d> points,
    PathPlannerPath sourcePath,
    NavGrid navGrid,
    List<List<bool>> blocked,
    {
    required bool keepVelocity,
  }
  ) {
    if (points.length < 2) {
      return null;
    }

    final endpointHeadingHints = keepVelocity
        ? _EndpointHeadingHints(
            startHeading: sourcePath.waypoints.first.heading,
            goalHeading: sourcePath.waypoints.last.heading,
          )
        : null;
    const controlScales = [0.34, 0.26, 0.20, 0.14, 0.08, 0.05];
    final endpointScales = keepVelocity
        ? const [1.8, 1.4, 1.1, 0.8, 0.55, 0.35]
        : const [1.0];
    for (final endpointScale in endpointScales) {
      for (final scale in controlScales) {
        final waypoints = _buildWaypointsWithScale(
          points,
          controlScale: scale,
          endpointScale: endpointScale,
          headingHints: endpointHeadingHints,
        );
        if (_isWaypointSetCollisionFree(
            waypoints, sourcePath, navGrid, blocked)) {
          return waypoints;
        }
      }
    }

    return null;
  }

  static double _maxDistanceToPath(
    List<Translation2d> referencePoints,
    List<Translation2d> candidatePathPoints,
  ) {
    if (referencePoints.isEmpty || candidatePathPoints.isEmpty) {
      return double.infinity;
    }

    double maxDeviation = 0.0;
    for (final referencePoint in referencePoints) {
      final minDistance = candidatePathPoints
              .map((candidatePoint) =>
                  referencePoint.getDistance(candidatePoint).toDouble())
              .minOrNull ??
          double.infinity;
      if (minDistance > maxDeviation) {
        maxDeviation = minDistance;
      }
    }

    return maxDeviation;
  }

  static List<Waypoint> _buildWaypointsWithScale(
    List<Translation2d> points,
    {
    required double controlScale,
    required double endpointScale,
    _EndpointHeadingHints? headingHints,
  }
  ) {
    final waypoints = <Waypoint>[];

    for (int i = 0; i < points.length; i++) {
      final anchor = points[i];
      Translation2d? prevControl;
      Translation2d? nextControl;

      Translation2d tangent;
      if (i == 0) {
        tangent = _tangentFromHeading(
              headingHints?.startHeading,
              anchor.getDistance(points[1]),
            ) ??
            (points[1] - points[0]);
      } else if (i == points.length - 1) {
        tangent = _tangentFromHeading(
              headingHints?.goalHeading,
              points[i].getDistance(points[i - 1]),
            ) ??
            (points[i] - points[i - 1]);
      } else if (headingHints != null && i == 1) {
        tangent = _blendTranslationDirections(
          _tangentFromHeading(
                headingHints.startHeading,
                max(
                  anchor.getDistance(points[i - 1]),
                  anchor.getDistance(points[i + 1]),
                ),
              ) ??
              (points[i + 1] - points[i - 1]),
          (points[i + 1] - points[i - 1]),
          0.72,
        );
      } else if (headingHints != null && i == points.length - 2) {
        tangent = _blendTranslationDirections(
          _tangentFromHeading(
                headingHints.goalHeading,
                max(
                  anchor.getDistance(points[i - 1]),
                  anchor.getDistance(points[i + 1]),
                ),
              ) ??
              (points[i + 1] - points[i - 1]),
          (points[i + 1] - points[i - 1]),
          0.72,
        );
      } else {
        tangent = (points[i + 1] - points[i - 1]) / 2.0;
      }

      final tangentNorm = tangent.norm;
      final tangentUnit = tangentNorm <= 1.0e-9
          ? const Translation2d(1.0, 0.0)
          : tangent / tangentNorm;

      if (i > 0) {
        final distToPrev = anchor.getDistance(points[i - 1]);
        final backScale = max(
          0.05,
          distToPrev *
              controlScale *
              ((i == points.length - 1 || i == points.length - 2)
                  ? endpointScale
                  : 1.0),
        );
        prevControl = anchor - (tangentUnit * backScale);
      }

      if (i < points.length - 1) {
        final distToNext = anchor.getDistance(points[i + 1]);
        final forwardScale = max(
          0.05,
          distToNext *
              controlScale *
              ((i == 0 || i == 1) ? endpointScale : 1.0),
        );
        nextControl = anchor + (tangentUnit * forwardScale);
      }

      waypoints.add(
        Waypoint(
          anchor: anchor,
          prevControl: prevControl,
          nextControl: nextControl,
        ),
      );
    }

    return waypoints;
  }

  static bool _isWaypointSetCollisionFree(
    List<Waypoint> waypoints,
    PathPlannerPath sourcePath,
    NavGrid navGrid,
    List<List<bool>> blocked,
  ) {
    if (waypoints.length < 2) {
      return false;
    }

    final candidatePath = sourcePath.duplicate(sourcePath.name)
      ..waypoints = PathPlannerPath.cloneWaypoints(waypoints);

    try {
      candidatePath.generatePathPoints();
    } catch (_) {
      return false;
    }

    final maxPos = candidatePath.waypoints.length - 1;
    final sampleStep = max(0.005, navGrid.nodeSizeMeters * 0.20);
    for (double pos = 0.0; pos <= maxPos; pos += sampleStep) {
      final point = candidatePath.samplePath(pos);
      if (_isPointBlocked(point, navGrid, blocked)) {
        return false;
      }
    }

    final endPoint = candidatePath.samplePath(maxPos.toDouble());
    return !_isPointBlocked(endPoint, navGrid, blocked);
  }

  static bool _isPointBlocked(
    Translation2d point,
    NavGrid navGrid,
    List<List<bool>> blocked,
  ) {
    final rows = blocked.length;
    final cols = blocked[0].length;

    final row = (point.y / navGrid.nodeSizeMeters).floor().clamp(0, rows - 1);
    final col = (point.x / navGrid.nodeSizeMeters).floor().clamp(0, cols - 1);
    return blocked[row][col];
  }

  static num _pathDistance(List<Translation2d> points) {
    num distance = 0.0;
    for (int i = 1; i < points.length; i++) {
      distance += points[i - 1].getDistance(points[i]);
    }
    return distance;
  }

  static double _turnPenalty(
    _GridCell? parent,
    _GridCell current,
    _GridCell neighbor,
    {
    required bool keepVelocity,
  }
  ) {
    if (parent == null) {
      return 0.0;
    }

    final inDx = current.col - parent.col;
    final inDy = current.row - parent.row;
    final outDx = neighbor.col - current.col;
    final outDy = neighbor.row - current.row;

    if (inDx == outDx && inDy == outDy) {
      return 0.0;
    }

    final inVec = Translation2d(inDx.toDouble(), inDy.toDouble());
    final outVec = Translation2d(outDx.toDouble(), outDy.toDouble());
    final inNorm = inVec.norm;
    final outNorm = outVec.norm;
    if (inNorm <= 1.0e-9 || outNorm <= 1.0e-9) {
      return 0.0;
    }

    final cosine =
        ((inVec.x * outVec.x) + (inVec.y * outVec.y)) / (inNorm * outNorm);
    final angle = acos(cosine.clamp(-1.0, 1.0));

    if (angle < 0.35) {
      return 0.0;
    }

    final penalty = 0.12 + (angle * 0.23);
    return keepVelocity ? penalty * _keepVelocityTurnPenaltyScale : penalty;
  }

  static double _headingPenalty({
    required _GridCell? parent,
    required _GridCell current,
    required _GridCell neighbor,
    required _GridCell start,
    required _GridCell goal,
    required Rotation2d? startHeading,
    required Rotation2d? goalHeading,
    required bool keepVelocity,
  }) {
    if (!keepVelocity) {
      return 0.0;
    }

    final moveHeading = Rotation2d.fromComponents(
      (neighbor.col - current.col).toDouble(),
      (neighbor.row - current.row).toDouble(),
    );

    double penalty = 0.0;
    if (parent == null && startHeading != null && current == start) {
      penalty += _angleDifference(moveHeading, startHeading) *
          _keepVelocityHeadingPenaltyScale;
    }

    if (goalHeading != null && neighbor == goal) {
      penalty += _angleDifference(moveHeading, goalHeading) *
          _keepVelocityHeadingPenaltyScale;
    }

    return penalty;
  }

  static double _angleDifference(Rotation2d a, Rotation2d b) {
    final diff = (a - b).radians.abs().toDouble();
    return min(diff, (2 * pi) - diff);
  }

  static Translation2d? _tangentFromHeading(
    Rotation2d? heading,
    num length,
  ) {
    if (heading == null || length <= 1.0e-9) {
      return null;
    }

    return Translation2d.fromAngle(length, heading);
  }

  static Translation2d _blendTranslationDirections(
    Translation2d preferred,
    Translation2d fallback,
    double preferredWeight,
  ) {
    return Translation2d(
      (preferred.x * preferredWeight) +
          (fallback.x * (1.0 - preferredWeight)),
      (preferred.y * preferredWeight) +
          (fallback.y * (1.0 - preferredWeight)),
    );
  }

  static double _robotRadiusForSize(Size robotSize) {
    final halfWidth = robotSize.width * 0.5;
    final halfLength = robotSize.height * 0.5;
    return max(halfWidth, halfLength);
  }
}

class _EndpointHeadingHints {
  final Rotation2d startHeading;
  final Rotation2d goalHeading;

  const _EndpointHeadingHints({
    required this.startHeading,
    required this.goalHeading,
  });
}

class _WaypointFit {
  final List<Waypoint> waypoints;
  final double maxDeviation;

  const _WaypointFit({
    required this.waypoints,
    required this.maxDeviation,
  });
}

class _GridSolveResult {
  final List<_GridCell> pathCells;
  final int visitedNodes;

  const _GridSolveResult(this.pathCells, this.visitedNodes);
}

class _QueueEntry {
  final int key;
  final double f;

  const _QueueEntry(this.key, this.f);
}

class _GridEdge {
  final _GridCell cell;
  final double cost;

  const _GridEdge(this.cell, this.cost);
}

class _GridCell {
  final int row;
  final int col;

  const _GridCell(this.row, this.col);

  int key(int cols) => (row * cols) + col;

  static _GridCell fromKey(int key, int cols) {
    return _GridCell(key ~/ cols, key % cols);
  }
}
