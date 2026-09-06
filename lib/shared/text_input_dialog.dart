import 'package:flutter/material.dart';

/// 弹出带输入框的对话框。
///
/// 控制器由对话框内部持有并在路由完全退出后由 State.dispose 释放，
/// 避免在 pop 后立刻 dispose 导致 Flutter 生命周期断言。
Future<String?> showTextInputDialog(
  BuildContext context, {
  required String title,
  String initialValue = '',
  String labelText = '',
  String hintText = '',
  String helperText = '',
  bool obscureText = false,
  TextInputType? keyboardType,
  bool autofocus = true,
  int maxLines = 1,
  String cancelText = '取消',
  String confirmText = '保存',
}) {
  return showDialog<String>(
    context: context,
    builder: (_) => _TextInputDialog(
      title: title,
      initialValue: initialValue,
      labelText: labelText,
      hintText: hintText,
      helperText: helperText,
      obscureText: obscureText,
      keyboardType: keyboardType,
      autofocus: autofocus,
      maxLines: maxLines,
      cancelText: cancelText,
      confirmText: confirmText,
    ),
  );
}

class _TextInputDialog extends StatefulWidget {
  const _TextInputDialog({
    required this.title,
    required this.initialValue,
    required this.labelText,
    required this.hintText,
    required this.helperText,
    required this.obscureText,
    required this.keyboardType,
    required this.autofocus,
    required this.maxLines,
    required this.cancelText,
    required this.confirmText,
  });

  final String title;
  final String initialValue;
  final String labelText;
  final String hintText;
  final String helperText;
  final bool obscureText;
  final TextInputType? keyboardType;
  final bool autofocus;
  final int maxLines;
  final String cancelText;
  final String confirmText;

  @override
  State<_TextInputDialog> createState() => _TextInputDialogState();
}

class _TextInputDialogState extends State<_TextInputDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialValue);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        controller: _controller,
        autofocus: widget.autofocus,
        obscureText: widget.obscureText,
        keyboardType: widget.keyboardType,
        // 多行时不能设 maxLines=1，也不能让回车提交，否则没法换行。
        maxLines: widget.maxLines,
        minLines: widget.maxLines > 1 ? widget.maxLines : null,
        decoration: InputDecoration(
          labelText: widget.labelText.isEmpty ? null : widget.labelText,
          hintText: widget.hintText.isEmpty ? null : widget.hintText,
          helperText: widget.helperText.isEmpty ? null : widget.helperText,
          helperMaxLines: 3,
        ),
        onSubmitted: widget.maxLines > 1
            ? null
            : (value) => Navigator.pop(context, value.trim()),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(widget.cancelText),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _controller.text.trim()),
          child: Text(widget.confirmText),
        ),
      ],
    );
  }
}
