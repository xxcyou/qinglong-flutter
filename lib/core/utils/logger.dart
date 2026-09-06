import 'package:flutter/material.dart';

/// 统一调试/审计日志。禁止输出 token、value、cookie 等敏感内容。
class Logger {
  Logger._();

  static void d(String tag, String message) {
    debugPrint('[QL][$tag] $message');
  }

  static void e(String tag, String message, [Object? error]) {
    debugPrint(
        '[QL][$tag][ERROR] $message${error == null ? '' : ' -> $error'}');
  }

  static String mask(String? value) {
    if (value == null || value.isEmpty) return '';
    if (value.length <= 4) return '****';
    return '${value.substring(0, 2)}****${value.substring(value.length - 2)}';
  }

  static void showError(BuildContext context, Object error) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
            content:
                Text('$error', maxLines: 3, overflow: TextOverflow.ellipsis)),
      );
  }
}
