import 'package:pathplanner/commands/command.dart';

class PathCommand extends Command {
  String? pathName;

  PathCommand({this.pathName, super.beforeDelay, super.afterDelay})
      : super(type: 'path');

  PathCommand.fromDataJson(Map<String, dynamic> json)
      : this(pathName: json['pathName']);

  @override
  Map<String, dynamic> dataToJson() {
    return {
      'pathName': pathName,
      'beforeDelay': beforeDelay,
      'afterDelay': afterDelay,
    };
  }

  @override
  Command clone() {
    return copyBaseValuesTo(PathCommand(pathName: pathName));
  }

  @override
  bool operator ==(Object other) =>
      other is PathCommand &&
      other.runtimeType == runtimeType &&
      other.beforeDelay == beforeDelay &&
      other.afterDelay == afterDelay &&
      other.pathName == pathName;

  @override
    int get hashCode => Object.hash(type, pathName, beforeDelay, afterDelay);
}
