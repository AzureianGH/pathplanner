import 'package:pathplanner/commands/command.dart';

class WaitCommand extends Command {
  num waitTime;

  WaitCommand({this.waitTime = 0, super.beforeDelay, super.afterDelay})
      : super(type: 'wait');

  WaitCommand.fromDataJson(Map<String, dynamic> dataJson)
      : this(waitTime: dataJson['waitTime'] ?? 0);

  @override
  Map<String, dynamic> dataToJson() {
    return {
      'waitTime': waitTime,
      'beforeDelay': beforeDelay,
      'afterDelay': afterDelay,
    };
  }

  @override
  Command clone() {
    return copyBaseValuesTo(WaitCommand(waitTime: waitTime));
  }

  @override
  bool operator ==(Object other) =>
      other is WaitCommand &&
      other.runtimeType == runtimeType &&
      other.beforeDelay == beforeDelay &&
      other.afterDelay == afterDelay &&
      other.waitTime == waitTime;

  @override
    int get hashCode => Object.hash(type, waitTime, beforeDelay, afterDelay);
}
