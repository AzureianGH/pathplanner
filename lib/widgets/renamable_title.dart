import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class RenamableTitle extends StatefulWidget {
  final String title;
  final ValueChanged<String>? onRename;
  final TextStyle? textStyle;
  final EdgeInsets? contentPadding;

  const RenamableTitle({
    super.key,
    required this.title,
    this.onRename,
    this.textStyle,
    this.contentPadding,
  });

  @override
  State<RenamableTitle> createState() => _RenamableTitleState();
}

class _RenamableTitleState extends State<RenamableTitle> {
  late final TextEditingController _controller;
  late final FocusNode _focusNode;
  String? _lastCommitted;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.title);
    _controller.selection = TextSelection.fromPosition(
      TextPosition(offset: widget.title.length),
    );
    _focusNode = FocusNode();
  }

  @override
  void didUpdateWidget(covariant RenamableTitle oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (widget.title != oldWidget.title && !_focusNode.hasFocus) {
      _controller.value = TextEditingValue(
        text: widget.title,
        selection: TextSelection.collapsed(offset: widget.title.length),
      );
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _commitRename() {
    final text = _controller.text.trim();
    if (text.isEmpty || text == widget.title || text == _lastCommitted) {
      return;
    }

    _lastCommitted = text;
    widget.onRename?.call(text);
  }

  @override
  Widget build(BuildContext context) {
    ColorScheme colorScheme = Theme.of(context).colorScheme;

    return IntrinsicWidth(
      child: TextField(
        focusNode: _focusNode,
        onSubmitted: (_) {
          _commitRename();
        },
        onEditingComplete: () {
          _commitRename();
          FocusManager.instance.primaryFocus?.unfocus();
        },
        onTapOutside: (_) {
          _commitRename();
          FocusManager.instance.primaryFocus?.unfocus();
        },
        style: widget.textStyle ?? TextStyle(color: colorScheme.onSurface),
        controller: _controller,
        decoration: InputDecoration(
          border: InputBorder.none,
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(20),
            borderSide: BorderSide(
              color: colorScheme.outline,
            ),
          ),
          enabledBorder: const OutlineInputBorder(
            borderSide: BorderSide(
              color: Colors.transparent,
            ),
          ),
          contentPadding: widget.contentPadding ??
              const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
        ),
        inputFormatters: [
          FilteringTextInputFormatter.deny(RegExp('["*<>?|/:\\\\]')),
        ],
      ),
    );
  }
}
