import 'dart:math';
import 'dart:ui';

import 'package:file/memory.dart';
import 'package:flutter/foundation.dart';
import 'package:isolate_manager/isolate_manager.dart';
import 'package:pathplanner/path/optimization_boundary.dart';
import 'package:pathplanner/path/path_point.dart';
import 'package:pathplanner/path/pathplanner_path.dart';
import 'package:pathplanner/path/waypoint.dart';
import 'package:pathplanner/services/log.dart';
import 'package:pathplanner/trajectory/config.dart';
import 'package:pathplanner/trajectory/trajectory.dart';
import 'package:pathplanner/util/wpimath/geometry.dart';

class PathOptimizer {
  static const int populationSize = 50;
  static const int generations = 100;

  static IsolateManager? _manager;

  static Future<OptimizationResult> optimizePath(PathPlannerPath path,
      RobotConfig config, Size fieldSizeMeters, Size robotSizeMeters,
      {ValueChanged<OptimizationResult>? onUpdate}) async {
    PathPlannerPath copy = PathPlannerPath(
      name: path.name,
      waypoints: PathPlannerPath.cloneWaypoints(path.waypoints),
      globalConstraints: path.globalConstraints.clone(),
      goalEndState: path.goalEndState.clone(),
      constraintZones:
          PathPlannerPath.cloneConstraintZones(path.constraintZones),
      optimizationBoundaries: PathPlannerPath.cloneOptimizationBoundaries(
          path.optimizationBoundaries),
      optimizationReferencePath: PathPlannerPath.cloneOptimizationReferencePath(
          path.optimizationReferencePath),
      optimizationReferenceAdherence: path.optimizationReferenceAdherence,
      rotationTargets:
          PathPlannerPath.cloneRotationTargets(path.rotationTargets),
      pointTowardsZones:
          PathPlannerPath.clonePointTowardsZones(path.pointTowardsZones),
      eventMarkers: [],
      pathDir: '',
      fs: MemoryFileSystem(),
      reversed: path.reversed,
      folder: '',
      idealStartingState: path.idealStartingState.clone(),
      useDefaultConstraints: path.useDefaultConstraints,
    );

    _manager ??= IsolateManager.createCustom(_optimizePathWaypoints);

    Log.info('Optimizing path: ${path.name}');

    final start = DateTime.now();
    final OptimizationResult result = await _manager!.compute(
      _OptimizerArgs(copy, config, fieldSizeMeters, robotSizeMeters),
      callback: (value) {
        OptimizationResult result = value;
        Log.info(
            'Best fit after generation ${result.generation}: ${result.runtime.toStringAsFixed(2)}s');
        onUpdate?.call(result);

        return result.generation == generations;
      },
    );
    final runtime = DateTime.now().difference(start);
    Log.info(
        'Finished ${PathOptimizer.generations} generations in ${(runtime.inMilliseconds / 1000.0).toStringAsFixed(2)}s');
    return result;
  }

  @isolateManagerCustomWorker
  static void _optimizePathWaypoints(dynamic params) {
    IsolateManagerFunction.customFunction<OptimizationResult, _OptimizerArgs>(
      params,
      onEvent: (controller, args) async {
        var rand = Random();

        bool preventFieldExit = true;
        final num robotRadius = sqrt(pow(args.robotSizeMeters.width / 2.0, 2) +
            pow(args.robotSizeMeters.height / 2.0, 2));
        final forbiddenBoundaries = PathPlannerPath.cloneOptimizationBoundaries(
            args.path.optimizationBoundaries);
        final optimizationReferencePath =
            PathPlannerPath.cloneOptimizationReferencePath(
                args.path.optimizationReferencePath);
        final optimizationReferenceAdherence =
            args.path.optimizationReferenceAdherence.clamp(0.0, 1.0).toDouble();
        final minPos = Translation2d(robotRadius, robotRadius);
        final maxPos = Translation2d(args.fieldSizeMeters.width - robotRadius,
            args.fieldSizeMeters.height - robotRadius);
        final processedReferencePath = _prepareReferencePath(
          optimizationReferencePath,
          args.path.waypoints.first.anchor,
          args.path.waypoints.last.anchor,
          minPos,
          maxPos,
        );
        for (Waypoint w in args.path.waypoints) {
          if (w.anchor.x < minPos.x ||
              w.anchor.y < minPos.y ||
              w.anchor.x > maxPos.x ||
              w.anchor.y > maxPos.y) {
            preventFieldExit = false;
            break;
          }
        }

        List<_Individual> population = [];

        final detourSeedPaths = _buildDetourSeedPaths(
          args.path,
          forbiddenBoundaries,
          minPos,
          maxPos,
          robotRadius.toDouble(),
        );
        final referenceSeedPaths = _buildReferenceSeedPaths(
          args.path,
          processedReferencePath,
          optimizationReferenceAdherence,
          minPos,
          maxPos,
        );
        final seedPaths = <PathPlannerPath>[
          ...detourSeedPaths,
          ...referenceSeedPaths,
        ];
        final fixedStart = args.path.waypoints.first.anchor;
        final fixedEnd = args.path.waypoints.last.anchor;

        for (final seed in seedPaths) {
          population.add(_Individual(
              seed,
              args.config,
              fixedStart,
              fixedEnd,
              minPos,
              maxPos,
              preventFieldExit,
              forbiddenBoundaries,
              robotRadius.toDouble(),
              processedReferencePath,
              optimizationReferenceAdherence));
        }

        while (population.length < populationSize) {
          final index = population.length;
          List<Waypoint> mutatedPoints = [];
          final baseSeed = (optimizationReferenceAdherence >= 0.6 &&
                  referenceSeedPaths.isNotEmpty &&
                  rand.nextDouble() < 0.7)
              ? referenceSeedPaths[rand.nextInt(referenceSeedPaths.length)]
              : seedPaths[rand.nextInt(seedPaths.length)];
          final p = baseSeed.duplicate(args.path.name);
          final mutationScale = (index % 3 == 0)
              ? 1.8
              : (index % 3 == 1)
                  ? 1.0
                  : 0.5;

          for (int i = 0; i < p.waypoints.length; i++) {
            mutatedPoints.add(_Individual.mutate(
                p.waypoints[i], i, p.waypoints.length,
                scale: mutationScale));
          }
          p.waypoints = mutatedPoints;

          population.add(_Individual(
              p,
              args.config,
              fixedStart,
              fixedEnd,
              minPos,
              maxPos,
              preventFieldExit,
              forbiddenBoundaries,
              robotRadius.toDouble(),
              processedReferencePath,
              optimizationReferenceAdherence));
        }

        int generation = 1;
        OptimizationResult? bestFeasibleFit;
        OptimizationResult? bestFallbackFit;
        while (generation <= generations) {
          population.sort(_Individual.compare);

          final bestCandidate = population.first;
          if (bestFallbackFit == null ||
              bestCandidate.objective < bestFallbackFit.score) {
            bestFallbackFit = OptimizationResult(
              bestCandidate.path,
              bestCandidate.trajectoryRuntime,
              generation,
              score: bestCandidate.objective,
            );
          }

          final int eliteCount = max(2, (populationSize * 0.15).floor());
          List<_Individual> nextGen = List.generate(
              eliteCount, (index) => population[index].duplicateForEvolution());

          final parentPool = max(2, (populationSize * 0.6).floor());
          while (nextGen.length < populationSize - 2) {
            final parent1 = population[rand.nextInt(parentPool)];
            final parent2 = population[rand.nextInt(parentPool)];
            nextGen.add(parent1.crossover(parent2));
          }

          while (nextGen.length < populationSize) {
            final PathPlannerPath p;
            if (optimizationReferenceAdherence >= 0.6 &&
                referenceSeedPaths.isNotEmpty &&
                rand.nextDouble() < 0.65) {
              p = referenceSeedPaths[rand.nextInt(referenceSeedPaths.length)]
                  .duplicate(args.path.name);
            } else {
              p = args.path.duplicate(args.path.name);
            }
            p.waypoints = [
              for (int i = 0; i < p.waypoints.length; i++)
                _Individual.mutate(p.waypoints[i], i, p.waypoints.length,
                    scale: 2.2),
            ];
            nextGen.add(_Individual(
                p,
                args.config,
                fixedStart,
                fixedEnd,
                minPos,
                maxPos,
                preventFieldExit,
                forbiddenBoundaries,
                robotRadius.toDouble(),
                processedReferencePath,
                optimizationReferenceAdherence));
          }

          _Individual? bestFeasibleCandidate;
          for (final candidate in population) {
            if (candidate.isFeasible) {
              bestFeasibleCandidate = candidate;
              break;
            }
          }

          if (bestFeasibleCandidate != null &&
              (bestFeasibleFit == null ||
                  _Individual.compareResult(
                          bestFeasibleCandidate, bestFeasibleFit) <
                      0)) {
            bestFeasibleFit = OptimizationResult(bestFeasibleCandidate.path,
                bestFeasibleCandidate.trajectoryRuntime, generation,
                score: bestFeasibleCandidate.objective);
          }

          final OptimizationResult? bestAvailable =
              bestFeasibleFit ?? bestFallbackFit;
          final resultToSend = bestAvailable != null
              ? bestAvailable.withGeneration(generation)
              : OptimizationResult(
                  args.path.duplicate(args.path.name),
                  double.infinity,
                  generation,
                  score: double.infinity,
                );
          controller.sendResult(resultToSend);

          population = nextGen;
          generation++;
        }

        if (bestFeasibleFit != null) {
          return bestFeasibleFit;
        } else if (bestFallbackFit != null) {
          return bestFallbackFit;
        } else {
          return OptimizationResult(
            args.path.duplicate(args.path.name),
            double.infinity,
            generations,
            score: double.infinity,
          );
        }
      },
    );
  }

  static List<PathPlannerPath> _buildDetourSeedPaths(
    PathPlannerPath basePath,
    List<OptimizationBoundary> boundaries,
    Translation2d minPos,
    Translation2d maxPos,
    double robotRadius,
  ) {
    final seeds = <PathPlannerPath>[basePath.duplicate(basePath.name)];
    if (basePath.waypoints.length < 2 || boundaries.isEmpty) {
      return seeds;
    }

    final start = basePath.waypoints.first.anchor;
    final end = basePath.waypoints.last.anchor;

    for (final boundary in boundaries) {
      final inflation = robotRadius + boundary.tolerance;
      if (!_segmentIntersectsInflatedBoundary(
          start, end, boundary, inflation)) {
        continue;
      }

      final clear = inflation + 0.45;
      final rect = boundary.toRect();
      final centerX = (rect.left + rect.right) / 2.0;
      final centerY = (rect.top + rect.bottom) / 2.0;

      final detours = <Translation2d>[
        Translation2d(rect.left - clear, centerY),
        Translation2d(rect.right + clear, centerY),
        Translation2d(centerX, rect.top + clear),
        Translation2d(centerX, rect.bottom - clear),
      ];

      for (final detour in detours) {
        final clamped = Translation2d(
          detour.x.clamp(minPos.x + 0.05, maxPos.x - 0.05),
          detour.y.clamp(minPos.y + 0.05, maxPos.y - 0.05),
        );

        final candidate = basePath.duplicate(basePath.name);
        int idx;
        if (candidate.waypoints.length < 3) {
          candidate.insertWaypointAfter(0);
          idx = 1;
        } else {
          idx = candidate.waypoints.length ~/ 2;
        }

        candidate.waypoints[idx].move(clamped.x, clamped.y);
        seeds.add(candidate);
      }

      final twoPointDetours = <(Translation2d, Translation2d)>[
        (
          Translation2d(rect.left - clear, rect.top + clear),
          Translation2d(rect.right + clear, rect.top + clear)
        ),
        (
          Translation2d(rect.left - clear, rect.bottom - clear),
          Translation2d(rect.right + clear, rect.bottom - clear)
        ),
        (
          Translation2d(rect.left - clear, rect.top + clear),
          Translation2d(rect.left - clear, rect.bottom - clear)
        ),
        (
          Translation2d(rect.right + clear, rect.top + clear),
          Translation2d(rect.right + clear, rect.bottom - clear)
        ),
      ];

      for (final detourPair in twoPointDetours) {
        final d1 = Translation2d(
          detourPair.$1.x.clamp(minPos.x + 0.05, maxPos.x - 0.05),
          detourPair.$1.y.clamp(minPos.y + 0.05, maxPos.y - 0.05),
        );
        final d2 = Translation2d(
          detourPair.$2.x.clamp(minPos.x + 0.05, maxPos.x - 0.05),
          detourPair.$2.y.clamp(minPos.y + 0.05, maxPos.y - 0.05),
        );

        final candidate = basePath.duplicate(basePath.name);
        while (candidate.waypoints.length < 4) {
          candidate.insertWaypointAfter(candidate.waypoints.length - 2);
        }

        final idxA = 1;
        final idxB = candidate.waypoints.length - 2;
        candidate.waypoints[idxA].move(d1.x, d1.y);
        candidate.waypoints[idxB].move(d2.x, d2.y);
        seeds.add(candidate);
      }
    }

    return seeds;
  }

  static List<PathPlannerPath> _buildReferenceSeedPaths(
    PathPlannerPath basePath,
    List<Translation2d> referencePath,
    double adherence,
    Translation2d minPos,
    Translation2d maxPos,
  ) {
    if (referencePath.length < 4 ||
        adherence < 0.45 ||
        basePath.waypoints.length < 2) {
      return const [];
    }

    final out = <PathPlannerPath>[];
    final baseCount = basePath.waypoints.length;
    final targetCount = max(
      baseCount,
      min(18, max(6, (referencePath.length / 2).round())),
    );
    final candidateCounts = <int>{
      targetCount,
      max(baseCount, targetCount - 2),
      min(18, targetCount + 2),
    };

    for (final count in candidateCounts) {
      if (count < 2) continue;

      final candidate = basePath.duplicate(basePath.name);
      while (candidate.waypoints.length < count) {
        candidate.insertWaypointAfter(candidate.waypoints.length - 2);
      }
      while (candidate.waypoints.length > count) {
        candidate.waypoints.removeAt(candidate.waypoints.length - 2);
      }

      final refSamples =
          _sampleReferencePolylineByProgress(referencePath, count);
      for (int i = 1; i < count - 1; i++) {
        final p = refSamples[i];
        final clamped = Translation2d(
          p.x.clamp(minPos.x + 0.02, maxPos.x - 0.02),
          p.y.clamp(minPos.y + 0.02, maxPos.y - 0.02),
        );
        candidate.waypoints[i].move(clamped.x, clamped.y);
      }

      out.add(candidate);
    }

    return out;
  }

  static List<Translation2d> _sampleReferencePolylineByProgress(
    List<Translation2d> referencePath,
    int sampleCount,
  ) {
    if (sampleCount <= 1 || referencePath.length < 2) {
      return [referencePath.first];
    }

    final cumulativeLengths = <num>[0.0];
    num totalLength = 0.0;
    for (int i = 1; i < referencePath.length; i++) {
      totalLength += referencePath[i - 1].getDistance(referencePath[i]);
      cumulativeLengths.add(totalLength);
    }

    if (totalLength <= 1.0e-9) {
      return List<Translation2d>.filled(sampleCount, referencePath.first);
    }

    final out = <Translation2d>[];
    for (int i = 0; i < sampleCount; i++) {
      final t = i / (sampleCount - 1);
      final targetLength = totalLength * t;

      int seg = 1;
      while (seg < cumulativeLengths.length &&
          cumulativeLengths[seg] < targetLength) {
        seg++;
      }

      if (seg >= cumulativeLengths.length) {
        out.add(referencePath.last);
        continue;
      }

      final segStartLen = cumulativeLengths[seg - 1];
      final segEndLen = cumulativeLengths[seg];
      final segLen = max(1.0e-9, segEndLen - segStartLen);
      final localT = ((targetLength - segStartLen) / segLen).clamp(0.0, 1.0);

      final a = referencePath[seg - 1];
      final b = referencePath[seg];
      out.add(Translation2d(
        a.x + ((b.x - a.x) * localT),
        a.y + ((b.y - a.y) * localT),
      ));
    }

    return out;
  }

  static List<Translation2d> _prepareReferencePath(
    List<Translation2d> rawReference,
    Translation2d fixedStart,
    Translation2d fixedEnd,
    Translation2d minPos,
    Translation2d maxPos,
  ) {
    if (rawReference.length < 2) {
      return rawReference;
    }

    final deduped = <Translation2d>[];
    for (final point in rawReference) {
      if (deduped.isEmpty || deduped.last.getDistance(point) > 1.0e-4) {
        deduped.add(point);
      }
    }

    if (deduped.length < 2) {
      return [fixedStart, fixedEnd];
    }

    final resampleCount = max(40, min(240, deduped.length * 3));
    var processed = _sampleReferencePolylineByProgress(deduped, resampleCount);

    for (int pass = 0; pass < 2; pass++) {
      final smoothed = <Translation2d>[processed.first];
      for (int i = 1; i < processed.length - 1; i++) {
        final prev = processed[i - 1];
        final curr = processed[i];
        final next = processed[i + 1];
        smoothed.add(Translation2d(
          (prev.x * 0.2) + (curr.x * 0.6) + (next.x * 0.2),
          (prev.y * 0.2) + (curr.y * 0.6) + (next.y * 0.2),
        ));
      }
      smoothed.add(processed.last);
      processed = smoothed;
    }

    final clamped = <Translation2d>[];
    for (final point in processed) {
      clamped.add(Translation2d(
        point.x.clamp(minPos.x + 0.01, maxPos.x - 0.01),
        point.y.clamp(minPos.y + 0.01, maxPos.y - 0.01),
      ));
    }

    if (clamped.isEmpty) {
      return [fixedStart, fixedEnd];
    }

    clamped[0] = fixedStart;
    clamped[clamped.length - 1] = fixedEnd;
    return clamped;
  }

  static bool _segmentIntersectsInflatedBoundary(
    Translation2d a,
    Translation2d b,
    OptimizationBoundary boundary,
    double inflate,
  ) {
    final dist = a.getDistance(b);
    if (dist <= 0.0) {
      return boundary.containsPoint(a, inflate: inflate);
    }

    final steps = max(1, (dist / 0.04).ceil());
    for (int i = 0; i <= steps; i++) {
      final t = i / steps;
      final p = Translation2d(
        a.x + ((b.x - a.x) * t),
        a.y + ((b.y - a.y) * t),
      );
      if (boundary.containsPoint(p, inflate: inflate)) {
        return true;
      }
    }

    return false;
  }
}

class OptimizationResult {
  final PathPlannerPath path;
  final num runtime;
  final int generation;
  final num score;

  const OptimizationResult(this.path, this.runtime, this.generation,
      {this.score = double.infinity});

  OptimizationResult withGeneration(int gen) {
    return OptimizationResult(path, runtime, gen, score: score);
  }
}

class _Individual {
  final PathPlannerPath path;
  final RobotConfig config;
  final Translation2d fixedStart;
  final Translation2d fixedEnd;
  late final num fieldViolation;
  late final num boundaryViolation;
  late final num trajectoryRuntime;
  late final num runtimePenalty;
  late final num lengthPenalty;
  late final num smoothnessPenalty;
  late final num sharpCornerPenalty;
  late final num referencePenalty;
  late final num objective;
  final Translation2d minPos;
  final Translation2d maxPos;
  final bool preventFieldExit;
  final List<OptimizationBoundary> forbiddenBoundaries;
  final double robotRadius;
  final List<Translation2d> optimizationReferencePath;
  final double optimizationReferenceAdherence;

  bool get isFeasible =>
      fieldViolation <= 1.0e-9 &&
      boundaryViolation <= 1.0e-9 &&
      trajectoryRuntime.isFinite &&
      trajectoryRuntime > 0.0;

  num get feasibleRuntime => isFeasible ? trajectoryRuntime : double.infinity;

  _Individual(
      this.path,
      this.config,
      this.fixedStart,
      this.fixedEnd,
      this.minPos,
      this.maxPos,
      this.preventFieldExit,
      this.forbiddenBoundaries,
      this.robotRadius,
      this.optimizationReferencePath,
      this.optimizationReferenceAdherence) {
    _lockEndpoints();
    path.generatePathPoints();

    num computedFieldViolation = 0.0;
    if (preventFieldExit) {
      for (PathPoint p in path.pathPoints) {
        computedFieldViolation += _fieldExitDistancePenalty(p.position);
      }
    }
    fieldViolation = computedFieldViolation;

    num computedBoundaryViolation = _splineBoundaryViolation();
    boundaryViolation = computedBoundaryViolation;

    num runtime = double.infinity;
    try {
      runtime = PathPlannerTrajectory(path: path, robotConfig: config)
          .getTotalTimeSeconds();
    } catch (_) {
      runtime = double.infinity;
    }
    trajectoryRuntime = runtime;
    runtimePenalty =
        (!trajectoryRuntime.isFinite || trajectoryRuntime <= 0.0) ? 1.0e7 : 0.0;

    lengthPenalty = _pathLengthPenalty();
    smoothnessPenalty = _smoothnessPenalty();
    sharpCornerPenalty = _sharpCornerPenalty();
    referencePenalty = _referencePathPenalty();
    final referenceWeight = _referencePenaltyWeight();
    final smoothnessWeight = _smoothnessPenaltyWeight();
    final sharpCornerWeight = _sharpCornerPenaltyWeight();

    if (isFeasible) {
      objective = trajectoryRuntime +
          runtimePenalty +
          (lengthPenalty * 0.10) +
          (smoothnessPenalty * smoothnessWeight) +
          (sharpCornerPenalty * sharpCornerWeight) +
          (referencePenalty * referenceWeight);
    } else {
      objective = 1.0e9 +
          runtimePenalty +
          (fieldViolation * 1.0e6) +
          (boundaryViolation * 2.0e6) +
          (lengthPenalty * 0.10) +
          (smoothnessPenalty * smoothnessWeight) +
          (sharpCornerPenalty * sharpCornerWeight) +
          (referencePenalty * referenceWeight);
    }
  }

  _Individual duplicateForEvolution() {
    return _Individual(
      path.duplicate(path.name),
      config,
      fixedStart,
      fixedEnd,
      minPos,
      maxPos,
      preventFieldExit,
      forbiddenBoundaries,
      robotRadius,
      optimizationReferencePath,
      optimizationReferenceAdherence,
    );
  }

  static int compare(_Individual a, _Individual b) {
    if (a.isFeasible != b.isFeasible) {
      return a.isFeasible ? -1 : 1;
    }

    return a.objective.compareTo(b.objective);
  }

  static int compareResult(_Individual candidate, OptimizationResult current) {
    final currentFeasible = current.score < 1.0e9;

    if (candidate.isFeasible != currentFeasible) {
      return candidate.isFeasible ? -1 : 1;
    }

    return candidate.objective.compareTo(current.score);
  }

  _Individual crossover(_Individual parent2) {
    int childCount = min(path.waypoints.length, parent2.path.waypoints.length);
    childCount = max(childCount, 2);

    List<Waypoint> childWaypoints = [];
    for (int i = 0; i < childCount; i++) {
      double prob = Random().nextDouble();

      if (prob < 0.3) {
        childWaypoints.add(path.waypoints[i].clone());
      } else if (prob < 0.6) {
        childWaypoints.add(parent2.path.waypoints[i].clone());
      } else {
        childWaypoints.add(
            mutate(path.waypoints[i], i, path.waypoints.length, scale: 1.0));
      }
    }

    PathPlannerPath offspringPath = path.duplicate(path.name);
    while (offspringPath.waypoints.length > childCount) {
      offspringPath.waypoints.removeAt(offspringPath.waypoints.length - 2);
    }
    while (offspringPath.waypoints.length < childCount) {
      offspringPath.insertWaypointAfter(offspringPath.waypoints.length - 2);
    }
    offspringPath.waypoints = childWaypoints;
    return _Individual(
      offspringPath,
      config,
      fixedStart,
      fixedEnd,
      minPos,
      maxPos,
      preventFieldExit,
      forbiddenBoundaries,
      robotRadius,
      optimizationReferencePath,
      optimizationReferenceAdherence,
    );
  }

  num _referencePenaltyWeight() {
    final adherence = optimizationReferenceAdherence.clamp(0.0, 1.0);
    if (adherence <= 0.0) {
      return 0.0;
    }

    return adherence * adherence * 120.0;
  }

  num _smoothnessPenaltyWeight() {
    final adherence = optimizationReferenceAdherence.clamp(0.0, 1.0);
    return 0.35 + (adherence * 0.55);
  }

  num _sharpCornerPenaltyWeight() {
    final adherence = optimizationReferenceAdherence.clamp(0.0, 1.0);
    return 1.1 + (adherence * 0.6);
  }

  void _lockEndpoints() {
    if (path.waypoints.length < 2) return;
    path.waypoints.first.move(fixedStart.x, fixedStart.y);
    path.waypoints.last.move(fixedEnd.x, fixedEnd.y);
  }

  num _segmentBoundaryPenalty(Translation2d a, Translation2d b,
      OptimizationBoundary boundary, double inflate) {
    final num dist = a.getDistance(b);
    if (dist <= 0.0) {
      return boundary.containsPoint(a, inflate: inflate) ? 1.0 : 0.0;
    }

    final steps = max(1, (dist / 0.04).ceil());
    num hits = 0.0;
    for (int i = 0; i <= steps; i++) {
      final t = i / steps;
      final p = Translation2d(
        a.x + ((b.x - a.x) * t),
        a.y + ((b.y - a.y) * t),
      );

      if (boundary.containsPoint(p, inflate: inflate)) {
        hits += 1.0;
      }
    }

    return hits / (steps + 1);
  }

  num _splineBoundaryViolation() {
    if (forbiddenBoundaries.isEmpty || path.waypoints.length < 2) {
      return 0.0;
    }

    num violation = 0.0;
    final maxPos = (path.waypoints.length - 1).toDouble();
    const sampleStep = 0.01;

    Translation2d? prev;
    for (double pos = 0.0; pos <= maxPos; pos += sampleStep) {
      final current = path.samplePath(pos);

      for (final boundary in forbiddenBoundaries) {
        final inflation = robotRadius + boundary.tolerance;

        if (boundary.containsPoint(current, inflate: inflation)) {
          violation += 1.0;
        }

        if (prev != null) {
          violation +=
              _segmentBoundaryPenalty(prev, current, boundary, inflation);
        }
      }

      prev = current;
    }

    final endPoint = path.samplePath(maxPos);
    if (prev != null) {
      for (final boundary in forbiddenBoundaries) {
        final inflation = robotRadius + boundary.tolerance;
        if (boundary.containsPoint(endPoint, inflate: inflation)) {
          violation += 1.0;
        }
        violation +=
            _segmentBoundaryPenalty(prev, endPoint, boundary, inflation);
      }
    }

    return violation;
  }

  num _fieldExitDistancePenalty(Translation2d p) {
    num penalty = 0.0;

    if (p.x < minPos.x) {
      penalty += (minPos.x - p.x);
    } else if (p.x > maxPos.x) {
      penalty += (p.x - maxPos.x);
    }

    if (p.y < minPos.y) {
      penalty += (minPos.y - p.y);
    } else if (p.y > maxPos.y) {
      penalty += (p.y - maxPos.y);
    }

    return penalty;
  }

  num _pathLengthPenalty() {
    if (path.pathPoints.length < 2) {
      return 0.0;
    }

    num length = 0.0;
    for (int i = 1; i < path.pathPoints.length; i++) {
      length += path.pathPoints[i - 1].position
          .getDistance(path.pathPoints[i].position);
    }

    return length;
  }

  num _smoothnessPenalty() {
    if (path.pathPoints.length < 3) {
      return 0.0;
    }

    num penalty = 0.0;
    for (int i = 1; i < path.pathPoints.length - 1; i++) {
      final prev = path.pathPoints[i - 1].position;
      final curr = path.pathPoints[i].position;
      final next = path.pathPoints[i + 1].position;

      final h1 = (curr - prev).angle.radians;
      final h2 = (next - curr).angle.radians;
      final delta = _wrapAngleRadians(h2 - h1).abs();
      penalty += delta;
    }

    return penalty;
  }

  num _sharpCornerPenalty() {
    if (path.pathPoints.length < 3) {
      return 0.0;
    }

    num penalty = 0.0;
    for (int i = 1; i < path.pathPoints.length - 1; i++) {
      final prev = path.pathPoints[i - 1].position;
      final curr = path.pathPoints[i].position;
      final next = path.pathPoints[i + 1].position;

      final seg1 = curr - prev;
      final seg2 = next - curr;
      final len1 = seg1.norm;
      final len2 = seg2.norm;
      if (len1 <= 1.0e-6 || len2 <= 1.0e-6) {
        continue;
      }

      final h1 = seg1.angle.radians;
      final h2 = seg2.angle.radians;
      final delta = _wrapAngleRadians(h2 - h1).abs();

      final excess = max(0.0, delta - 0.55);
      final localLength = max(0.08, min(len1, len2));
      final localScale = 1.0 / localLength;

      penalty += (excess * excess) * localScale;
      if (delta > 1.20) {
        penalty += (delta - 1.20) * 4.0;
      }
    }

    return penalty;
  }

  num _referencePathPenalty() {
    if (optimizationReferencePath.length < 2 || path.pathPoints.isEmpty) {
      return 0.0;
    }

    return _progressAlignedReferencePenalty();
  }

  num _progressAlignedReferencePenalty() {
    final candidateCount = max(30, min(220, path.pathPoints.length * 2));
    final referenceCount =
        max(30, min(220, optimizationReferencePath.length * 4));
    final sampleCount = max(candidateCount, referenceCount);

    final candidateSamples = _sampleCandidatePathByProgress(sampleCount);
    final referenceSamples = PathOptimizer._sampleReferencePolylineByProgress(
      optimizationReferencePath,
      sampleCount,
    );

    if (candidateSamples.isEmpty || referenceSamples.isEmpty) {
      return 0.0;
    }

    num positionPenalty = 0.0;
    for (int i = 0; i < sampleCount; i++) {
      positionPenalty += candidateSamples[i].getDistance(referenceSamples[i]);
    }

    positionPenalty /= sampleCount;
    final directionPenalty =
        _directionAlignmentPenalty(candidateSamples, referenceSamples);

    return positionPenalty + (directionPenalty * 3.0);
  }

  num _directionAlignmentPenalty(
    List<Translation2d> candidateSamples,
    List<Translation2d> referenceSamples,
  ) {
    final segCount = min(candidateSamples.length, referenceSamples.length) - 1;
    if (segCount <= 0) {
      return 0.0;
    }

    num penalty = 0.0;
    int usedSegments = 0;
    for (int i = 0; i < segCount; i++) {
      final candVec = candidateSamples[i + 1] - candidateSamples[i];
      final refVec = referenceSamples[i + 1] - referenceSamples[i];

      final candMag = candVec.norm;
      final refMag = refVec.norm;
      if (candMag <= 1.0e-9 || refMag <= 1.0e-9) {
        continue;
      }

      final candUnit = candVec / candMag;
      final refUnit = refVec / refMag;
      final cosine =
          (candUnit.x * refUnit.x + candUnit.y * refUnit.y).clamp(-1.0, 1.0);

      penalty += (1.0 - cosine) * 0.5;
      usedSegments++;
    }

    if (usedSegments == 0) {
      return 0.0;
    }

    return penalty / usedSegments;
  }

  List<Translation2d> _sampleCandidatePathByProgress(int sampleCount) {
    if (sampleCount <= 1 || path.waypoints.length < 2) {
      return [path.waypoints.first.anchor];
    }

    final maxPos = (path.waypoints.length - 1).toDouble();
    final out = <Translation2d>[];
    for (int i = 0; i < sampleCount; i++) {
      final t = i / (sampleCount - 1);
      out.add(path.samplePath(maxPos * t));
    }

    return out;
  }

  num _wrapAngleRadians(num angle) {
    while (angle > pi) {
      angle -= 2 * pi;
    }
    while (angle < -pi) {
      angle += 2 * pi;
    }
    return angle;
  }

  static Waypoint mutate(Waypoint original, int index, int totalWaypoints,
      {double scale = 1.0}) {
    Waypoint mutated = original.clone();

    var rand = Random();

    final isStartOrEnd = index == 0 || index == totalWaypoints - 1;
    if (!isStartOrEnd) {
      final xDelta = (rand.nextDouble() - 0.5) * 0.7 * scale;
      final yDelta = (rand.nextDouble() - 0.5) * 0.7 * scale;
      mutated.move(mutated.anchor.x + xDelta, mutated.anchor.y + yDelta);
    }

    if (mutated.nextControl != null) {
      final nxDelta = (rand.nextDouble() - 0.5) * 1.2 * scale;
      final nyDelta = (rand.nextDouble() - 0.5) * 1.2 * scale;
      mutated.nextControl = Translation2d(
        mutated.nextControl!.x + nxDelta,
        mutated.nextControl!.y + nyDelta,
      );
    }

    if (mutated.prevControl != null) {
      final pxDelta = (rand.nextDouble() - 0.5) * 1.2 * scale;
      final pyDelta = (rand.nextDouble() - 0.5) * 1.2 * scale;
      mutated.prevControl = Translation2d(
        mutated.prevControl!.x + pxDelta,
        mutated.prevControl!.y + pyDelta,
      );
    }

    double theta = (rand.nextDouble() - 0.5) * 10.0 * scale;
    mutated.setHeading(mutated.heading + Rotation2d.fromDegrees(theta));

    if (mutated.prevControl != null) {
      double x = (rand.nextDouble() - 0.5) * 0.2 * scale;
      double prevLength = mutated.prevControlLength! + x;
      mutated.setPrevControlLength(prevLength);
    }

    if (mutated.nextControl != null) {
      double x = (rand.nextDouble() - 0.5) * 0.2 * scale;
      double nextLength = mutated.nextControlLength! + x;
      mutated.setNextControlLength(nextLength);
    }

    return mutated;
  }
}

class _OptimizerArgs {
  final PathPlannerPath path;
  final RobotConfig config;
  final Size fieldSizeMeters;
  final Size robotSizeMeters;

  const _OptimizerArgs(
      this.path, this.config, this.fieldSizeMeters, this.robotSizeMeters);
}
