import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:multi_split_view/multi_split_view.dart';
import 'package:pathplanner/path/constraints_zone.dart';
import 'package:pathplanner/path/event_marker.dart';
import 'package:pathplanner/path/field_constraints_profile.dart';
import 'package:pathplanner/path/path_constraints.dart';
import 'package:pathplanner/path/pathplanner_path.dart';
import 'package:pathplanner/path/point_towards_zone.dart';
import 'package:pathplanner/path/optimization_boundary.dart';
import 'package:pathplanner/path/rotation_target.dart';
import 'package:pathplanner/path/waypoint.dart';
import 'package:pathplanner/services/log.dart';
import 'package:pathplanner/services/pplib_telemetry.dart';
import 'package:pathplanner/trajectory/config.dart';
import 'package:pathplanner/trajectory/trajectory.dart';
import 'package:pathplanner/util/prefs.dart';
import 'package:pathplanner/util/wpimath/geometry.dart';
import 'package:pathplanner/widgets/dialogs/trajectory_render_dialog.dart';
import 'package:pathplanner/widgets/editor/path_painter.dart';
import 'package:pathplanner/widgets/editor/preview_seekbar.dart';
import 'package:pathplanner/widgets/editor/runtime_display.dart';
import 'package:pathplanner/widgets/editor/tree_widgets/path_tree.dart';
import 'package:pathplanner/widgets/editor/tree_widgets/waypoints_tree.dart';
import 'package:pathplanner/widgets/field_image.dart';
import 'package:pathplanner/util/path_painter_util.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:undo/undo.dart';

enum _BoundaryDragMode {
  draw,
  move,
  resize,
  rotate,
}

class SplitPathEditor extends StatefulWidget {
  final SharedPreferences prefs;
  final PathPlannerPath path;
  final FieldImage fieldImage;
  final FieldConstraintsProfile fieldProfile;
  final List<String> hiddenFieldZoneNames;
  final ChangeStack undoStack;
  final PPLibTelemetry? telemetry;
  final bool hotReload;
  final bool simulate;
  final VoidCallback? onPathChanged;

  const SplitPathEditor({
    required this.prefs,
    required this.path,
    required this.fieldImage,
    required this.fieldProfile,
    required this.hiddenFieldZoneNames,
    required this.undoStack,
    this.telemetry,
    this.hotReload = false,
    this.simulate = false,
    this.onPathChanged,
    super.key,
  });

  @override
  State<SplitPathEditor> createState() => _SplitPathEditorState();
}

class _SplitPathEditorState extends State<SplitPathEditor>
    with SingleTickerProviderStateMixin {
  final MultiSplitViewController _controller = MultiSplitViewController();
  final WaypointsTreeController _waypointsTreeController =
      WaypointsTreeController();
  int? _hoveredWaypoint;
  int? _selectedWaypoint;
  int? _hoveredZone;
  int? _selectedZone;
  int? _hoveredRotTarget;
  int? _selectedRotTarget;
  int? _hoveredPointZone;
  int? _selectedPointZone;
  int? _hoveredMarker;
  int? _selectedMarker;
  late bool _treeOnRight;
  late String _layoutPreset;
  Waypoint? _draggedPoint;
  Waypoint? _dragOldValue;
  int? _draggedRotationIdx;
  Translation2d? _draggedRotationPos;
  Rotation2d? _dragRotationOldValue;
  PathPlannerTrajectory? _simTraj;
  bool _paused = false;
  bool _treeCollapsed = false;
  late bool _holonomicMode;
  bool _boundaryDrawMode = false;
  bool _referencePathDrawMode = false;
  int? _selectedBoundaryIdx;
  _BoundaryDragMode? _boundaryDragMode;
  int? _boundaryResizeCorner;
  Translation2d? _boundaryDragStartPos;
  List<OptimizationBoundary>? _boundaryDragStartSnapshot;
  List<Translation2d> _referencePathDraft = [];

  PathPlannerPath? _optimizedPath;

  late Size _robotSize;
  late Translation2d _bumperOffset;
  late AnimationController _previewController;

  List<Waypoint> get waypoints => widget.path.waypoints;

  RuntimeDisplay? _runtimeDisplay;

  @override
  void initState() {
    super.initState();

    _previewController = AnimationController(vsync: this);

    _holonomicMode =
        widget.prefs.getBool(PrefsKeys.holonomicMode) ?? Defaults.holonomicMode;

    _treeOnRight =
        widget.prefs.getBool(PrefsKeys.treeOnRight) ?? Defaults.treeOnRight;
    _layoutPreset = widget.prefs.getString(PrefsKeys.editorLayoutPreset) ??
      Defaults.editorLayoutPreset;

    var width =
        widget.prefs.getDouble(PrefsKeys.robotWidth) ?? Defaults.robotWidth;
    var length =
        widget.prefs.getDouble(PrefsKeys.robotLength) ?? Defaults.robotLength;
    _robotSize = Size(width, length);
    _bumperOffset = Translation2d(
        widget.prefs.getDouble(PrefsKeys.bumperOffsetX) ??
            Defaults.bumperOffsetX,
        widget.prefs.getDouble(PrefsKeys.bumperOffsetY) ??
            Defaults.bumperOffsetY);

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

    WidgetsBinding.instance.addPostFrameCallback((_) => _simulatePath());
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
            child: GestureDetector(
              onTapDown: (details) {
                FocusScopeNode currentScope = FocusScope.of(context);
                if (!currentScope.hasPrimaryFocus && currentScope.hasFocus) {
                  FocusManager.instance.primaryFocus!.unfocus();
                }

                final tapPos = Translation2d(
                  _xPixelsToMeters(details.localPosition.dx),
                  _yPixelsToMeters(details.localPosition.dy),
                );

                int? boundaryHit;
                for (int i = widget.path.optimizationBoundaries.length - 1;
                    i >= 0;
                    i--) {
                  if (widget.path.optimizationBoundaries[i]
                      .containsPoint(tapPos)) {
                    boundaryHit = i;
                    break;
                  }
                }

                if (boundaryHit != null) {
                  setState(() {
                    _selectedBoundaryIdx = boundaryHit;
                  });
                  return;
                }

                for (int i = waypoints.length - 1; i >= 0; i--) {
                  Waypoint w = waypoints[i];
                  if (w.isPointInAnchor(
                          _xPixelsToMeters(details.localPosition.dx),
                          _yPixelsToMeters(details.localPosition.dy),
                          _pixelsToMeters(PathPainterUtil.uiPointSizeToPixels(
                              25, PathPainter.scale, widget.fieldImage))) ||
                      w.isPointInNextControl(
                          _xPixelsToMeters(details.localPosition.dx),
                          _yPixelsToMeters(details.localPosition.dy),
                          _pixelsToMeters(PathPainterUtil.uiPointSizeToPixels(
                              20, PathPainter.scale, widget.fieldImage))) ||
                      w.isPointInPrevControl(
                          _xPixelsToMeters(details.localPosition.dx),
                          _yPixelsToMeters(details.localPosition.dy),
                          _pixelsToMeters(PathPainterUtil.uiPointSizeToPixels(
                              20, PathPainter.scale, widget.fieldImage)))) {
                    _setSelectedWaypoint(i);
                    return;
                  }
                }
                _setSelectedWaypoint(null);
                setState(() {
                  _selectedBoundaryIdx = null;
                });
              },
              onDoubleTapDown: (details) {
                widget.undoStack.add(Change(
                  PathPlannerPath.cloneWaypoints(waypoints),
                  () {
                    setState(() {
                      widget.path.addWaypoint(Translation2d(
                          _xPixelsToMeters(details.localPosition.dx),
                          _yPixelsToMeters(details.localPosition.dy)));
                      widget.path.generateAndSavePath();
                    });
                    _simulatePath();
                  },
                  (oldValue) {
                    setState(() {
                      widget.path.waypoints =
                          PathPlannerPath.cloneWaypoints(oldValue);
                      _setSelectedWaypoint(null);
                      widget.path.generateAndSavePath();
                      _simulatePath();
                    });
                  },
                ));
              },
              onPanStart: (details) {
                double xPos = _xPixelsToMeters(details.localPosition.dx);
                double yPos = _yPixelsToMeters(details.localPosition.dy);

                final panStartPos = Translation2d(xPos, yPos);

                if (_referencePathDrawMode) {
                  setState(() {
                    _referencePathDraft = [panStartPos];
                    _optimizedPath = null;
                  });
                  return;
                }

                if (_boundaryDrawMode) {
                  final startSnapshot =
                      PathPlannerPath.cloneOptimizationBoundaries(
                          widget.path.optimizationBoundaries);
                  final newBoundary = OptimizationBoundary(
                    x: panStartPos.x.toDouble(),
                    y: panStartPos.y.toDouble(),
                    width: 0.05,
                    height: 0.05,
                    rotationDeg: 0.0,
                    tolerance: 0.0,
                  );
                  setState(() {
                    widget.path.optimizationBoundaries.add(newBoundary);
                    _selectedBoundaryIdx =
                        widget.path.optimizationBoundaries.length - 1;
                    _boundaryDragMode = _BoundaryDragMode.draw;
                    _boundaryDragStartPos = panStartPos;
                    _boundaryDragStartSnapshot = startSnapshot;
                    _boundaryDrawMode = false;
                    _optimizedPath = null;
                  });
                  return;
                }

                final boundaryInteraction = _hitTestBoundaryInteraction(
                  panStartPos,
                  _pixelsToMeters(PathPainterUtil.uiPointSizeToPixels(
                      20, PathPainter.scale, widget.fieldImage)),
                );

                if (boundaryInteraction != null) {
                  setState(() {
                    _selectedBoundaryIdx = boundaryInteraction.$1;
                    _boundaryDragMode = boundaryInteraction.$2;
                    _boundaryResizeCorner = boundaryInteraction.$3;
                    _boundaryDragStartPos = panStartPos;
                    _boundaryDragStartSnapshot =
                        PathPlannerPath.cloneOptimizationBoundaries(
                            widget.path.optimizationBoundaries);
                    _optimizedPath = null;
                  });
                  return;
                }

                for (int i = waypoints.length - 1; i >= 0; i--) {
                  Waypoint w = waypoints[i];
                  if (w.startDragging(
                      xPos,
                      yPos,
                      _pixelsToMeters(PathPainterUtil.uiPointSizeToPixels(
                          25, PathPainter.scale, widget.fieldImage)),
                      _pixelsToMeters(PathPainterUtil.uiPointSizeToPixels(
                          20, PathPainter.scale, widget.fieldImage)))) {
                    _draggedPoint = w;
                    _dragOldValue = w.clone();
                    break;
                  }
                }

                // Not dragging any waypoints, check rotations
                num dotRadius = _pixelsToMeters(
                    PathPainterUtil.uiPointSizeToPixels(
                        15, PathPainter.scale, widget.fieldImage));
                for (int i = 0; i < widget.path.pathPoints.length; i++) {
                  Rotation2d rotation;
                  Translation2d pos;
                  if (i == 0) {
                    rotation = widget.path.idealStartingState.rotation;
                    pos = widget.path.pathPoints.first.position;
                  } else if (i == widget.path.pathPoints.length - 1) {
                    rotation = widget.path.goalEndState.rotation;
                    pos = widget.path.pathPoints.last.position;
                  } else if (widget.path.pathPoints[i].rotationTarget != null) {
                    rotation =
                        widget.path.pathPoints[i].rotationTarget!.rotation;
                    pos = widget.path.pathPoints[i].position;
                  } else {
                    continue;
                  }

                  num dotX = pos.x +
                      (((_robotSize.height / 2) + _bumperOffset.x) *
                          rotation.cosine);
                  num dotY = pos.y +
                      (((_robotSize.height / 2) + _bumperOffset.x) *
                          rotation.sine);
                  if (pow(xPos - dotX, 2) + pow(yPos - dotY, 2) <
                      pow(dotRadius, 2)) {
                    if (i == 0) {
                      _draggedRotationIdx = -2;
                    } else if (i == widget.path.pathPoints.length - 2) {
                      _draggedRotationIdx = -1;
                    } else {
                      _draggedRotationIdx = widget.path.rotationTargets
                          .indexOf(widget.path.pathPoints[i].rotationTarget!);
                    }
                    _draggedRotationPos = pos;
                    _dragRotationOldValue = rotation;
                    return;
                  }
                }
              },
              onPanUpdate: (details) {
                if (_referencePathDrawMode && _referencePathDraft.isNotEmpty) {
                  _appendReferenceDraftPoint(Translation2d(
                    _xPixelsToMeters(details.localPosition.dx),
                    _yPixelsToMeters(details.localPosition.dy),
                  ));
                } else if (_boundaryDragMode != null &&
                    _selectedBoundaryIdx != null) {
                  _updateBoundaryDrag(
                    Translation2d(
                      _xPixelsToMeters(details.localPosition.dx),
                      _yPixelsToMeters(details.localPosition.dy),
                    ),
                  );
                } else if (_draggedPoint != null) {
                  num targetX = _xPixelsToMeters(min(
                      88 +
                          (widget.fieldImage.defaultSize.width *
                              PathPainter.scale),
                      max(8, details.localPosition.dx)));
                  num targetY = _yPixelsToMeters(min(
                      88 +
                          (widget.fieldImage.defaultSize.height *
                              PathPainter.scale),
                      max(8, details.localPosition.dy)));

                  bool snapSetting =
                      widget.prefs.getBool(PrefsKeys.snapToGuidelines) ??
                          Defaults.snapToGuidelines;
                  bool ctrlHeld = HardwareKeyboard.instance.logicalKeysPressed
                          .contains(LogicalKeyboardKey.controlLeft) ||
                      HardwareKeyboard.instance.logicalKeysPressed
                          .contains(LogicalKeyboardKey.controlRight);

                  bool shouldSnap = snapSetting ^ ctrlHeld;

                  if (shouldSnap && _draggedPoint!.isAnchorDragging) {
                    num? closestX;
                    num? closestY;

                    for (Waypoint w in waypoints) {
                      if (w != _draggedPoint) {
                        if (closestX == null ||
                            (targetX - w.anchor.x).abs() <
                                (targetX - closestX).abs()) {
                          closestX = w.anchor.x;
                        }

                        if (closestY == null ||
                            (targetY - w.anchor.y).abs() <
                                (targetY - closestY).abs()) {
                          closestY = w.anchor.y;
                        }
                      }
                    }

                    if (closestX != null && (targetX - closestX).abs() < 0.1) {
                      targetX = closestX;
                    }
                    if (closestY != null && (targetY - closestY).abs() < 0.1) {
                      targetY = closestY;
                    }
                  }

                  setState(() {
                    _draggedPoint!.dragUpdate(targetX, targetY);
                    widget.path.generatePathPoints();
                  });
                } else if (_draggedRotationIdx != null) {
                  Translation2d pos;
                  if (_draggedRotationIdx == -2) {
                    pos = widget.path.waypoints.first.anchor;
                  } else if (_draggedRotationIdx == -1) {
                    pos = widget.path.waypoints.last.anchor;
                  } else {
                    pos = _draggedRotationPos!;
                  }

                  double x = _xPixelsToMeters(details.localPosition.dx);
                  double y = _yPixelsToMeters(details.localPosition.dy);

                  setState(() {
                    if (_draggedRotationIdx == -2) {
                      widget.path.idealStartingState.rotation =
                          Rotation2d.fromComponents(x - pos.x, y - pos.y);
                    } else if (_draggedRotationIdx == -1) {
                      widget.path.goalEndState.rotation =
                          Rotation2d.fromComponents(x - pos.x, y - pos.y);
                    } else {
                      widget.path.rotationTargets[_draggedRotationIdx!]
                              .rotation =
                          Rotation2d.fromComponents(x - pos.x, y - pos.y);
                    }
                  });
                }
              },
              onPanEnd: (details) {
                if (_referencePathDrawMode) {
                  _commitReferencePathDraw();
                } else if (_boundaryDragMode != null) {
                  _commitBoundaryDrag();
                } else if (_draggedPoint != null) {
                  _draggedPoint!.stopDragging();
                  int index = waypoints.indexOf(_draggedPoint!);
                  Waypoint dragEnd = _draggedPoint!.clone();
                  widget.undoStack.add(Change(
                    _dragOldValue,
                    () {
                      setState(() {
                        if (waypoints[index] != _draggedPoint) {
                          waypoints[index] = dragEnd.clone();
                        }
                        widget.path.generateAndSavePath();
                        _simulatePath();
                        widget.onPathChanged?.call();
                      });
                      if (widget.hotReload) {
                        widget.telemetry?.hotReloadPath(widget.path);
                      }
                    },
                    (oldValue) {
                      setState(() {
                        waypoints[index] = oldValue!.clone();
                        widget.path.generateAndSavePath();
                        _simulatePath();
                        widget.onPathChanged?.call();
                      });
                      if (widget.hotReload) {
                        widget.telemetry?.hotReloadPath(widget.path);
                      }
                    },
                  ));
                  _draggedPoint = null;
                } else if (_draggedRotationIdx != null) {
                  if (_draggedRotationIdx == -2) {
                    final endRotation = widget.path.idealStartingState.rotation;
                    widget.undoStack.add(Change(
                      _dragRotationOldValue,
                      () {
                        setState(() {
                          widget.path.idealStartingState.rotation = endRotation;
                          widget.path.generateAndSavePath();
                          _simulatePath();
                          widget.onPathChanged?.call();
                        });
                      },
                      (oldValue) {
                        setState(() {
                          widget.path.idealStartingState.rotation = oldValue!;
                          widget.path.generateAndSavePath();
                          _simulatePath();
                          widget.onPathChanged?.call();
                        });
                      },
                    ));
                  } else if (_draggedRotationIdx == -1) {
                    final endRotation = widget.path.goalEndState.rotation;
                    widget.undoStack.add(Change(
                      _dragRotationOldValue,
                      () {
                        setState(() {
                          widget.path.goalEndState.rotation = endRotation;
                          widget.path.generateAndSavePath();
                          _simulatePath();
                          widget.onPathChanged?.call();
                        });
                      },
                      (oldValue) {
                        setState(() {
                          widget.path.goalEndState.rotation = oldValue!;
                          widget.path.generateAndSavePath();
                          _simulatePath();
                          widget.onPathChanged?.call();
                        });
                      },
                    ));
                  } else {
                    int rotationIdx = _draggedRotationIdx!;
                    final endRotation =
                        widget.path.rotationTargets[rotationIdx].rotation;
                    widget.undoStack.add(Change(
                      _dragRotationOldValue,
                      () {
                        setState(() {
                          widget.path.rotationTargets[rotationIdx].rotation =
                              endRotation;
                          widget.path.generateAndSavePath();
                          _simulatePath();
                          widget.onPathChanged?.call();
                        });
                      },
                      (oldValue) {
                        setState(() {
                          widget.path.rotationTargets[rotationIdx].rotation =
                              oldValue!;
                          widget.path.generateAndSavePath();
                          _simulatePath();
                          widget.onPathChanged?.call();
                        });
                      },
                    ));
                  }
                  _draggedRotationIdx = null;
                  _draggedRotationPos = null;
                }
              },
              child: Padding(
                padding: const EdgeInsets.all(48),
                child: Stack(
                  children: [
                    widget.fieldImage.getWidget(),
                    Positioned.fill(
                      child: CustomPaint(
                        painter: PathPainter(
                          colorScheme: colorScheme,
                          paths: [widget.path],
                          fieldObjects: widget.fieldProfile.objects,
                          fieldZones: widget.fieldProfile.zones,
                          hiddenFieldZoneNames:
                              widget.hiddenFieldZoneNames.toSet(),
                          simple: false,
                          fieldImage: widget.fieldImage,
                          hoveredWaypoint: _hoveredWaypoint,
                          selectedWaypoint: _selectedWaypoint,
                          hoveredZone: _hoveredZone,
                          selectedZone: _selectedZone,
                          hoveredPointZone: _hoveredPointZone,
                          selectedPointZone: _selectedPointZone,
                          hoveredRotTarget: _hoveredRotTarget,
                          selectedRotTarget: _selectedRotTarget,
                          hoveredMarker: _hoveredMarker,
                          selectedMarker: _selectedMarker,
                          simulatedPath: _simTraj,
                          animation: _previewController.view,
                          prefs: widget.prefs,
                          optimizedPath: _optimizedPath,
                          selectedBoundary: _selectedBoundaryIdx,
                          boundaryDrawMode: _boundaryDrawMode,
                          referencePath: widget.path.optimizationReferencePath,
                          referencePathDrawMode: _referencePathDrawMode,
                          drawingReferencePathPoints: _referencePathDraft,
                        ),
                      ),
                    ),
                  ],
                ),
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
                  totalPathTime: _simTraj?.states.last.timeSeconds ?? 1.0,
                ),
              if (!_treeCollapsed)
                Card(
                  margin: const EdgeInsets.all(0),
                  elevation: 2.0,
                  color: colorScheme.surface,
                  surfaceTintColor: colorScheme.surfaceTint,
                  child: Padding(
                    padding: const EdgeInsets.all(4.0),
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        return _buildResponsiveTreeScale(
                          constraints.maxWidth,
                          PathTree(
                            path: widget.path,
                            pathRuntime: _simTraj?.getTotalTimeSeconds(),
                            runtimeDisplay: _runtimeDisplay,
                            initiallySelectedWaypoint: _selectedWaypoint,
                            initiallySelectedZone: _selectedZone,
                            initiallySelectedRotTarget: _selectedRotTarget,
                            initiallySelectedPointZone: _selectedPointZone,
                            initiallySelectedMarker: _selectedMarker,
                            waypointsTreeController: _waypointsTreeController,
                            undoStack: widget.undoStack,
                            holonomicMode: _holonomicMode,
                            defaultConstraints: _getDefaultConstraints(),
                            prefs: widget.prefs,
                            fieldSizeMeters:
                                widget.fieldImage.getFieldSizeMeters(),
                            alwaysFieldObjects:
                              widget.fieldProfile.objectBoundaries(),
                            onRenderPath: () {
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
                            onPathChanged: () {
                              setState(() {
                                widget.path.generateAndSavePath();
                                _simulatePath();
                              });

                              if (widget.hotReload) {
                                widget.telemetry?.hotReloadPath(widget.path);
                              }

                              widget.onPathChanged?.call();
                            },
                            onPathChangedNoSim: () {
                              setState(() {
                                widget.path.generateAndSavePath();
                              });

                              if (widget.hotReload) {
                                widget.telemetry?.hotReloadPath(widget.path);
                              }

                              widget.onPathChanged?.call();
                            },
                            onWaypointDeleted: (waypointIdx) {
                      widget.undoStack.add(Change(
                        [
                          PathPlannerPath.cloneWaypoints(widget.path.waypoints),
                          PathPlannerPath.cloneConstraintZones(
                              widget.path.constraintZones),
                          PathPlannerPath.cloneEventMarkers(
                              widget.path.eventMarkers),
                          PathPlannerPath.cloneRotationTargets(
                              widget.path.rotationTargets),
                          PathPlannerPath.clonePointTowardsZones(
                              widget.path.pointTowardsZones),
                        ],
                        () {
                          setState(() {
                            _selectedWaypoint = null;
                            _hoveredWaypoint = null;
                            _waypointsTreeController.setSelectedWaypoint(null);

                            Waypoint w =
                                widget.path.waypoints.removeAt(waypointIdx);

                            if (w.isEndPoint) {
                              waypoints[widget.path.waypoints.length - 1]
                                  .nextControl = null;
                            } else if (w.isStartPoint) {
                              waypoints[0].prevControl = null;
                            }

                            for (ConstraintsZone zone
                                in widget.path.constraintZones) {
                              zone.minWaypointRelativePos =
                                  _adjustDeletedWaypointRelativePos(
                                      zone.minWaypointRelativePos, waypointIdx);
                              zone.maxWaypointRelativePos =
                                  _adjustDeletedWaypointRelativePos(
                                      zone.maxWaypointRelativePos, waypointIdx);
                            }

                            for (PointTowardsZone zone
                                in widget.path.pointTowardsZones) {
                              zone.minWaypointRelativePos =
                                  _adjustDeletedWaypointRelativePos(
                                      zone.minWaypointRelativePos, waypointIdx);
                              zone.maxWaypointRelativePos =
                                  _adjustDeletedWaypointRelativePos(
                                      zone.maxWaypointRelativePos, waypointIdx);
                            }

                            for (EventMarker m in widget.path.eventMarkers) {
                              m.waypointRelativePos =
                                  _adjustDeletedWaypointRelativePos(
                                      m.waypointRelativePos, waypointIdx);
                            }

                            for (RotationTarget t
                                in widget.path.rotationTargets) {
                              t.waypointRelativePos =
                                  _adjustDeletedWaypointRelativePos(
                                      t.waypointRelativePos, waypointIdx);
                            }

                            widget.path.generateAndSavePath();
                            _simulatePath();
                          });
                        },
                        (oldValue) {
                          setState(() {
                            _selectedWaypoint = null;
                            _hoveredWaypoint = null;
                            _waypointsTreeController.setSelectedWaypoint(null);

                            widget.path.waypoints =
                                PathPlannerPath.cloneWaypoints(
                                    oldValue[0] as List<Waypoint>);
                            widget.path.constraintZones =
                                PathPlannerPath.cloneConstraintZones(
                                    oldValue[1] as List<ConstraintsZone>);
                            widget.path.eventMarkers =
                                PathPlannerPath.cloneEventMarkers(
                                    oldValue[2] as List<EventMarker>);
                            widget.path.rotationTargets =
                                PathPlannerPath.cloneRotationTargets(
                                    oldValue[3] as List<RotationTarget>);
                            widget.path.pointTowardsZones =
                                PathPlannerPath.clonePointTowardsZones(
                                    oldValue[4] as List<PointTowardsZone>);
                            widget.path.generateAndSavePath();
                            _simulatePath();
                          });
                        },
                      ));
                    },
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
                                    onStartBoundaryDraw: () {
                                      setState(() {
                                        _boundaryDrawMode = true;
                                        _referencePathDrawMode = false;
                                        _referencePathDraft = [];
                                        _selectedBoundaryIdx = null;
                                      });
                                    },
                                    onStartReferencePathDraw: () {
                                      setState(() {
                                        _referencePathDrawMode = true;
                                        _boundaryDrawMode = false;
                                        _boundaryDragMode = null;
                                        _selectedBoundaryIdx = null;
                                        _referencePathDraft = [];
                                        _optimizedPath = null;
                                      });
                                    },
                                    onClearReferencePath: () {
                                      setState(() {
                                        _referencePathDrawMode = false;
                                        _referencePathDraft = [];
                                        _optimizedPath = null;
                                      });
                                    },
                            onWaypointHovered: (value) {
                              setState(() {
                                _hoveredWaypoint = value;
                              });
                            },
                            onWaypointSelected: (value) {
                              setState(() {
                                _selectedWaypoint = value;
                              });
                            },
                            onZoneHovered: (value) {
                              setState(() {
                                _hoveredZone = value;
                              });
                            },
                            onZoneSelected: (value) {
                              setState(() {
                                _selectedZone = value;
                              });
                            },
                            onPointZoneHovered: (value) {
                              setState(() {
                                _hoveredPointZone = value;
                              });
                            },
                            onPointZoneSelected: (value) {
                              setState(() {
                                _selectedPointZone = value;
                              });
                            },
                            onRotTargetHovered: (value) {
                              setState(() {
                                _hoveredRotTarget = value;
                              });
                            },
                            onRotTargetSelected: (value) {
                              setState(() {
                                _selectedRotTarget = value;
                              });
                            },
                            onMarkerHovered: (value) {
                              setState(() {
                                _hoveredMarker = value;
                              });
                            },
                            onMarkerSelected: (value) {
                              setState(() {
                                _selectedMarker = value;
                              });
                            },
                            onOptimizationUpdate: (result) => setState(() {
                              _optimizedPath = result;
                            }),
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
      setState(() {
        _simTraj = PathPlannerTrajectory(
          path: widget.path,
          robotConfig: RobotConfig.fromPrefs(widget.prefs),
        );
        if (!(_simTraj?.getTotalTimeSeconds().isFinite ?? false)) {
          _simTraj = null;
        }

        // Update the RuntimeDisplay widget
        _runtimeDisplay = RuntimeDisplay(
          currentRuntime: _simTraj?.states.last.timeSeconds,
          previousRuntime: _runtimeDisplay?.currentRuntime,
        );
      });

      if (!_paused) {
        _previewController.stop();
        _previewController.reset();
      }

      if (_simTraj != null) {
        try {
          if (!_paused) {
            _previewController.stop();
            _previewController.reset();
            _previewController.duration = Duration(
                milliseconds:
                    (_simTraj!.states.last.timeSeconds * 1000).toInt());
            _previewController.repeat();
          } else if (_previewController.duration != null) {
            double prevTime = _previewController.value *
                (_previewController.duration!.inMilliseconds / 1000.0);
            _previewController.duration = Duration(
                milliseconds:
                    (_simTraj!.states.last.timeSeconds * 1000).toInt());
            double newPos = prevTime / _simTraj!.states.last.timeSeconds;
            _previewController.forward(from: newPos);
            _previewController.stop();
          }
        } catch (_) {
          _showGenerationFailedError();
        }
      } else {
        // Trajectory failed to generate. Notify the user
        _showGenerationFailedError();
      }
    }
  }

  void _showGenerationFailedError() {
    Log.warning('Failed to generate trajectory for path: ${widget.path.name}');
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Failed to generate trajectory. This is likely due to bad control point placement. Please adjust your control points to avoid kinks in the path.',
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

  num _adjustDeletedWaypointRelativePos(num pos, int deletedWaypointIdx) {
    if (pos >= deletedWaypointIdx + 1) {
      return pos - 1.0;
    } else if (pos >= deletedWaypointIdx) {
      int segment = pos.floor();
      double segmentPct = pos % 1.0;

      return max(
          (((segment - 0.5) + (segmentPct / 2.0)) * 20).round() / 20.0, 0.0);
    } else if (pos > deletedWaypointIdx - 1) {
      int segment = pos.floor();
      double segmentPct = pos % 1.0;

      return min(widget.path.waypoints.length - 1,
          ((segment + (0.5 * segmentPct)) * 20).round() / 20.0);
    }

    return pos;
  }

  (int, _BoundaryDragMode, int?)? _hitTestBoundaryInteraction(
      Translation2d posMeters, num handleRadiusMeters) {
    for (int i = widget.path.optimizationBoundaries.length - 1; i >= 0; i--) {
      final boundary = widget.path.optimizationBoundaries[i];

      final rotateHandle = boundary.rotationHandle();
      if (rotateHandle.getDistance(posMeters) <= handleRadiusMeters) {
        return (i, _BoundaryDragMode.rotate, null);
      }

      final corners = boundary.corners();
      for (int cornerIdx = 0; cornerIdx < corners.length; cornerIdx++) {
        final corner = corners[cornerIdx];
        if (corner.getDistance(posMeters) <= handleRadiusMeters) {
          return (i, _BoundaryDragMode.resize, cornerIdx);
        }
      }

      if (boundary.containsPoint(posMeters)) {
        return (i, _BoundaryDragMode.move, null);
      }
    }

    return null;
  }

  void _updateBoundaryDrag(Translation2d currentPos) {
    if (_selectedBoundaryIdx == null ||
        _boundaryDragMode == null ||
        _selectedBoundaryIdx! < 0 ||
        _selectedBoundaryIdx! >= widget.path.optimizationBoundaries.length) {
      return;
    }

    final boundary = widget.path.optimizationBoundaries[_selectedBoundaryIdx!];
    final snapshot = _boundaryDragStartSnapshot;
    final dragStartBoundary = (snapshot != null &&
            _selectedBoundaryIdx! < snapshot.length)
        ? snapshot[_selectedBoundaryIdx!]
        : boundary;
    final startPos = _boundaryDragStartPos;

    if (startPos == null) {
      return;
    }

    setState(() {
      switch (_boundaryDragMode!) {
        case _BoundaryDragMode.draw:
          final minX = min(startPos.x, currentPos.x);
          final minY = min(startPos.y, currentPos.y);
          final maxX = max(startPos.x, currentPos.x);
          final maxY = max(startPos.y, currentPos.y);
          boundary.x = minX.toDouble();
          boundary.y = minY.toDouble();
          boundary.width = max(0.05, maxX - minX).toDouble();
          boundary.height = max(0.05, maxY - minY).toDouble();
          boundary.rotationDeg = 0.0;
          break;
        case _BoundaryDragMode.move:
          final delta = currentPos - startPos;
          final center = boundary.center;
          boundary.setFromCenter(Translation2d(center.x + delta.x, center.y + delta.y));
          _boundaryDragStartPos = currentPos;
          break;
        case _BoundaryDragMode.resize:
          final cornerIdx = _boundaryResizeCorner;
          if (cornerIdx == null) {
            break;
          }

          final oppositeIdx = (cornerIdx + 2) % 4;
          final startCorners = dragStartBoundary.corners();
          final oppositeLocal = dragStartBoundary.toLocal(startCorners[oppositeIdx]);
          final currentLocal = dragStartBoundary.toLocal(currentPos);

          final newWidth = max(0.05, (currentLocal.x - oppositeLocal.x).abs());
          final newHeight = max(0.05, (currentLocal.y - oppositeLocal.y).abs());
          final newCenterLocal = Translation2d(
            (currentLocal.x + oppositeLocal.x) / 2.0,
            (currentLocal.y + oppositeLocal.y) / 2.0,
          );
          final newCenterWorld = dragStartBoundary.toWorld(newCenterLocal);

          boundary.width = newWidth.toDouble();
          boundary.height = newHeight.toDouble();
          boundary.rotationDeg = dragStartBoundary.rotationDeg;
          boundary.setFromCenter(newCenterWorld);
          break;
        case _BoundaryDragMode.rotate:
          final c = dragStartBoundary.center;
          final angle = atan2(currentPos.y - c.y, currentPos.x - c.x);
          boundary.rotationDeg = ((angle - (pi / 2.0)) * (180.0 / pi));
          break;
      }

      _optimizedPath = null;
    });
  }

  void _commitBoundaryDrag() {
    final oldSnapshot = _boundaryDragStartSnapshot;
    final newSnapshot =
        PathPlannerPath.cloneOptimizationBoundaries(widget.path.optimizationBoundaries);

    _boundaryDragMode = null;
    _boundaryResizeCorner = null;
    _boundaryDragStartPos = null;
    _boundaryDragStartSnapshot = null;

    if (oldSnapshot == null) {
      return;
    }

    widget.undoStack.add(Change(
      oldSnapshot,
      () {
        setState(() {
          widget.path.optimizationBoundaries =
              PathPlannerPath.cloneOptimizationBoundaries(newSnapshot);
          _optimizedPath = null;
        });
        widget.onPathChanged?.call();
      },
      (oldValue) {
        setState(() {
          widget.path.optimizationBoundaries =
              PathPlannerPath.cloneOptimizationBoundaries(oldValue);
          _optimizedPath = null;
        });
        widget.onPathChanged?.call();
      },
    ));
  }

  void _appendReferenceDraftPoint(Translation2d point) {
    if (_referencePathDraft.isEmpty) return;

    if (_referencePathDraft.last.getDistance(point) < 0.03) {
      return;
    }

    setState(() {
      _referencePathDraft.add(point);
    });
  }

  void _commitReferencePathDraw() {
    if (_referencePathDraft.length < 2) {
      setState(() {
        _referencePathDrawMode = false;
        _referencePathDraft = [];
      });
      return;
    }

    final oldReference = PathPlannerPath.cloneOptimizationReferencePath(
        widget.path.optimizationReferencePath);
    final newReference = PathPlannerPath.cloneOptimizationReferencePath(
      _referencePathDraft,
    );

    widget.undoStack.add(Change(
      oldReference,
      () {
        setState(() {
          widget.path.optimizationReferencePath =
              PathPlannerPath.cloneOptimizationReferencePath(newReference);
          _referencePathDrawMode = false;
          _referencePathDraft = [];
          _optimizedPath = null;
        });
        widget.onPathChanged?.call();
      },
      (oldValue) {
        setState(() {
          widget.path.optimizationReferencePath =
              PathPlannerPath.cloneOptimizationReferencePath(oldValue);
          _referencePathDrawMode = false;
          _referencePathDraft = [];
          _optimizedPath = null;
        });
        widget.onPathChanged?.call();
      },
    ));
  }

  void _setSelectedWaypoint(int? waypointIdx) {
    setState(() {
      _selectedWaypoint = waypointIdx;
    });

    _waypointsTreeController.setSelectedWaypoint(waypointIdx);
  }

  double _xPixelsToMeters(double pixels) {
    return (((pixels - 48) / PathPainter.scale) /
            widget.fieldImage.pixelsPerMeter) -
        widget.fieldImage.marginMeters;
  }

  double _yPixelsToMeters(double pixels) {
    return ((widget.fieldImage.defaultSize.height -
                ((pixels - 48) / PathPainter.scale)) /
            widget.fieldImage.pixelsPerMeter) -
        widget.fieldImage.marginMeters;
  }

  double _pixelsToMeters(double pixels) {
    return (pixels / PathPainter.scale) / widget.fieldImage.pixelsPerMeter;
  }

  PathConstraints _getDefaultConstraints() {
    return PathConstraints(
      maxVelocityMPS: widget.prefs.getDouble(PrefsKeys.defaultMaxVel) ??
          Defaults.defaultMaxVel,
      maxAccelerationMPSSq: widget.prefs.getDouble(PrefsKeys.defaultMaxAccel) ??
          Defaults.defaultMaxAccel,
      maxAngularVelocityDeg:
          widget.prefs.getDouble(PrefsKeys.defaultMaxAngVel) ??
              Defaults.defaultMaxAngVel,
      maxAngularAccelerationDeg:
          widget.prefs.getDouble(PrefsKeys.defaultMaxAngAccel) ??
              Defaults.defaultMaxAngAccel,
    );
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
