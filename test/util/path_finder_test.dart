import 'dart:convert';
import 'dart:ui';

import 'package:file/memory.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pathplanner/path/goal_end_state.dart';
import 'package:pathplanner/path/ideal_starting_state.dart';
import 'package:pathplanner/path/path_constraints.dart';
import 'package:pathplanner/path/pathplanner_path.dart';
import 'package:pathplanner/path/waypoint.dart';
import 'package:pathplanner/pathfinding/nav_grid.dart';
import 'package:pathplanner/util/path_finder.dart';
import 'package:pathplanner/util/wpimath/geometry.dart';

void main() {
  test('path finder routes around blocked cells', () async {
    final fs = MemoryFileSystem();
    fs.directory('/project').createSync(recursive: true);
    fs.directory('/project/paths').createSync(recursive: true);

    final navGrid = NavGrid.blankGrid(
      nodeSizeMeters: 1.0,
      fieldSize: const Size(6.0, 6.0),
    );
    navGrid.grid[2][2] = true;
    navGrid.grid[3][3] = true;

    fs
        .file('/project/navgrid.json')
        .writeAsStringSync(jsonEncode(navGrid.toJson()));

    final sourcePath = PathPlannerPath(
      name: 'testPath',
      waypoints: [
        Waypoint(
          anchor: const Translation2d(0.5, 0.5),
          nextControl: const Translation2d(1.0, 0.5),
        ),
        Waypoint(
          prevControl: const Translation2d(5.0, 5.5),
          anchor: const Translation2d(5.5, 5.5),
        ),
      ],
      globalConstraints: PathConstraints(),
      goalEndState: GoalEndState(0.0, const Rotation2d()),
      constraintZones: [],
      pointTowardsZones: [],
      rotationTargets: [],
      eventMarkers: [],
      pathDir: '/project/paths',
      fs: fs,
      reversed: false,
      folder: null,
      idealStartingState: IdealStartingState(0.0, const Rotation2d()),
      useDefaultConstraints: true,
    );

    final result = await PathFinder.findPath(
      sourcePath: sourcePath,
      fieldSizeMeters: const Size(6.0, 6.0),
      additionalObstacles: const [],
      algorithm: PathFinderAlgorithm.aStar,
    );

    expect(result, isNotNull);
    expect(result!.path.waypoints.length, greaterThan(2));
    expect(result.path.waypoints.first.anchor, const Translation2d(0.5, 0.5));
    expect(result.path.waypoints.last.anchor, const Translation2d(5.5, 5.5));
    expect(result.distanceMeters, greaterThan(0));
  });

  test('path finder supports dijkstra', () async {
    final fs = MemoryFileSystem();
    fs.directory('/project').createSync(recursive: true);
    fs.directory('/project/paths').createSync(recursive: true);

    final sourcePath = PathPlannerPath.defaultPath(
      pathDir: '/project/paths',
      fs: fs,
    );
    sourcePath.waypoints.first.anchor = const Translation2d(0.5, 0.5);
    sourcePath.waypoints.first.nextControl = const Translation2d(1.0, 0.5);
    sourcePath.waypoints.last.anchor = const Translation2d(2.5, 2.5);
    sourcePath.waypoints.last.prevControl = const Translation2d(2.0, 2.5);

    final navGrid = NavGrid.blankGrid(
      nodeSizeMeters: 0.5,
      fieldSize: const Size(3.0, 3.0),
    );
    fs
        .file('/project/navgrid.json')
        .writeAsStringSync(jsonEncode(navGrid.toJson()));

    final result = await PathFinder.findPath(
      sourcePath: sourcePath,
      fieldSizeMeters: const Size(3.0, 3.0),
      additionalObstacles: const [],
      algorithm: PathFinderAlgorithm.dijkstra,
    );

    expect(result, isNotNull);
    expect(result!.visitedNodes, greaterThan(0));
  });
}
