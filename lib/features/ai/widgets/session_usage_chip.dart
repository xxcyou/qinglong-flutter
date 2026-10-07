import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/glass.dart';
import '../../../core/utils/formatter.dart';
import '../providers/chat_provider.dart';
import 'ai_control_sheets.dart';

/// 标题栏上的会话用量牌：这个会话花了多少 token、发了多少次请求。
///
/// 现在把 token 按“输入 / 输出 / 缓存”分类展示，都是会话累计值（加出来的），
/// 运行中还会把当前这轮已经回来的分类累计也加上。
/// 空间有限：只用 ↓ ↑ ⚡ 三个小符号 + 紧凑数字，不写长标签。
class SessionUsageChip extends ConsumerWidget {
  const SessionUsageChip({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    // 只订阅这几个数：整份 ChatState 每 80ms 就会因流式文字变一次，
    // 照它重建的话这块牌子会跟着抖。
    final input =
        ref.watch(chatProvider.select((s) => s.liveSessionInputTokens));
    final output =
        ref.watch(chatProvider.select((s) => s.liveSessionOutputTokens));
    final cache =
        ref.watch(chatProvider.select((s) => s.liveSessionCacheTokens));
    final total = ref.watch(chatProvider.select((s) => s.liveSessionTokens));
    final requests = ref.watch(chatProvider.select((s) => s.sessionRequests));
    final liveTurn = ref.watch(chatProvider.select((s) => s.liveTurn));
    final running = ref.watch(chatProvider.select((s) => s.isLoading));

    // 运行中：把当前这一轮也算上，用户看到的数字才是"此刻"的。
    final totalRequests = requests + liveTurn;

    // 一次都还没跑过就不显示，避免新会话刚打开就顶着 0 tok · 0 次。
    if (total == 0 && totalRequests == 0) return const SizedBox.shrink();

    // 有些接口只回传 totalTokens、不回传 input/output 分类：
    // 有分类就展示分类，没有分类就退回总 token。
    final hasBreakdown = input + output > 0;

    final strong = TextStyle(
      fontSize: 12,
      height: 1.15,
      fontWeight: FontWeight.w700,
      color: scheme.primary.withValues(alpha: 0.92),
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    final weak = TextStyle(
      fontSize: 10.5,
      height: 1.15,
      fontWeight: FontWeight.w500,
      color: scheme.onSurfaceVariant.withValues(alpha: 0.72),
    );

    String tooltip() {
      final buf = StringBuffer();
      if (hasBreakdown) {
        buf.write('本会话累计：↓输入 ${Formatter.tokens(input)}');
        buf.write(' · ↑输出 ${Formatter.tokens(output)}');
        if (cache > 0) buf.write(' · ⚡缓存 ${Formatter.tokens(cache)}');
      } else if (total > 0) {
        buf.write('本会话累计 ${Formatter.tokens(total)} tokens');
      }
      if (totalRequests > 0) {
        buf.write(' · $totalRequests 次请求');
      }
      if (running) buf.write('（含正在跑的第 $liveTurn 轮）');
      buf.write('\n点一下看上下文占用与上限');
      return buf.toString();
    }

    // 屏幕宽度不同时动态限制最大宽度：先给右侧 5 个动作按钮留出约 200px，
    // 剩下的宽度才是用量牌的可用空间，再交给 FittedBox 等比缩放。
    // 窄屏自动缩小（必要时隐藏缓存，优先保输入/输出），宽屏保持自然大小。
    final maxWidth =
        (MediaQuery.sizeOf(context).width - 200.0).clamp(90.0, 320.0);
    final showCache = cache > 0 && maxWidth >= 145;

    return Tooltip(
      message: tooltip(),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: GlassPanel(
            radius: 14,
            blur: 10,
            shadowY: 2,
            opacity: 0.62,
            borderWidth: 0.8,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            onTap: () => AiControlSheets.showContext(context, ref),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  running ? Icons.blur_on : Icons.data_saver_off,
                  size: 13,
                  color: scheme.primary.withValues(
                    alpha: running ? 0.95 : 0.6,
                  ),
                ),
                const SizedBox(width: 5),
                if (hasBreakdown) ...[
                  _UsageItem(
                    icon: Icons.arrow_downward,
                    iconColor: Colors.lightBlueAccent,
                    value: input,
                    style: strong,
                  ),
                  Text(' · ', style: weak),
                  _UsageItem(
                    icon: Icons.arrow_upward,
                    iconColor: Colors.orangeAccent,
                    value: output,
                    style: strong,
                  ),
                  if (showCache) ...[
                    Text(' · ', style: weak),
                    _UsageItem(
                      icon: Icons.bolt,
                      iconColor: Colors.purpleAccent,
                      value: cache,
                      style: strong,
                    ),
                  ],
                ] else if (total > 0) ...[
                  _AnimatedCountText(
                    value: total,
                    style: strong,
                    format: Formatter.tokens,
                  ),
                  Text(' tok', style: weak),
                ],
                Text('  ·  ', style: weak),
                _AnimatedCountText(
                  value: totalRequests,
                  style: strong,
                  format: Formatter.count,
                ),
                Text(' 次', style: weak),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _UsageItem extends StatelessWidget {
  const _UsageItem({
    required this.icon,
    required this.iconColor,
    required this.value,
    required this.style,
  });

  final IconData icon;
  final Color iconColor;
  final int value;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 11, color: iconColor),
        const SizedBox(width: 2),
        _AnimatedCountText(
          value: value,
          style: style,
          format: Formatter.tokens,
        ),
      ],
    );
  }
}

/// 数值跳动：token/次数变化时用 Tween 平滑滚过去，而不是生硬地跳数字。
class _AnimatedCountText extends StatelessWidget {
  const _AnimatedCountText({
    required this.value,
    required this.style,
    required this.format,
  });

  final int value;
  final TextStyle style;
  final String Function(int value) format;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(end: value.toDouble()),
      duration: const Duration(milliseconds: 950),
      curve: Curves.easeOutBack,
      builder: (context, animated, _) => Text(
        format(animated.round()),
        style: style,
      ),
    );
  }
}
