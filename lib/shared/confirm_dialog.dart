import 'package:flutter/material.dart';

import '../router.dart';

/// 二次确认对话框。
Future<bool> showConfirmDialog(
  BuildContext context, {
  required String title,
  required String message,
  String confirmText = '确认',
  bool destructive = false,
}) async {
  // 悬浮窗挂在 Navigator 之上；APP 内要用根 Navigator 的 context 才能弹窗。
  // 外悬浮模式根 Navigator 不在树上，appNavigatorKey.currentContext 为 null，
  // 此时回退到悬浮窗自己的 context（ExternalFloatShell 的内层 Navigator）。
  final targetContext = appNavigatorKey.currentContext ?? context;
  final result = await showDialog<bool>(
    context: targetContext,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('取消'),
        ),
        FilledButton(
          style: destructive
              ? FilledButton.styleFrom(
                  backgroundColor: Theme.of(context).colorScheme.error,
                )
              : null,
          onPressed: () => Navigator.pop(context, true),
          child: Text(confirmText),
        ),
      ],
    ),
  );
  return result ?? false;
}
