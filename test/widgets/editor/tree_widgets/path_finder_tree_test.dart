import 'package:file/memory.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pathplanner/path/pathplanner_path.dart';
import 'package:pathplanner/widgets/editor/tree_widgets/path_finder_tree.dart';
import 'package:pathplanner/widgets/editor/tree_widgets/tree_card_node.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:undo/undo.dart';

void main() {
  late ChangeStack undoStack;
  late PathPlannerPath path;
  late SharedPreferences prefs;

  setUp(() async {
    undoStack = ChangeStack();
    path = PathPlannerPath.defaultPath(
      pathDir: '/paths',
      fs: MemoryFileSystem(),
    );
    path.pathFinderExpanded = true;
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
  });

  testWidgets('widget builds and displays correctly', (widgetTester) async {
    await widgetTester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: PathFinderTree(
          path: path,
          undoStack: undoStack,
          prefs: prefs,
          fieldSizeMeters: const Size(16.54, 8.21),
        ),
      ),
    ));
    await widgetTester.pumpAndSettle();

    expect(find.byType(TreeCardNode), findsOneWidget);
    expect(find.text('PathFinder'), findsOneWidget);
    expect(find.byIcon(Icons.alt_route), findsOneWidget);
    expect(find.text('Find Path'), findsOneWidget);
    expect(find.text('Discard'), findsOneWidget);
    expect(find.text('Accept'), findsOneWidget);
  });

  testWidgets('tapping expands/collapses tree', (widgetTester) async {
    path.pathFinderExpanded = false;

    await widgetTester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: PathFinderTree(
          path: path,
          undoStack: undoStack,
          prefs: prefs,
          fieldSizeMeters: const Size(16.54, 8.21),
        ),
      ),
    ));

    await widgetTester.tap(find.byType(TreeCardNode));
    await widgetTester.pumpAndSettle();
    expect(path.pathFinderExpanded, true);

    await widgetTester.tap(find.text('PathFinder'));
    await widgetTester.pumpAndSettle();
    expect(path.pathFinderExpanded, false);
  });
}
