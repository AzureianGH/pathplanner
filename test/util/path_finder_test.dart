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

  test('keep velocity preserves endpoint heading hints', () async {
    final fs = MemoryFileSystem();
    fs.directory('/project').createSync(recursive: true);
    fs.directory('/project/paths').createSync(recursive: true);

    final navGrid = NavGrid.blankGrid(
      nodeSizeMeters: 0.5,
      fieldSize: const Size(6.0, 6.0),
    );
    fs
        .file('/project/navgrid.json')
        .writeAsStringSync(jsonEncode(navGrid.toJson()));

    final sourcePath = PathPlannerPath(
      name: 'testPath',
      waypoints: [
        Waypoint(
          anchor: const Translation2d(1.0, 1.0),
          nextControl: const Translation2d(1.0, 2.0),
        ),
        Waypoint(
          prevControl: const Translation2d(4.0, 5.0),
          anchor: const Translation2d(5.0, 5.0),
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

    final noKeepVelocity = await PathFinder.findPath(
      sourcePath: sourcePath,
      fieldSizeMeters: const Size(6.0, 6.0),
      additionalObstacles: const [],
      keepVelocity: false,
    );
    final keepVelocity = await PathFinder.findPath(
      sourcePath: sourcePath,
      fieldSizeMeters: const Size(6.0, 6.0),
      additionalObstacles: const [],
      keepVelocity: true,
    );

    expect(noKeepVelocity, isNotNull);
    expect(keepVelocity, isNotNull);

    final keepStartHeading = keepVelocity!.path.waypoints.first.heading;
    final keepEndHeading = keepVelocity.path.waypoints.last.heading;
    final noKeepStartHeading = noKeepVelocity!.path.waypoints.first.heading;

    expect((keepStartHeading.degrees - 90).abs(), lessThan(15));
    expect((keepEndHeading.degrees - 0).abs(), lessThan(15));
    expect((noKeepStartHeading.degrees - 90).abs(), greaterThan(20));
  });

  test('keep velocity minimizes bezier waypoint anchors', () async {
    final fs = MemoryFileSystem();
    fs.directory('/project').createSync(recursive: true);
    fs.directory('/project/paths').createSync(recursive: true);

    final navGrid = NavGrid.blankGrid(
      nodeSizeMeters: 0.2,
      fieldSize: const Size(16.0, 8.0),
    );
    fs
        .file('/project/navgrid.json')
        .writeAsStringSync(jsonEncode(navGrid.toJson()));

    final sourcePath = PathPlannerPath(
      name: 'testPath',
      waypoints: [
        Waypoint(
          anchor: const Translation2d(2.0, 7.0),
          nextControl: const Translation2d(2.0, 6.0),
        ),
        Waypoint(
          prevControl: const Translation2d(12.0, 1.0),
          anchor: const Translation2d(14.0, 1.0),
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
      idealStartingState: IdealStartingState(4.0, Rotation2d.fromDegrees(-90)),
      useDefaultConstraints: true,
    );

    final result = await PathFinder.findPath(
      sourcePath: sourcePath,
      fieldSizeMeters: const Size(16.0, 8.0),
      additionalObstacles: const [],
      keepVelocity: true,
    );

    expect(result, isNotNull);
    expect(result!.path.waypoints.length, lessThanOrEqualTo(10));

    final segmentLengths = [
      for (int i = 1; i < result.path.waypoints.length; i++)
        result.path.waypoints[i - 1]
            .anchor
            .getDistance(result.path.waypoints[i].anchor)
            .toDouble(),
    ];
    expect(segmentLengths.every((length) => length >= 0.25), isTrue);
  });
}
