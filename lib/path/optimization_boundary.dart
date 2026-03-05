import 'dart:math';
import 'dart:ui';

import 'package:pathplanner/util/wpimath/geometry.dart';

class OptimizationBoundary {
  double x;
  double y;
  double width;
  double height;
  double rotationDeg;
  double tolerance;

  OptimizationBoundary({
    required this.x,
    required this.y,
    required this.width,
    required this.height,
    this.rotationDeg = 0.0,
    this.tolerance = 0.0,
  });

  factory OptimizationBoundary.fromJson(Map<String, dynamic> json) {
    return OptimizationBoundary(
      x: (json['x'] ?? 0.0).toDouble(),
      y: (json['y'] ?? 0.0).toDouble(),
      width: (json['width'] ?? 1.0).toDouble(),
      height: (json['height'] ?? 1.0).toDouble(),
      rotationDeg: (json['rotationDeg'] ?? 0.0).toDouble(),
      tolerance: (json['tolerance'] ?? 0.0).toDouble(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'x': x,
      'y': y,
      'width': width,
      'height': height,
      'rotationDeg': rotationDeg,
      'tolerance': tolerance,
    };
  }

  OptimizationBoundary clone() {
    return OptimizationBoundary(
      x: x,
      y: y,
      width: width,
      height: height,
      rotationDeg: rotationDeg,
      tolerance: tolerance,
    );
  }

  double get rotationRad => rotationDeg * (3.1415926535897932 / 180.0);

  Translation2d get center {
    final rect = toRect();
    return Translation2d(rect.center.dx, rect.center.dy);
  }

  void setFromCenter(Translation2d c) {
    x = c.x - (width / 2.0);
    y = c.y - (height / 2.0);
  }

  Translation2d toLocal(Translation2d point) {
    final c = center;
    final dx = point.x - c.x;
    final dy = point.y - c.y;
    final cosA = cos(-rotationRad);
    final sinA = sin(-rotationRad);
    return Translation2d((dx * cosA) - (dy * sinA), (dx * sinA) + (dy * cosA));
  }

  Translation2d toWorld(Translation2d local) {
    final c = center;
    final cosA = cos(rotationRad);
    final sinA = sin(rotationRad);
    return Translation2d(
      c.x + (local.x * cosA) - (local.y * sinA),
      c.y + (local.x * sinA) + (local.y * cosA),
    );
  }

  bool containsPoint(Translation2d point, {double inflate = 0.0}) {
    final local = toLocal(point);
    final halfW = (width / 2.0) + inflate;
    final halfH = (height / 2.0) + inflate;
    return local.x >= -halfW &&
        local.x <= halfW &&
        local.y >= -halfH &&
        local.y <= halfH;
  }

  List<Translation2d> corners({double inflate = 0.0}) {
    final halfW = (width / 2.0) + inflate;
    final halfH = (height / 2.0) + inflate;
    return [
      toWorld(Translation2d(-halfW, halfH)),
      toWorld(Translation2d(halfW, halfH)),
      toWorld(Translation2d(halfW, -halfH)),
      toWorld(Translation2d(-halfW, -halfH)),
    ];
  }

  Translation2d rotationHandle({double offset = 0.35}) {
    final halfH = (height / 2.0) + offset;
    return toWorld(Translation2d(0.0, halfH));
  }

  Rect toRect() {
    final left = width >= 0 ? x : x + width;
    final right = width >= 0 ? x + width : x;
    final bottom = height >= 0 ? y : y + height;
    final top = height >= 0 ? y + height : y;

    return Rect.fromLTRB(left, bottom, right, top);
  }

  Rect toleranceRect() {
    return toRect().inflate(tolerance);
  }

  @override
  bool operator ==(Object other) {
    return other is OptimizationBoundary &&
        other.runtimeType == runtimeType &&
        other.x == x &&
        other.y == y &&
        other.width == width &&
        other.height == height &&
          other.rotationDeg == rotationDeg &&
        other.tolerance == tolerance;
  }

  @override
        int get hashCode => Object.hash(x, y, width, height, rotationDeg, tolerance);
}
