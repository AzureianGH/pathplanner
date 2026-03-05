import 'dart:io';

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';
import 'package:pathplanner/widgets/window_buttons.dart';

class CustomAppBar extends AppBar {
  final Widget titleWidget;

  CustomAppBar({
    this.titleWidget = const Text('PathPlannerX'),
    super.key,
    Widget? leading,
    bool? automaticallyImplyLeading,
  }) : super(
          leading: leading,
          automaticallyImplyLeading: automaticallyImplyLeading ?? true,
      centerTitle: true,
          titleSpacing: 0,
          actions: [
            if (!Platform.isMacOS) MinimizeWindowButton(),
            if (!Platform.isMacOS) MaximizeWindowButton(),
            if (!Platform.isMacOS) CloseWindowButton(),
            if (Platform.isMacOS &&
                (leading != null || (automaticallyImplyLeading ?? true)))
              const SizedBox(width: kToolbarHeight),
          ],
          title: SizedBox(
            height: 48,
            child: Row(
              children: [
                Expanded(
                  child: _MoveWindowArea(
                    child: Container(
                      alignment: Alignment.center,
                      child: titleWidget,
                    ),
                  ),
                ),
              ],
            ),
          ),
          elevation: 1,
        );
}

class _MoveWindowArea extends StatelessWidget {
  final Widget? child;

  const _MoveWindowArea({this.child});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onPanStart: (details) {
        windowManager.startDragging();
      },
      onDoubleTap: () async {
        if (await windowManager.isMaximized()) {
          windowManager.unmaximize();
        } else {
          windowManager.maximize();
        }
      },
      child: child ?? Container(),
    );
  }
}
