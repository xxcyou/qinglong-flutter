import 'package:flutter/material.dart';

/// 工具调用卡片（P6 实现）。
class ToolCallCard extends StatelessWidget {
  const ToolCallCard({super.key, this.title, this.detail});
  final String? title;
  final String? detail;

  @override
  Widget build(BuildContext context) {
    return Card(
        child:
            ListTile(title: Text(title ?? ''), subtitle: Text(detail ?? '')));
  }
}
