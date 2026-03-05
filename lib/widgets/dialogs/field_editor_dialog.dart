import 'dart:math';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:pathplanner/path/field_constraints_profile.dart';
import 'package:pathplanner/path/optimization_boundary.dart';
import 'package:pathplanner/util/path_painter_util.dart';
import 'package:pathplanner/util/wpimath/geometry.dart';
import 'package:pathplanner/widgets/field_image.dart';
import 'package:pathplanner/widgets/number_text_field.dart';

enum _DrawTargetType { object, zone }

enum _SelectionTargetType { object, zone }

enum _CanvasInteractionMode { draw, move, resize, rotate }

enum _CanvasControlMode { edit, navigate }

class FieldEditorDialog extends StatefulWidget {
  final FieldConstraintsProfile profile;
  final ValueChanged<FieldConstraintsProfile> onSaved;
  final Size fieldSizeMeters;
  final FieldImage? fieldImage;

  const FieldEditorDialog({
    super.key,
    required this.profile,
    required this.onSaved,
    required this.fieldSizeMeters,
    this.fieldImage,
  });

  @override
  State<FieldEditorDialog> createState() => _FieldEditorDialogState();
}

class _FieldEditorDialogState extends State<FieldEditorDialog> {
  late FieldConstraintsProfile _working;
  _DrawTargetType _drawTarget = _DrawTargetType.object;
  Offset? _drawStart;
  Rect? _draftRect;
  _SelectionTargetType? _selectedTargetType;
  int? _selectedBoundaryIndex;
  _CanvasInteractionMode? _interactionMode;
  int? _resizeCornerIndex;
  Translation2d? _interactionStartMeters;
  OptimizationBoundary? _interactionStartBoundary;
  late final TransformationController _canvasTransformController;
  _CanvasControlMode _canvasControlMode = _CanvasControlMode.edit;
  Size _canvasViewportSize = Size.zero;
  double _canvasViewScale = 1.0;

  @override
  void initState() {
    super.initState();
    _working = widget.profile.clone();
    _canvasTransformController = TransformationController();
    _canvasTransformController.addListener(_onCanvasTransformChanged);
  }

  @override
  void dispose() {
    _canvasTransformController.removeListener(_onCanvasTransformChanged);
    _canvasTransformController.dispose();
    super.dispose();
  }

  void _onCanvasTransformChanged() {
    final scale = _canvasTransformController.value.getMaxScaleOnAxis();
    if ((scale - _canvasViewScale).abs() > 0.001) {
      setState(() {
        _canvasViewScale = scale;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return AlertDialog(
      backgroundColor: colorScheme.surface,
      surfaceTintColor: colorScheme.surfaceTint,
      title: const Text('Field Editor (.ppx)'),
      content: SizedBox(
        width: 1150,
        height: 650,
        child: Row(
          children: [
            Expanded(
              flex: 7,
              child: _buildFieldCanvas(),
            ),
            const SizedBox(width: 10),
            Expanded(
              flex: 6,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextFormField(
                    initialValue: _working.fieldName,
                    decoration: const InputDecoration(labelText: 'Field Name'),
                    onChanged: (value) => _working.fieldName = value,
                  ),
                  const SizedBox(height: 10),
                  Expanded(
                    child: DefaultTabController(
                      length: 2,
                      child: Column(
                        children: [
                          const TabBar(
                            tabs: [
                              Tab(text: 'Objects (Always Active)'),
                              Tab(text: 'Zones (Visibility Controlled)'),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Expanded(
                            child: TabBarView(
                              children: [
                                _buildObjectsTab(),
                                _buildZonesTab(),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () {
            widget.onSaved(_working.clone());
            Navigator.of(context).pop();
          },
          child: const Text('Save'),
        ),
      ],
    );
  }

  Widget _buildFieldCanvas() {
    final colorScheme = Theme.of(context).colorScheme;

    return Card(
      elevation: 1,
      child: Padding(
        padding: const EdgeInsets.all(8.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                const Text('Draw: '),
                SegmentedButton<_DrawTargetType>(
                  showSelectedIcon: false,
                  selected: {_drawTarget},
                  segments: const [
                    ButtonSegment<_DrawTargetType>(
                      value: _DrawTargetType.object,
                      label: Text('Obstacle'),
                    ),
                    ButtonSegment<_DrawTargetType>(
                      value: _DrawTargetType.zone,
                      label: Text('Zone'),
                    ),
                  ],
                  onSelectionChanged: (selection) {
                    setState(() {
                      _drawTarget = selection.first;
                    });
                  },
                ),
                SegmentedButton<_CanvasControlMode>(
                  showSelectedIcon: false,
                  selected: {_canvasControlMode},
                  segments: const [
                    ButtonSegment<_CanvasControlMode>(
                      value: _CanvasControlMode.edit,
                      label: Text('Edit'),
                      icon: Icon(Icons.edit_outlined),
                    ),
                    ButtonSegment<_CanvasControlMode>(
                      value: _CanvasControlMode.navigate,
                      label: Text('Navigate'),
                      icon: Icon(Icons.pan_tool_outlined),
                    ),
                  ],
                  onSelectionChanged: (selection) {
                    setState(() {
                      _canvasControlMode = selection.first;
                    });
                  },
                ),
                IconButton(
                  tooltip: 'Zoom Out',
                  onPressed: () => _zoomFromCenter(1 / 1.15),
                  icon: const Icon(Icons.remove),
                ),
                IconButton(
                  tooltip: 'Zoom In',
                  onPressed: () => _zoomFromCenter(1.15),
                  icon: const Icon(Icons.add),
                ),
                IconButton(
                  tooltip: 'Reset View',
                  onPressed: () {
                    setState(() {
                      _canvasTransformController.value = Matrix4.identity();
                    });
                  },
                  icon: const Icon(Icons.center_focus_strong),
                ),
                Text(
                  _canvasControlMode == _CanvasControlMode.edit
                      ? 'Drag on field to create ${_drawTarget == _DrawTargetType.object ? 'obstacles' : 'zones'}'
                      : 'Pan and zoom the canvas',
                  style: TextStyle(color: colorScheme.onSurfaceVariant),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final fieldAspect = _canvasAspectRatio();
                  final maxWidth = constraints.maxWidth;
                  final maxHeight = constraints.maxHeight;
                  double width = maxWidth;
                  double height = width / fieldAspect;

                  if (height > maxHeight) {
                    height = maxHeight;
                    width = height * fieldAspect;
                  }

                  final canvasSize = Size(width, height);
                  _canvasViewportSize = canvasSize;

                  final isEditMode =
                      _canvasControlMode == _CanvasControlMode.edit;

                  return Center(
                    child: SizedBox(
                      width: width,
                      height: height,
                      child: ClipRect(
                        child: Listener(
                          onPointerSignal: (event) {
                            if (event is! PointerScrollEvent) return;
                            final zoomFactor = event.scrollDelta.dy < 0 ? 1.08 : 1 / 1.08;
                            _zoomAtViewportPoint(event.localPosition, zoomFactor);
                          },
                          child: InteractiveViewer(
                            transformationController: _canvasTransformController,
                            panEnabled: _canvasControlMode == _CanvasControlMode.navigate,
                            scaleEnabled:
                                _canvasControlMode == _CanvasControlMode.navigate,
                            constrained: false,
                            boundaryMargin: const EdgeInsets.all(500),
                            minScale: 0.35,
                            maxScale: 6.0,
                            trackpadScrollCausesScale: true,
                            child: SizedBox(
                              width: width,
                              height: height,
                              child: GestureDetector(
                                behavior: HitTestBehavior.opaque,
                                onTapDown: isEditMode
                                    ? (details) {
                                        final meters = _pixelsToMeters(
                                            details.localPosition, canvasSize);
                                        final hit = _hitTestBoundary(meters);
                                        setState(() {
                                          _selectedTargetType = hit?.$1;
                                          _selectedBoundaryIndex = hit?.$2;
                                        });
                                      }
                                    : null,
                                onPanStart: isEditMode
                                    ? (details) {
                                        final local = details.localPosition;
                                        final meters =
                                            _pixelsToMeters(local, canvasSize);

                                        final interaction = _hitTestInteraction(
                                          meters,
                                          _metersHandleRadius(canvasSize),
                                        );

                                        if (interaction != null) {
                                          final boundary = _selectedBoundary;
                                          if (boundary != null) {
                                            setState(() {
                                              _interactionMode = interaction.$1;
                                              _resizeCornerIndex = interaction.$2;
                                              _interactionStartMeters = meters;
                                              _interactionStartBoundary =
                                                  boundary.clone();
                                              _drawStart = null;
                                              _draftRect = null;
                                            });
                                          }
                                          return;
                                        }

                                        setState(() {
                                          _interactionMode =
                                              _CanvasInteractionMode.draw;
                                          _resizeCornerIndex = null;
                                          _interactionStartMeters = null;
                                          _interactionStartBoundary = null;
                                          _drawStart = local;
                                          _draftRect =
                                              Rect.fromPoints(local, local);
                                        });
                                      }
                                    : null,
                                onPanUpdate: isEditMode
                                    ? (details) {
                                        if (_interactionMode ==
                                            _CanvasInteractionMode.draw) {
                                          if (_drawStart == null) return;
                                          setState(() {
                                            _draftRect = Rect.fromPoints(
                                                _drawStart!,
                                                details.localPosition);
                                          });
                                          return;
                                        }

                                        if (_interactionMode != null) {
                                          _updateInteraction(
                                            _pixelsToMeters(
                                                details.localPosition,
                                                canvasSize),
                                          );
                                        }
                                      }
                                    : null,
                                onPanEnd: isEditMode
                                    ? (_) {
                                        if (_interactionMode ==
                                            _CanvasInteractionMode.draw) {
                                          _commitDraftBoundary(canvasSize);
                                        }
                                        setState(() {
                                          _interactionMode = null;
                                          _resizeCornerIndex = null;
                                          _interactionStartMeters = null;
                                          _interactionStartBoundary = null;
                                        });
                                      }
                                    : null,
                                onPanCancel: isEditMode
                                    ? () {
                                        setState(() {
                                          _drawStart = null;
                                          _draftRect = null;
                                          _interactionMode = null;
                                          _resizeCornerIndex = null;
                                          _interactionStartMeters = null;
                                          _interactionStartBoundary = null;
                                        });
                                      }
                                    : null,
                                child: Stack(
                                  fit: StackFit.expand,
                                  children: [
                                    Container(
                                      color: colorScheme.surfaceContainerHigh,
                                    ),
                                    if (widget.fieldImage != null)
                                      Positioned.fill(
                                        child: widget.fieldImage!.getWidget(),
                                      ),
                                    Positioned.fill(
                                      child: CustomPaint(
                                        painter: _FieldConstraintCanvasPainter(
                                          fieldSizeMeters: widget.fieldSizeMeters,
                                          fieldImage: widget.fieldImage,
                                          viewScale: _canvasViewScale,
                                          objects: _working.objects,
                                          zones: _working.zones,
                                          draftRect: _draftRect,
                                          selectedTargetType: _selectedTargetType,
                                          selectedBoundaryIndex:
                                              _selectedBoundaryIndex,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _commitDraftBoundary(Size canvasSize) {
    final draftRect = _draftRect;
    if (draftRect == null) {
      return;
    }

    final left = draftRect.left.clamp(0.0, canvasSize.width);
    final right = draftRect.right.clamp(0.0, canvasSize.width);
    final top = draftRect.top.clamp(0.0, canvasSize.height);
    final bottom = draftRect.bottom.clamp(0.0, canvasSize.height);

    final widthPx = (right - left).abs();
    final heightPx = (bottom - top).abs();
    if (widthPx < 6 || heightPx < 6) {
      setState(() {
        _drawStart = null;
        _draftRect = null;
      });
      return;
    }

    final bottomLeft = _pixelsToMeters(Offset(left, bottom), canvasSize);
    final topRight = _pixelsToMeters(Offset(right, top), canvasSize);

    final x = bottomLeft.x < topRight.x ? bottomLeft.x : topRight.x;
    final y = bottomLeft.y < topRight.y ? bottomLeft.y : topRight.y;
    final width = (topRight.x - bottomLeft.x).abs().clamp(0.05, 54.0);
    final height = (topRight.y - bottomLeft.y).abs().clamp(0.05, 27.0);

    final boundary = OptimizationBoundary(
      x: x.toDouble(),
      y: y.toDouble(),
      width: width.toDouble(),
      height: height.toDouble(),
      rotationDeg: 0.0,
      tolerance: 0.0,
    );

    setState(() {
      if (_drawTarget == _DrawTargetType.object) {
        _working.objects.add(
          FieldConstraintObject(
            name: 'Object ${_working.objects.length + 1}',
            boundary: boundary,
          ),
        );
      } else {
        _working.zones.add(
          FieldConstraintZone(
            name: 'Zone ${_working.zones.length + 1}',
            boundary: boundary,
            visibleByDefault: true,
          ),
        );
      }

      _drawStart = null;
      _draftRect = null;
    });
  }

  Translation2d _pixelsToMeters(Offset px, Size canvasSize) {
    final fieldImage = widget.fieldImage;
    if (fieldImage != null) {
      final scale = _fieldImageScale(canvasSize);
      final x = ((px.dx / scale) / fieldImage.pixelsPerMeter.toDouble()) -
          fieldImage.marginMeters.toDouble();
      final y = ((fieldImage.defaultSize.height - (px.dy / scale)) /
              fieldImage.pixelsPerMeter.toDouble()) -
          fieldImage.marginMeters.toDouble();

      return Translation2d(
        x.clamp(0.0, widget.fieldSizeMeters.width),
        y.clamp(0.0, widget.fieldSizeMeters.height),
      );
    }

    final fieldW = widget.fieldSizeMeters.width;
    final fieldH = widget.fieldSizeMeters.height;

    final x = (px.dx / canvasSize.width * fieldW).clamp(0.0, fieldW);
    final y = ((canvasSize.height - px.dy) / canvasSize.height * fieldH)
        .clamp(0.0, fieldH);
    return Translation2d(x, y);
  }

  OptimizationBoundary? get _selectedBoundary {
    if (_selectedTargetType == null || _selectedBoundaryIndex == null) {
      return null;
    }

    if (_selectedTargetType == _SelectionTargetType.object) {
      if (_selectedBoundaryIndex! < 0 ||
          _selectedBoundaryIndex! >= _working.objects.length) {
        return null;
      }
      return _working.objects[_selectedBoundaryIndex!].boundary;
    }

    if (_selectedBoundaryIndex! < 0 ||
        _selectedBoundaryIndex! >= _working.zones.length) {
      return null;
    }
    return _working.zones[_selectedBoundaryIndex!].boundary;
  }

  (_SelectionTargetType, int)? _hitTestBoundary(Translation2d posMeters) {
    for (int i = _working.objects.length - 1; i >= 0; i--) {
      if (_working.objects[i].boundary.containsPoint(posMeters)) {
        return (_SelectionTargetType.object, i);
      }
    }
    for (int i = _working.zones.length - 1; i >= 0; i--) {
      if (_working.zones[i].boundary.containsPoint(posMeters)) {
        return (_SelectionTargetType.zone, i);
      }
    }
    return null;
  }

  (_CanvasInteractionMode, int?)? _hitTestInteraction(
    Translation2d posMeters,
    num handleRadiusMeters,
  ) {
    final selected = _selectedBoundary;
    if (selected == null) return null;

    final rotateHandle = selected.rotationHandle();
    if (rotateHandle.getDistance(posMeters) <= handleRadiusMeters) {
      return (_CanvasInteractionMode.rotate, null);
    }

    final corners = selected.corners();
    for (int i = 0; i < corners.length; i++) {
      if (corners[i].getDistance(posMeters) <= handleRadiusMeters) {
        return (_CanvasInteractionMode.resize, i);
      }
    }

    if (selected.containsPoint(posMeters)) {
      return (_CanvasInteractionMode.move, null);
    }

    return null;
  }

  num _metersHandleRadius(Size canvasSize) {
    final fieldImage = widget.fieldImage;
    if (fieldImage != null) {
      final scale = _fieldImageScale(canvasSize);
      return 14.0 / (fieldImage.pixelsPerMeter.toDouble() * scale);
    }

    final metersPerPxX = widget.fieldSizeMeters.width / canvasSize.width;
    final metersPerPxY = widget.fieldSizeMeters.height / canvasSize.height;
    final metersPerPx = max(metersPerPxX, metersPerPxY);
    return metersPerPx * 14.0;
  }

  double _canvasAspectRatio() {
    final fieldImage = widget.fieldImage;
    if (fieldImage != null) {
      return fieldImage.defaultSize.width / fieldImage.defaultSize.height;
    }
    return widget.fieldSizeMeters.width / widget.fieldSizeMeters.height;
  }

  double _fieldImageScale(Size canvasSize) {
    final fieldImage = widget.fieldImage;
    if (fieldImage == null) return 1.0;
    return canvasSize.width / fieldImage.defaultSize.width;
  }

  void _zoomFromCenter(double factor) {
    if (_canvasViewportSize == Size.zero) return;
    _zoomAtViewportPoint(
      Offset(_canvasViewportSize.width / 2.0, _canvasViewportSize.height / 2.0),
      factor,
    );
  }

  void _zoomAtViewportPoint(Offset viewportPoint, double factor) {
    final currentScale = _canvasTransformController.value.getMaxScaleOnAxis();
    final nextScale = (currentScale * factor).clamp(0.35, 6.0);
    final scaleChange = nextScale / currentScale;
    if (scaleChange == 1.0) return;

    final scenePoint = _canvasTransformController.toScene(viewportPoint);
    final nextMatrix = _canvasTransformController.value.clone()
      ..translate(scenePoint.dx, scenePoint.dy)
      ..scale(scaleChange)
      ..translate(-scenePoint.dx, -scenePoint.dy);

    setState(() {
      _canvasTransformController.value = nextMatrix;
    });
  }

  void _updateInteraction(Translation2d currentMeters) {
    final mode = _interactionMode;
    final selected = _selectedBoundary;
    final startMeters = _interactionStartMeters;
    final startBoundary = _interactionStartBoundary;
    if (mode == null || selected == null || startMeters == null) return;

    setState(() {
      if (mode == _CanvasInteractionMode.move) {
        final delta = currentMeters - startMeters;
        final center = startBoundary?.center ?? selected.center;
        selected.setFromCenter(
          Translation2d(center.x + delta.x, center.y + delta.y),
        );
      } else if (mode == _CanvasInteractionMode.resize) {
        final base = startBoundary ?? selected;
        final cornerIdx = _resizeCornerIndex;
        if (cornerIdx == null) return;

        final oppositeIdx = (cornerIdx + 2) % 4;
        final startCorners = base.corners();
        final oppositeLocal = base.toLocal(startCorners[oppositeIdx]);
        final currentLocal = base.toLocal(currentMeters);

        final newWidth = max(0.05, (currentLocal.x - oppositeLocal.x).abs());
        final newHeight = max(0.05, (currentLocal.y - oppositeLocal.y).abs());
        final newCenterLocal = Translation2d(
          (currentLocal.x + oppositeLocal.x) / 2.0,
          (currentLocal.y + oppositeLocal.y) / 2.0,
        );
        final newCenterWorld = base.toWorld(newCenterLocal);

        selected.width = newWidth.toDouble();
        selected.height = newHeight.toDouble();
        selected.rotationDeg = base.rotationDeg;
        selected.setFromCenter(newCenterWorld);
      } else if (mode == _CanvasInteractionMode.rotate) {
        final base = startBoundary ?? selected;
        final center = base.center;
        final angle = atan2(
          currentMeters.y - center.y,
          currentMeters.x - center.x,
        );
        selected.rotationDeg = ((angle - (pi / 2.0)) * (180.0 / pi));
      }
    });
  }

  Widget _buildObjectsTab() {
    return Column(
      children: [
        Align(
          alignment: Alignment.centerRight,
          child: FilledButton.icon(
            onPressed: () {
              setState(() {
                _working.objects.add(
                  FieldConstraintObject(
                    name: 'Object ${_working.objects.length + 1}',
                    boundary: OptimizationBoundary(
                      x: widget.fieldSizeMeters.width * 0.35,
                      y: widget.fieldSizeMeters.height * 0.35,
                      width: 1.0,
                      height: 1.0,
                    ),
                  ),
                );
              });
            },
            icon: const Icon(Icons.add_box_outlined),
            label: const Text('Add Object'),
          ),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: ListView.builder(
            itemCount: _working.objects.length,
            itemBuilder: (context, index) {
              final item = _working.objects[index];
              return _buildBoundaryCard(
                title: 'Object ${index + 1}',
                name: item.name,
                boundary: item.boundary,
                selected: _selectedTargetType == _SelectionTargetType.object &&
                    _selectedBoundaryIndex == index,
                onNameChanged: (value) => item.name = value,
                onSelected: () {
                  setState(() {
                    _selectedTargetType = _SelectionTargetType.object;
                    _selectedBoundaryIndex = index;
                  });
                },
                onDelete: () {
                  setState(() {
                    _working.objects.removeAt(index);
                    if (_selectedTargetType == _SelectionTargetType.object &&
                        _selectedBoundaryIndex == index) {
                      _selectedBoundaryIndex = null;
                      _selectedTargetType = null;
                    }
                  });
                },
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildZonesTab() {
    return Column(
      children: [
        Align(
          alignment: Alignment.centerRight,
          child: FilledButton.icon(
            onPressed: () {
              setState(() {
                _working.zones.add(
                  FieldConstraintZone(
                    name: 'Zone ${_working.zones.length + 1}',
                    boundary: OptimizationBoundary(
                      x: widget.fieldSizeMeters.width * 0.30,
                      y: widget.fieldSizeMeters.height * 0.30,
                      width: 1.2,
                      height: 1.2,
                    ),
                    visibleByDefault: true,
                  ),
                );
              });
            },
            icon: const Icon(Icons.add_box_outlined),
            label: const Text('Add Zone'),
          ),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: ListView.builder(
            itemCount: _working.zones.length,
            itemBuilder: (context, index) {
              final item = _working.zones[index];
              return Column(
                children: [
                  _buildBoundaryCard(
                    title: 'Zone ${index + 1}',
                    name: item.name,
                    boundary: item.boundary,
                    selected: _selectedTargetType == _SelectionTargetType.zone &&
                        _selectedBoundaryIndex == index,
                    onNameChanged: (value) => item.name = value,
                    onSelected: () {
                      setState(() {
                        _selectedTargetType = _SelectionTargetType.zone;
                        _selectedBoundaryIndex = index;
                      });
                    },
                    onDelete: () {
                      setState(() {
                        _working.zones.removeAt(index);
                        if (_selectedTargetType == _SelectionTargetType.zone &&
                            _selectedBoundaryIndex == index) {
                          _selectedBoundaryIndex = null;
                          _selectedTargetType = null;
                        }
                      });
                    },
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text('Visible by default'),
                        const SizedBox(width: 6),
                        Switch(
                          value: item.visibleByDefault,
                          onChanged: (value) {
                            setState(() {
                              item.visibleByDefault = value;
                            });
                          },
                        ),
                      ],
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildBoundaryCard({
    required String title,
    required String name,
    required OptimizationBoundary boundary,
    required bool selected,
    required ValueChanged<String> onNameChanged,
    required VoidCallback onSelected,
    required VoidCallback onDelete,
    Widget? trailing,
  }) {
    final colorScheme = Theme.of(context).colorScheme;

    return Card(
      elevation: 1,
      margin: const EdgeInsets.symmetric(vertical: 6),
      shape: selected
          ? RoundedRectangleBorder(
              side: BorderSide(color: colorScheme.primary, width: 1.5),
              borderRadius: BorderRadius.circular(8),
            )
          : null,
      child: InkWell(
        onTap: onSelected,
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text(title),
                  const Spacer(),
                  if (trailing != null) trailing,
                  IconButton(
                    tooltip: 'Delete',
                    onPressed: onDelete,
                    icon: const Icon(Icons.delete_forever),
                  ),
                ],
              ),
              TextFormField(
                initialValue: name,
                decoration: const InputDecoration(labelText: 'Name'),
                onChanged: onNameChanged,
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _numField('X (m)', boundary.x, (v) => boundary.x = v.toDouble()),
                  _numField('Y (m)', boundary.y, (v) => boundary.y = v.toDouble()),
                  _numField(
                    'Width (m)',
                    boundary.width,
                    (v) => boundary.width = v.toDouble().abs().clamp(0.05, 54),
                    min: 0.05,
                  ),
                  _numField(
                    'Height (m)',
                    boundary.height,
                    (v) => boundary.height = v.toDouble().abs().clamp(0.05, 27),
                    min: 0.05,
                  ),
                  _numField(
                    'Rotation (deg)',
                    boundary.rotationDeg,
                    (v) => boundary.rotationDeg = v.toDouble(),
                  ),
                  _numField(
                    'Tolerance (m)',
                    boundary.tolerance,
                    (v) => boundary.tolerance = v.toDouble().clamp(0.0, 2.0),
                    min: 0.0,
                    max: 2.0,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _numField(
    String label,
    num value,
    ValueChanged<num> onChanged, {
    num? min,
    num? max,
  }) {
    return SizedBox(
      width: 145,
      child: NumberTextField(
        initialValue: value,
        label: label,
        minValue: min,
        maxValue: max,
        onSubmitted: (newValue) {
          if (newValue != null) {
            setState(() {
              onChanged(newValue);
            });
          }
        },
      ),
    );
  }
}

class _FieldConstraintCanvasPainter extends CustomPainter {
  final Size fieldSizeMeters;
  final FieldImage? fieldImage;
  final double viewScale;
  final List<FieldConstraintObject> objects;
  final List<FieldConstraintZone> zones;
  final Rect? draftRect;
  final _SelectionTargetType? selectedTargetType;
  final int? selectedBoundaryIndex;

  const _FieldConstraintCanvasPainter({
    required this.fieldSizeMeters,
    required this.fieldImage,
    required this.viewScale,
    required this.objects,
    required this.zones,
    required this.draftRect,
    required this.selectedTargetType,
    required this.selectedBoundaryIndex,
  });

  @override
  void paint(Canvas canvas, Size size) {
    for (int i = 0; i < objects.length; i++) {
      final object = objects[i];
      _paintBoundary(
        canvas,
        size,
        object.boundary,
        Colors.deepOrangeAccent,
        fillAlpha: 0.16,
        isSelected:
            selectedTargetType == _SelectionTargetType.object && selectedBoundaryIndex == i,
        label: object.name,
      );
    }

    for (int i = 0; i < zones.length; i++) {
      final zone = zones[i];
      _paintBoundary(
        canvas,
        size,
        zone.boundary,
        Colors.lightBlueAccent,
        fillAlpha: 0.14,
        isSelected:
            selectedTargetType == _SelectionTargetType.zone && selectedBoundaryIndex == i,
      );
    }

    if (draftRect != null) {
      final draftFill = Paint()
        ..style = PaintingStyle.fill
        ..color = Colors.pinkAccent.withAlpha(55);
      final draftStroke = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.0
        ..color = Colors.pinkAccent;
      canvas.drawRect(draftRect!, draftFill);
      canvas.drawRect(draftRect!, draftStroke);
    }
  }

  void _paintBoundary(
    Canvas canvas,
    Size canvasSize,
    OptimizationBoundary boundary,
    Color color, {
    double fillAlpha = 0.1,
    bool isSelected = false,
    String? label,
  }) {
    final corners = boundary.corners();
    if (corners.isEmpty) return;

    final path = Path();
    final first = _metersToPixels(corners.first, canvasSize);
    path.moveTo(first.dx, first.dy);

    for (int i = 1; i < corners.length; i++) {
      final px = _metersToPixels(corners[i], canvasSize);
      path.lineTo(px.dx, px.dy);
    }
    path.close();

    final fillPaint = Paint()
      ..style = PaintingStyle.fill
      ..color = color.withAlpha((fillAlpha * 255).round().clamp(0, 255));
    final scale = viewScale.clamp(0.35, 6.0);
    final strokePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = (isSelected ? 2.8 : 2.0) / scale
      ..color = color;

    canvas.drawPath(path, fillPaint);
    canvas.drawPath(path, strokePaint);

    if (label != null && label.trim().isNotEmpty) {
      _paintBoundaryLabel(canvas, canvasSize, boundary, label.trim());
    }

    if (isSelected) {
      _paintSelectionHandles(canvas, canvasSize, boundary, color);
    }
  }

  void _paintBoundaryLabel(
    Canvas canvas,
    Size canvasSize,
    OptimizationBoundary boundary,
    String label,
  ) {
    final pxCorners = [for (final c in boundary.corners()) _metersToPixels(c, canvasSize)];
    double minX = pxCorners.first.dx;
    double maxX = pxCorners.first.dx;
    double minY = pxCorners.first.dy;
    double maxY = pxCorners.first.dy;
    for (final p in pxCorners) {
      minX = min(minX, p.dx);
      maxX = max(maxX, p.dx);
      minY = min(minY, p.dy);
      maxY = max(maxY, p.dy);
    }

    final availableW = max(10.0, maxX - minX - 8.0);
    final availableH = max(8.0, maxY - minY - 8.0);
    final scale = viewScale.clamp(0.35, 6.0);
    double fontSize =
      (min(availableH * 0.55, availableW * 0.22) / scale).clamp(6.0 / scale, 28.0 / scale);

    TextPainter textPainter;
    while (true) {
      textPainter = TextPainter(
        textDirection: TextDirection.ltr,
        textAlign: TextAlign.center,
        maxLines: 1,
        ellipsis: '…',
        text: TextSpan(
          text: label,
          style: TextStyle(
            color: Colors.white.withAlpha(220),
            fontWeight: FontWeight.w600,
            fontSize: fontSize,
          ),
        ),
      )..layout(maxWidth: availableW);

      if ((textPainter.width <= availableW && textPainter.height <= availableH) ||
          fontSize <= (6.0 / scale)) {
        break;
      }
      fontSize -= 1.0;
    }

    final center = _metersToPixels(boundary.center, canvasSize);
    final drawOffset = Offset(
      center.dx - (textPainter.width / 2.0),
      center.dy - (textPainter.height / 2.0),
    );
    textPainter.paint(canvas, drawOffset);
  }

  void _paintSelectionHandles(
    Canvas canvas,
    Size canvasSize,
    OptimizationBoundary boundary,
    Color color,
  ) {
    final corners = [for (final c in boundary.corners()) _metersToPixels(c, canvasSize)];
    final scale = viewScale.clamp(0.35, 6.0);
    final handleRadius = 5.0 / scale;
    final fill = Paint()
      ..style = PaintingStyle.fill
      ..color = Colors.white;
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0 / scale
      ..color = color;

    for (final c in corners) {
      canvas.drawCircle(c, handleRadius, fill);
      canvas.drawCircle(c, handleRadius, stroke);
    }

    final rotateHandle = _metersToPixels(boundary.rotationHandle(), canvasSize);
    final rotateStem = _metersToPixels(
      boundary.toWorld(Translation2d(0.0, boundary.height / 2.0)),
      canvasSize,
    );
    canvas.drawLine(rotateStem, rotateHandle, stroke);
    canvas.drawCircle(rotateHandle, handleRadius, fill);
    canvas.drawCircle(rotateHandle, handleRadius, stroke);
  }

  Offset _metersToPixels(Translation2d meters, Size canvasSize) {
    if (fieldImage != null) {
      final scale = canvasSize.width / fieldImage!.defaultSize.width;
      return PathPainterUtil.pointToPixelOffset(meters, scale, fieldImage!);
    }

    final x = (meters.x / fieldSizeMeters.width) * canvasSize.width;
    final y = canvasSize.height -
        ((meters.y / fieldSizeMeters.height) * canvasSize.height);
    return Offset(x.toDouble(), y.toDouble());
  }

  @override
  bool shouldRepaint(covariant _FieldConstraintCanvasPainter oldDelegate) {
    return oldDelegate.objects != objects ||
        oldDelegate.zones != zones ||
        oldDelegate.draftRect != draftRect ||
        oldDelegate.viewScale != viewScale ||
        oldDelegate.selectedTargetType != selectedTargetType ||
        oldDelegate.selectedBoundaryIndex != selectedBoundaryIndex;
  }
}
