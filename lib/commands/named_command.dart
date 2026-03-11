import 'package:pathplanner/commands/command.dart';

class NamedCommand extends Command {
  String? name;

  NamedCommand({this.name, super.beforeDelay, super.afterDelay})
      : super(type: 'named');

  NamedCommand.fromDataJson(Map<String, dynamic> json)
      : this(name: json['name']);

  @override
  Map<String, dynamic> dataToJson() {
    return {
      'name': name,
      'beforeDelay': beforeDelay,
      'afterDelay': afterDelay,
    };
  }

  @override
  Command clone() {
    return copyBaseValuesTo(NamedCommand(name: name));
  }

  @override
  bool operator ==(Object other) =>
      other is NamedCommand &&
      other.runtimeType == runtimeType &&
      other.beforeDelay == beforeDelay &&
      other.afterDelay == afterDelay &&
      other.name == name;

  @override
    int get hashCode => Object.hash(type, name, beforeDelay, afterDelay);
}
