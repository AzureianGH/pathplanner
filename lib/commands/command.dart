import 'package:flutter/foundation.dart';
import 'package:pathplanner/commands/command_groups.dart';
import 'package:pathplanner/commands/named_command.dart';
import 'package:pathplanner/commands/path_command.dart';
import 'package:pathplanner/commands/wait_command.dart';

abstract class Command {
  final String type;
  num beforeDelay;
  num afterDelay;

  Command({
    required this.type,
    this.beforeDelay = 0,
    this.afterDelay = 0,
  });

  Map<String, dynamic> dataToJson();

  Command clone();

  bool get hasExecutionDelays => beforeDelay > 0 || afterDelay > 0;

  T copyBaseValuesTo<T extends Command>(T command) {
    command.beforeDelay = beforeDelay;
    command.afterDelay = afterDelay;
    return command;
  }

  Map<String, dynamic> toRawJson() {
    return {
      'type': type,
      'data': dataToJson(),
    };
  }

  @nonVirtual
  Map<String, dynamic> toJson() {
    final rawJson = toRawJson();

    if (!hasExecutionDelays) {
      return rawJson;
    }

    return {
      'type': 'sequential',
      'data': {
        'commands': [
          if (beforeDelay > 0) WaitCommand(waitTime: beforeDelay).toJson(),
          rawJson,
          if (afterDelay > 0) WaitCommand(waitTime: afterDelay).toJson(),
        ],
        'wrappedCommand': rawJson,
        'delay': {
          'before': beforeDelay,
          'after': afterDelay,
        },
      },
    };
  }

  static Command? fromJson(Map<String, dynamic> json) {
    String? type = json['type'];
    Map<String, dynamic> data = json['data'] ?? {};

    if (type == 'sequential' && data['wrappedCommand'] is Map<String, dynamic>) {
      final wrapped = Command.fromJson(
          Map<String, dynamic>.from(data['wrappedCommand'] as Map));
      if (wrapped != null) {
        final delay = data['delay'];
        if (delay is Map) {
          wrapped.beforeDelay = _numValue(delay['before']);
          wrapped.afterDelay = _numValue(delay['after']);
        }
      }
      return wrapped;
    }

    final command = switch (type) {
      'wait' => WaitCommand.fromDataJson(data),
      'named' => NamedCommand.fromDataJson(data),
      'path' => PathCommand.fromDataJson(data),
      'sequential' => SequentialCommandGroup.fromDataJson(data),
      'parallel' => ParallelCommandGroup.fromDataJson(data),
      'race' => RaceCommandGroup.fromDataJson(data),
      'deadline' => DeadlineCommandGroup.fromDataJson(data),
      _ => null,
    };

    if (command != null) {
      command.beforeDelay = _numValue(data['beforeDelay']);
      command.afterDelay = _numValue(data['afterDelay']);
    }

    return command;
  }

  static Command? fromType(String type, {List<Command>? commands}) {
    return switch (type) {
      'named' => NamedCommand(),
      'wait' => WaitCommand(),
      'path' => PathCommand(),
      'sequential' => SequentialCommandGroup(commands: commands ?? []),
      'parallel' => ParallelCommandGroup(commands: commands ?? []),
      'race' => RaceCommandGroup(commands: commands ?? []),
      'deadline' => DeadlineCommandGroup(commands: commands ?? []),
      _ => null,
    };
  }

  static num _numValue(dynamic value) {
    if (value is num) {
      return value;
    }
    if (value is String) {
      return num.tryParse(value) ?? 0;
    }
    return 0;
  }
}
