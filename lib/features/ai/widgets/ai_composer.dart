import 'package:flutter/material.dart';

import '../../../core/theme/glass.dart';
import '../../../core/utils/formatter.dart';
import '../models/approval_mode.dart';
import '../providers/chat_provider.dart';

/// AI 输入区：模型选择行 + 输入框，整体是一块悬浮液态玻璃。
///
/// 之前这两行是贴在页面底部的实心控件（`Material` chip + `filled` TextField），
/// 和全站玻璃风格断裂。现在合成一块浮起的玻璃板，行内元素用 [GlassPill]，
/// 输入框自身透明、靠玻璃板托底。
class AiComposer extends StatelessWidget {
  const AiComposer({
    super.key,
    required this.state,
    required this.controller,
    required this.onSend,
    required this.onStop,
    required this.onModelTap,
    required this.onStrengthTap,
    required this.onContextTap,
    required this.onApprovalTap,
    this.onChanged,
    this.onPaste,
    this.onAttach,
    this.compact = false,
    this.showControls = true,
    this.margin = const EdgeInsets.fromLTRB(10, 0, 10, 8),
  });

  final ChatState state;
  final TextEditingController controller;
  final VoidCallback onSend;
  final VoidCallback onStop;
  final VoidCallback onModelTap;
  final VoidCallback onStrengthTap;
  final VoidCallback onContextTap;
  final VoidCallback onApprovalTap;

  /// 输入内容变化回调（悬浮窗用它把草稿存进 dock state）。
  final ValueChanged<String>? onChanged;

  /// 粘贴按钮（悬浮窗里把剪贴板收进输入行，不再单独占一格）。
  final Future<void> Function()? onPaste;

  /// 加附件（挑一个本地文件带进提问）。null = 不显示这颗按钮。
  final Future<void> Function()? onAttach;

  /// 是否显示模型/策略/强度/上下文那一行。
  /// 悬浮窗里空间宝贵，用户只要"输入 + 发送 + 粘贴"，所以那里关掉。
  final bool showControls;

  /// 悬浮窗里空间紧，缩一号。
  final bool compact;
  final EdgeInsetsGeometry margin;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final running = state.isLoading;
    return Padding(
      padding: margin,
      child: GlassPanel(
        radius: 26,
        blur: Glass.blurStrong,
        shadowY: 10,
        padding: EdgeInsets.fromLTRB(8, compact ? 5 : 7, 8, compact ? 5 : 7),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (showControls) ...[
              _ControlRow(
                state: state,
                compact: compact,
                onModelTap: onModelTap,
                onStrengthTap: onStrengthTap,
                onContextTap: onContextTap,
                onApprovalTap: onApprovalTap,
              ),
              SizedBox(height: compact ? 5 : 7),
            ],
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                if (onAttach != null)
                  IconButton(
                    tooltip: '加附件（本地文件）',
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(
                      minWidth: 34,
                      minHeight: 34,
                    ),
                    onPressed: () => onAttach!(),
                    icon: const Icon(Icons.attach_file_rounded, size: 19),
                  ),
                if (onPaste != null)
                  IconButton(
                    tooltip: '粘贴剪贴板',
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(
                      minWidth: 34,
                      minHeight: 34,
                    ),
                    onPressed: () => onPaste!(),
                    icon: const Icon(Icons.content_paste_go, size: 18),
                  ),
                Expanded(
                  child: TextField(
                    controller: controller,
                    // 跑的时候也能输入：内容会进排队区，不再被丢弃。
                    minLines: 1,
                    maxLines: compact ? 3 : 5,
                    textInputAction: TextInputAction.newline,
                    style: TextStyle(fontSize: compact ? 13 : 14),
                    decoration: InputDecoration(
                      isDense: true,
                      // 玻璃板已经提供底色，输入框自己不能再填一层实色，
                      // 否则模糊效果被盖住。
                      filled: false,
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      hintText: running ? '继续输入会排队…' : '说说你想做什么',
                      hintStyle: TextStyle(
                        fontSize: compact ? 12.5 : 13.5,
                        color: scheme.onSurfaceVariant.withValues(alpha: 0.75),
                      ),
                      contentPadding: EdgeInsets.fromLTRB(
                        12,
                        compact ? 8 : 10,
                        4,
                        compact ? 8 : 10,
                      ),
                    ),
                    onChanged: onChanged,
                    onSubmitted: (_) => onSend(),
                  ),
                ),
                const SizedBox(width: 4),
                // 跑的时候「发送」变成「排队」，另给一颗停止键；
                // 以前只有停止键，等于跑起来就不能再输入了。
                if (running)
                  IconButton(
                    tooltip: '停止当前任务',
                    visualDensity: VisualDensity.compact,
                    onPressed: onStop,
                    icon: Icon(
                      Icons.stop_circle_outlined,
                      size: compact ? 22 : 25,
                      color: scheme.error,
                    ),
                  ),
                _SendButton(
                  running: running,
                  compact: compact,
                  onSend: onSend,
                  onStop: onStop,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ControlRow extends StatelessWidget {
  const _ControlRow({
    required this.state,
    required this.compact,
    required this.onModelTap,
    required this.onStrengthTap,
    required this.onContextTap,
    required this.onApprovalTap,
  });

  final ChatState state;
  final bool compact;
  final VoidCallback onModelTap;
  final VoidCallback onStrengthTap;
  final VoidCallback onContextTap;
  final VoidCallback onApprovalTap;

  @override
  Widget build(BuildContext context) {
    const effortLabels = ['无', '低', '中', '高'];
    final scheme = Theme.of(context).colorScheme;
    final model = state.selectedModel.isEmpty ? '未选择模型' : state.selectedModel;
    // 上下文占用要用服务端报回来的 prompt_tokens，没有再退回字符估算。
    // 以前拿"累计计费 token"或纯估算去算百分比，和真实占用差一个数量级。
    final estimated = state.estimatedContextTokens > 0
        ? state.estimatedContextTokens
        : (state.messages.fold<int>(
                  0,
                  (sum, m) =>
                      sum + m.content.length + m.toolCalls.length * 80 + 20,
                ) /
                3.5)
            .ceil();
    // 服务端 prompt_tokens 在有提示词缓存时往往只报“新写入/未命中”的部分，
    // 真正占用的上下文还要加上缓存命中量（cache_read），否则第二次同话题提问
    // 会看到上下文从 39k 掉到 4k 的假象。
    final lastContext = state.lastPromptTokens + state.lastCacheHitTokens;
    final usedTokens = lastContext > 0
        ? (lastContext > state.estimatedContextTokens
            ? lastContext
            : state.estimatedContextTokens)
        : estimated;
    final limit = state.contextLimit;
    final percent = limit <= 0 ? 0.0 : (usedTokens / limit).clamp(0.0, 1.0);
    final approval = state.approvalMode;

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: Row(
        children: [
          GlassPill(
            icon: Icons.smart_toy_outlined,
            label: model,
            // 夹在文字上而不是套在外面：外面套框拦不住 Row 给子节点的
            // 无限宽约束，模型名一长就是一条黄黑警告斜线。
            maxLabelWidth: compact ? 78 : 104,
            dense: compact,
            tooltip: model,
            onTap: onModelTap,
          ),
          const SizedBox(width: 6),
          // 上下文紧跟模型：这排是横向滚动的，一屏放不下四个药丸，
          // 排在第四位的等于没有（之前"上下文"就一直在屏幕外）。
          // 只给百分比看不出"到底多少"，所以把实际 token 也写上（智能换单位）；
          // 上限在点开的面板里，写进标签会长到把别人全挤出去。
          GlassPill(
            icon: Icons.data_usage_outlined,
            label: '上下文 ${Formatter.tokens(usedTokens)}'
                ' · ${(percent * 100).round()}%',
            dense: compact,
            color: percent > 0.85 ? scheme.error : null,
            onTap: onContextTap,
          ),
          const SizedBox(width: 6),
          GlassPill(
            icon: switch (approval) {
              AiApprovalMode.strict => Icons.lock_outline,
              AiApprovalMode.cautious => Icons.shield_outlined,
              AiApprovalMode.full => Icons.rocket_launch_outlined,
            },
            label: approval.label,
            dense: compact,
            color: switch (approval) {
              AiApprovalMode.strict => scheme.primary,
              AiApprovalMode.cautious => null,
              AiApprovalMode.full => scheme.error,
            },
            onTap: onApprovalTap,
          ),
          const SizedBox(width: 6),
          GlassPill(
            icon: Icons.bolt_outlined,
            label: '强度 ${effortLabels[state.reasoningEffort]}',
            dense: compact,
            onTap: onStrengthTap,
          ),
        ],
      ),
    );
  }
}

/// 发送/停止按钮：圆形玻璃 + 主色内胆。
class _SendButton extends StatelessWidget {
  const _SendButton({
    required this.running,
    required this.compact,
    required this.onSend,
    required this.onStop,
  });

  final bool running;
  final bool compact;
  final VoidCallback onSend;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final size = compact ? 38.0 : 44.0;
    final color = running ? scheme.tertiary : scheme.primary;
    return Tooltip(
      message: running ? '加入排队' : '发送',
      child: Material(
        color: color.withValues(alpha: 0.92),
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onSend,
          child: SizedBox(
            width: size,
            height: size,
            child: Icon(
              running ? Icons.playlist_add_rounded : Icons.arrow_upward_rounded,
              size: compact ? 19 : 22,
              color: running ? scheme.onTertiary : scheme.onPrimary,
            ),
          ),
        ),
      ),
    );
  }
}
