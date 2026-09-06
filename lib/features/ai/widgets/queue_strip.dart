import 'package:flutter/material.dart';

import '../../../core/theme/glass.dart';
import '../models/chat_runtime.dart';

/// 排队条：AI 还在跑时继续输入的消息都停在这里。
///
/// 支持长按拖拽改顺序、点一下置顶、左边按钮"中断当前任务立即发送"。
/// 这样急事不用等 AI 把当前任务跑完。
class QueueStrip extends StatelessWidget {
  const QueueStrip({
    super.key,
    required this.queue,
    required this.onReorder,
    required this.onRemove,
    required this.onInterruptSend,
    this.compact = false,
    this.margin = const EdgeInsets.fromLTRB(10, 0, 10, 6),
  });

  final List<QueuedMessage> queue;
  final void Function(int oldIndex, int newIndex) onReorder;
  final ValueChanged<String> onRemove;
  final ValueChanged<String> onInterruptSend;
  final bool compact;
  final EdgeInsetsGeometry margin;

  @override
  Widget build(BuildContext context) {
    if (queue.isEmpty) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    // 一条时不必给拖拽列表，省一半高度。
    final rowHeight = compact ? 40.0 : 46.0;
    final listHeight = (queue.length.clamp(1, 3)) * rowHeight;

    return Padding(
      padding: margin,
      child: GlassPanel(
        radius: 18,
        blur: 16,
        shadowY: 4,
        padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.playlist_play, size: 15, color: scheme.tertiary),
                const SizedBox(width: 5),
                Text(
                  '排队 ${queue.length} 条 · 长按拖动改顺序',
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                    color: scheme.tertiary,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 2),
            SizedBox(
              height: listHeight,
              child: ReorderableListView.builder(
                buildDefaultDragHandles: false,
                padding: EdgeInsets.zero,
                itemCount: queue.length,
                onReorder: (oldIndex, newIndex) {
                  // ReorderableListView 的 newIndex 是"插入点"，往下拖要减 1。
                  onReorder(
                    oldIndex,
                    newIndex > oldIndex ? newIndex - 1 : newIndex,
                  );
                },
                itemBuilder: (context, index) {
                  final item = queue[index];
                  return ReorderableDragStartListener(
                    key: ValueKey(item.id),
                    index: index,
                    child: SizedBox(
                      height: rowHeight,
                      child: Row(
                        children: [
                          IconButton(
                            tooltip: '中断当前任务，立即发送这条',
                            visualDensity: VisualDensity.compact,
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(
                              minWidth: 30,
                              minHeight: 30,
                            ),
                            onPressed: () => onInterruptSend(item.id),
                            icon: Icon(
                              Icons.flash_on,
                              size: 17,
                              color: scheme.error,
                            ),
                          ),
                          Container(
                            width: 18,
                            alignment: Alignment.center,
                            child: Text(
                              '${index + 1}',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                          Expanded(
                            child: Text(
                              item.text.replaceAll('\n', ' '),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(fontSize: compact ? 12 : 13),
                            ),
                          ),
                          IconButton(
                            tooltip: '取消这条',
                            visualDensity: VisualDensity.compact,
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(
                              minWidth: 30,
                              minHeight: 30,
                            ),
                            onPressed: () => onRemove(item.id),
                            icon: const Icon(Icons.close, size: 16),
                          ),
                          Icon(
                            Icons.drag_handle,
                            size: 16,
                            color:
                                scheme.onSurfaceVariant.withValues(alpha: 0.6),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 崩溃恢复条：上次运行被打断，可以一键继续。
class ResumeStrip extends StatelessWidget {
  const ResumeStrip({
    super.key,
    required this.run,
    required this.onResume,
    required this.onDiscard,
    this.margin = const EdgeInsets.fromLTRB(10, 0, 10, 6),
  });

  final InterruptedRun run;
  final VoidCallback onResume;
  final VoidCallback onDiscard;
  final EdgeInsetsGeometry margin;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final toolCount = run.events
        .where((e) => e.toolName != null && e.toolName!.isNotEmpty)
        .map((e) => e.toolName)
        .toSet()
        .length;
    return Padding(
      padding: margin,
      child: GlassPanel(
        radius: 18,
        blur: 18,
        shadowY: 5,
        padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.history_toggle_off, size: 17, color: scheme.primary),
                const SizedBox(width: 6),
                Text(
                  '上次任务被中断了',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: scheme.primary,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              run.userInput.replaceAll('\n', ' '),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 13),
            ),
            const SizedBox(height: 2),
            Text(
              '已完成 ${run.events.length} 个步骤'
              '${toolCount > 0 ? '，用过 $toolCount 种工具' : ''}'
              '（过程见下方卡片）',
              style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                FilledButton.tonalIcon(
                  onPressed: onResume,
                  style: FilledButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                  ),
                  icon: const Icon(Icons.play_arrow_rounded, size: 18),
                  label: const Text('继续'),
                ),
                const SizedBox(width: 8),
                TextButton(
                  onPressed: onDiscard,
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                  ),
                  child: const Text('放弃'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
