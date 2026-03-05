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

  static Future<PathFinderResult?> findPath({
    required PathPlannerPath sourcePath,
    required Size fieldSizeMeters,
    required List<OptimizationBoundary> additionalObstacles,
    PathFinderAlgorithm algorithm = PathFinderAlgorithm.aStar,
    Size robotSize = const Size(0.9, 0.9),
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
    );
    if (solveResult == null || solveResult.pathCells.isEmpty) {
      return null;
    }

    final rawPoints = <Translation2d>[startPos];
    for (int i = 1; i < solveResult.pathCells.length - 1; i++) {
      rawPoints.add(_cellCenter(solveResult.pathCells[i], navGrid));
    }
    rawPoints.add(goalPos);

    final simplified = _simplifyPath(rawPoints, blocked, navGrid);
    if (simplified.length < 2) {
      return null;
    }

    final smoothed = _smoothPath(simplified, blocked, navGrid);
    if (smoothed.length < 2) {
      return null;
    }

    final waypoints = _waypointsFromPoints(
      smoothed,
      sourcePath,
      navGrid,
      blocked,
    );
    if (waypoints.length < 2) {
      return null;
    }

    final generatedPath = sourcePath.duplicate(sourcePath.name)
      ..waypoints = waypoints
      ..generatePathPoints();

    return PathFinderResult(
      path: generatedPath,
      distanceMeters: _pathDistance(smoothed),
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

        final turnPenalty = _turnPenalty(parentCell, current, edge.cell);
        final tentativeG = currentG + edge.cost + turnPenalty;
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
  ) {
    if (points.length <= 2) {
      return points;
    }

    final simplified = <Translation2d>[points.first];
    int anchorIdx = 0;

    while (anchorIdx < points.length - 1) {
      int targetIdx = points.length - 1;
      while (targetIdx > anchorIdx + 1 &&
          _isLineBlocked(
              points[anchorIdx], points[targetIdx], blocked, navGrid)) {
        targetIdx--;
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
  ) {
    if (points.length < 3) {
      return points;
    }

    var current = <Translation2d>[...points];

    for (int iter = 0; iter < 2; iter++) {
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
  ) {
    if (points.length < 2) {
      return [];
    }

    const controlScales = [0.34, 0.26, 0.20, 0.14, 0.08, 0.05];
    for (final scale in controlScales) {
      final waypoints = _buildWaypointsWithScale(points, scale);
      if (_isWaypointSetCollisionFree(
          waypoints, sourcePath, navGrid, blocked)) {
        return waypoints;
      }
    }

    return _buildWaypointsWithScale(points, 0.05);
  }

  static List<Waypoint> _buildWaypointsWithScale(
    List<Translation2d> points,
    double controlScale,
  ) {
    final waypoints = <Waypoint>[];

    for (int i = 0; i < points.length; i++) {
      final anchor = points[i];
      Translation2d? prevControl;
      Translation2d? nextControl;

      Translation2d tangent;
      if (i == 0) {
        tangent = points[1] - points[0];
      } else if (i == points.length - 1) {
        tangent = points[i] - points[i - 1];
      } else {
        tangent = (points[i + 1] - points[i - 1]) / 2.0;
      }

      final tangentNorm = tangent.norm;
      final tangentUnit = tangentNorm <= 1.0e-9
          ? const Translation2d(1.0, 0.0)
          : tangent / tangentNorm;

      if (i > 0) {
        final distToPrev = anchor.getDistance(points[i - 1]);
        final backScale = max(0.05, distToPrev * controlScale);
        prevControl = anchor - (tangentUnit * backScale);
      }

      if (i < points.length - 1) {
        final distToNext = anchor.getDistance(points[i + 1]);
        final forwardScale = max(0.05, distToNext * controlScale);
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

    return 0.12 + (angle * 0.23);
  }

  static double _robotRadiusForSize(Size robotSize) {
    final halfWidth = robotSize.width * 0.5;
    final halfLength = robotSize.height * 0.5;
    return max(halfWidth, halfLength);
  }
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
