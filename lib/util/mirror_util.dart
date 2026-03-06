import 'dart:math';

import 'package:pathplanner/path/optimization_boundary.dart';
import 'package:pathplanner/path/pathplanner_path.dart';
import 'package:pathplanner/path/waypoint.dart';
import 'package:pathplanner/util/wpimath/geometry.dart';

Translation2d mirrorPointAboutAxis(
  Translation2d point,
  Translation2d axisCenter,
  double axisAngleRad,
) {
  final ux = cos(axisAngleRad);
  final uy = sin(axisAngleRad);
  final vx = point.x - axisCenter.x;
  final vy = point.y - axisCenter.y;

  final dot = (vx * ux) + (vy * uy);
  final rx = (2 * dot * ux) - vx;
  final ry = (2 * dot * uy) - vy;

  return Translation2d(axisCenter.x + rx, axisCenter.y + ry);
}

Rotation2d mirrorRotationAboutAxis(
  Rotation2d rotation,
  double axisAngleRad,
) {
  final ux = cos(axisAngleRad);
  final uy = sin(axisAngleRad);

  final hx = rotation.cosine;
  final hy = rotation.sine;

  final dot = (hx * ux) + (hy * uy);
  final rx = (2 * dot * ux) - hx;
  final ry = (2 * dot * uy) - hy;

  return Rotation2d.fromComponents(rx, ry);
}

void mirrorPathInPlace(
  PathPlannerPath path,
  Translation2d axisCenter,
  double axisAngleRad,
) {
  for (final waypoint in path.waypoints) {
    waypoint.anchor =
        mirrorPointAboutAxis(waypoint.anchor, axisCenter, axisAngleRad);
    if (waypoint.prevControl != null) {
      waypoint.prevControl = mirrorPointAboutAxis(
        waypoint.prevControl!,
        axisCenter,
        axisAngleRad,
      );
    }
    if (waypoint.nextControl != null) {
      waypoint.nextControl = mirrorPointAboutAxis(
        waypoint.nextControl!,
        axisCenter,
        axisAngleRad,
      );
    }

    if (waypoint.linkedName != null) {
      Waypoint.linked[waypoint.linkedName!] = Pose2d(
        waypoint.anchor,
        Waypoint.linked[waypoint.linkedName!]?.rotation ?? const Rotation2d(),
      );
    }
  }

  path.idealStartingState.rotation = mirrorRotationAboutAxis(
    path.idealStartingState.rotation,
    axisAngleRad,
  );
  path.goalEndState.rotation = mirrorRotationAboutAxis(
    path.goalEndState.rotation,
    axisAngleRad,
  );

  for (final target in path.rotationTargets) {
    target.rotation = mirrorRotationAboutAxis(target.rotation, axisAngleRad);
  }

  for (final zone in path.pointTowardsZones) {
    zone.fieldPosition =
        mirrorPointAboutAxis(zone.fieldPosition, axisCenter, axisAngleRad);
    zone.rotationOffset =
        mirrorRotationAboutAxis(zone.rotationOffset, axisAngleRad);
  }

  for (final boundary in path.optimizationBoundaries) {
    _mirrorBoundaryInPlace(boundary, axisCenter, axisAngleRad);
  }

  path.optimizationReferencePath = [
    for (final point in path.optimizationReferencePath)
      mirrorPointAboutAxis(point, axisCenter, axisAngleRad),
  ];
}

void _mirrorBoundaryInPlace(
  OptimizationBoundary boundary,
  Translation2d axisCenter,
  double axisAngleRad,
) {
  final center = boundary.center;
  final mirroredCenter = mirrorPointAboutAxis(center, axisCenter, axisAngleRad);
  final mirroredRotation = mirrorRotationAboutAxis(
    Rotation2d.fromDegrees(boundary.rotationDeg),
    axisAngleRad,
  );

  boundary.rotationDeg = mirroredRotation.degrees.toDouble();
  boundary.setFromCenter(mirroredCenter);
}

void copyPathContents(PathPlannerPath target, PathPlannerPath source) {
  target.waypoints = PathPlannerPath.cloneWaypoints(source.waypoints);
  target.globalConstraints = source.globalConstraints.clone();
  target.goalEndState = source.goalEndState.clone();
  target.constraintZones =
      PathPlannerPath.cloneConstraintZones(source.constraintZones);
  target.optimizationBoundaries = PathPlannerPath.cloneOptimizationBoundaries(
      source.optimizationBoundaries);
  target.optimizationReferencePath =
      PathPlannerPath.cloneOptimizationReferencePath(
          source.optimizationReferencePath);
  target.optimizationReferenceAdherence = source.optimizationReferenceAdherence;
  target.pointTowardsZones =
      PathPlannerPath.clonePointTowardsZones(source.pointTowardsZones);
  target.rotationTargets =
      PathPlannerPath.cloneRotationTargets(source.rotationTargets);
  target.eventMarkers = PathPlannerPath.cloneEventMarkers(source.eventMarkers);
  target.reversed = source.reversed;
  target.idealStartingState = source.idealStartingState.clone();
  target.useDefaultConstraints = source.useDefaultConstraints;

  target.generateAndSavePath();
}
