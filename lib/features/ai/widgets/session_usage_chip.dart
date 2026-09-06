import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/glass.dart';
import '../../../core/utils/formatter.dart';
import '../providers/chat_provider.dart';
import 'ai_control_sheets.dart';

/// 标题栏上的会话用量牌：这个会话花了多少 token、发了多少次请求。
///
/// 为什么要单独有它：原来只有一个"上下文 45%"的百分比，看不出"这一整个会话
/// 到底烧了多少"。而计费是按累计 token 走的（每一轮都会重发历史），所以
/// 会话累计和上下文占用是两个数量级不同的数字，必须分开显示。
///
/// 表现上是一块半透明玻璃 + 富文本：数字用主色加粗、单位和"次"淡一号，
/// 运行中会把正在跑的这一轮算进去，所以它是活的。
class SessionUsageChip extends ConsumerWidget {
  const SessionUsageChip({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    // 只订阅这四个数：整份 ChatState 每 80ms 就会因流式文字变一次，
    // 照它重建的话这块牌子会跟着抖。
    final tokens = ref.watch(chatProvider.select((s) => s.sessionTokens));
    final requests = ref.watch(chatProvider.select((s) => s.sessionRequests));
    final liveTurn = ref.watch(chatProvider.select((s) => s.liveTurn));
    final running = ref.watch(chatProvider.select((s) => s.isLoading));

    // 运行中：把当前这一轮也算上，用户看到的数字才是"此刻"的。
    final totalRequests = requests + liveTurn;
    if (tokens == 0 && totalRequests == 0) return const SizedBox.shrink();

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

    // 一行字放不下解释，长按给全文。
    return Tooltip(
      message: '本会话累计 $tokens tokens、$totalRequests 次请求'
          '${running ? '（含正在跑的第 $liveTurn 轮）' : ''}\n'
          '点一下看上下文占用与上限',
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
              color: scheme.primary.withValues(alpha: running ? 0.95 : 0.6),
            ),
            const SizedBox(width: 5),
            RichText(
              textAlign: TextAlign.right,
              text: TextSpan(
                children: [
                  TextSpan(text: Formatter.tokens(tokens), style: strong),
                  TextSpan(text: ' tok', style: weak),
                  TextSpan(text: '  ·  ', style: weak),
                  TextSpan(
                    text: Formatter.count(totalRequests),
                    style: strong,
                  ),
                  TextSpan(text: ' 次', style: weak),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
