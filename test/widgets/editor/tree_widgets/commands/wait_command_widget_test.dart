import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pathplanner/commands/wait_command.dart';
import 'package:pathplanner/widgets/editor/tree_widgets/commands/command_preview_state.dart';
import 'package:pathplanner/widgets/editor/tree_widgets/commands/wait_command_widget.dart';
import 'package:pathplanner/widgets/number_text_field.dart';
import 'package:undo/undo.dart';

void main() {
  late WaitCommand cmd;
  late ChangeStack undoStack;
  late bool removed;
  late bool updated;

  setUp(() {
    cmd = WaitCommand(waitTime: 1.0);
    undoStack = ChangeStack();
    removed = false;
    updated = false;
  });

  testWidgets('time text field', (widgetTester) async {
    await widgetTester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: WaitCommandWidget(
          command: cmd,
          undoStack: undoStack,
          onRemoved: () => removed = true,
          onUpdated: () => updated = true,
        ),
      ),
    ));

    final textField = find.widgetWithText(NumberTextField, 'Wait Time (S)');

    expect(textField, findsOneWidget);

    await widgetTester.enterText(textField, '2.0');
    await widgetTester.testTextInput.receiveAction(TextInputAction.done);
    await widgetTester.pump();

    expect(updated, true);
    expect(cmd.waitTime, 2.0);

    undoStack.undo();
    await widgetTester.pump();
    expect(cmd.waitTime, 1.0);
  });

  testWidgets('remove button', (widgetTester) async {
    await widgetTester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: WaitCommandWidget(
          command: cmd,
          undoStack: undoStack,
          onRemoved: () => removed = true,
          onUpdated: () => updated = true,
        ),
      ),
    ));

    final actionsButton = find.byTooltip('Command Actions');

    expect(actionsButton, findsOneWidget);

    await widgetTester.tap(actionsButton);
    await widgetTester.pumpAndSettle();
    await widgetTester.tap(find.text('Delete'));
    await widgetTester.pump();

    expect(removed, true);
  });

  testWidgets('shows active delay countdown', (widgetTester) async {
    cmd.afterDelay = 1.0;

    await widgetTester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: WaitCommandWidget(
          command: cmd,
          undoStack: undoStack,
          previewState: CommandPreviewState(
            command: cmd,
            phase: CommandPreviewPhase.afterDelay,
            remainingTime: 0.44,
          ),
        ),
      ),
    ));

    expect(find.text('0.5s'), findsOneWidget);
  });
}
