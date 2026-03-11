import 'package:flutter/material.dart';
import 'package:pathplanner/commands/command.dart';

enum CommandPreviewPhase {
  beforeDelay,
  running,
  afterDelay,
}

class CommandPreviewState {
  final Command command;
  final CommandPreviewPhase phase;
  final num remainingTime;

  const CommandPreviewState({
    required this.command,
    required this.phase,
    required this.remainingTime,
  });

  bool get isDelayPhase =>
      phase == CommandPreviewPhase.beforeDelay ||
      phase == CommandPreviewPhase.afterDelay;

  int get countdownTenths => (remainingTime * 10).ceil().clamp(0, 1048576);
}

class CommandDelayStatus extends StatelessWidget {
  final Command command;
  final CommandPreviewState? previewState;
  final Color activeColor;

  const CommandDelayStatus({
    super.key,
    required this.command,
    required this.previewState,
    required this.activeColor,
  });

  @override
  Widget build(BuildContext context) {
    final activeDelay = previewState != null &&
        identical(previewState!.command, command) &&
        previewState!.isDelayPhase;

    if (activeDelay) {
      final phaseLabel = previewState!.phase == CommandPreviewPhase.beforeDelay
          ? 'Before'
          : 'After';
      final displaySeconds =
          (previewState!.countdownTenths / 10).toStringAsFixed(1);

      return Tooltip(
        message: '$phaseLabel delay active',
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: activeColor.withAlpha(36),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: activeColor),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.schedule, size: 14, color: activeColor),
              const SizedBox(width: 4),
              Text(
                '${displaySeconds}s',
                style: TextStyle(
                  color: activeColor,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      );
    }

    if (!command.hasExecutionDelays) {
      return const SizedBox.shrink();
    }

    return const Tooltip(
      message: 'Command delays set',
      child: Icon(Icons.schedule, size: 18),
    );
  }
}