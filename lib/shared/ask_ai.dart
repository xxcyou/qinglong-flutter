import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/ai/floating/ai_dock_provider.dart';

/// 「发给 AI」的统一入口。任意页面拿到一段文本（日志、报错、代码片段、
/// 配置内容）都可以调用它，内容会作为上下文附到悬浮 AI 的输入框上方，
/// 用户可以再补一句话再发送——不需要切到 AI 页。
class AskAi {
  const AskAi._();

  /// 附上上下文并弹出悬浮面板。
  ///
  /// [contextKey] 给「页面自动附带」的内容用：传了它，这次手动推送和自动挂上
  /// 来的是同一个附件（同 key 原地替换），也会解除用户之前的 X。配合
  /// [sticky]/[live]，手动点一下和自动附带的行为就完全一致，不会出现
  /// 「点了发给 AI，发一次就没了」这种两套语义。
  static void push(
    WidgetRef ref, {
    required String label,
    required String content,
    String source = '',
    String? language,
    String? draft,
    String? contextKey,
    bool readOnly = false,
    bool sticky = false,
    String Function()? live,
  }) {
    if (content.trim().isEmpty) return;
    ref.read(aiDockProvider.notifier).push(
          AiContextChip(
            label: label,
            content: content,
            source: source,
            language: language,
            key: contextKey,
            readOnly: readOnly,
            sticky: sticky,
            live: live,
          ),
          draft: draft,
        );
  }

  /// 附上下文并立刻提问（不等用户补话）。
  static void ask(
    WidgetRef ref, {
    required String label,
    required String content,
    required String question,
    String source = '',
    String? language,
    String? contextKey,
    bool readOnly = false,
    bool sticky = false,
    String Function()? live,
  }) {
    push(
      ref,
      label: label,
      content: content,
      source: source,
      language: language,
      draft: question,
      contextKey: contextKey,
      readOnly: readOnly,
      sticky: sticky,
      live: live,
    );
  }

  /// 带提示的推送：顺手给用户一个反馈。
  static void pushWithToast(
    BuildContext context,
    WidgetRef ref, {
    required String label,
    required String content,
    String source = '',
    String? language,
    String? draft,
    String? contextKey,
    bool readOnly = false,
    bool sticky = false,
    String Function()? live,
  }) {
    if (content.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('没有可发送的内容'),
          duration: Duration(seconds: 1),
        ),
      );
      return;
    }
    push(
      ref,
      label: label,
      content: content,
      source: source,
      language: language,
      draft: draft,
      contextKey: contextKey,
      readOnly: readOnly,
      sticky: sticky,
      live: live,
    );
  }
}

/// 「问 AI」按钮：图标版，放在 AppBar / 工具条上。
class AskAiButton extends ConsumerWidget {
  const AskAiButton({
    super.key,
    required this.label,
    required this.contentBuilder,
    this.source = '',
    this.language,
    this.draft,
    this.tooltip = '发给 AI',
    this.icon = Icons.auto_awesome,
    this.dense = false,
    this.contextKey,
    this.readOnly = false,
    this.sticky = false,
  });

  final String label;

  /// 延迟取内容：选中文本、当前编辑器内容都可能随时变化。
  final String Function() contentBuilder;
  final String source;
  final String? language;
  final String? draft;
  final String tooltip;
  final IconData icon;
  final bool dense;

  /// 与页面自动附带的附件对齐（见 [AskAi.push]）。日志页这类
  /// 「用户正在看」的页面传自己的 aiContextKey，手动点和自动挂就是一回事。
  final String? contextKey;
  final bool readOnly;
  final bool sticky;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return IconButton(
      tooltip: tooltip,
      visualDensity: dense ? VisualDensity.compact : null,
      onPressed: () => AskAi.pushWithToast(
        context,
        ref,
        label: label,
        content: contentBuilder(),
        source: source,
        language: language,
        draft: draft,
        contextKey: contextKey,
        readOnly: readOnly,
        sticky: sticky,
        live: contextKey == null ? null : contentBuilder,
      ),
      icon: Icon(icon, size: dense ? 18 : 20),
    );
  }
}
