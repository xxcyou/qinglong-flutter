import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/debug/api_debug_log.dart';
import '../../../core/debug/api_debug_provider.dart';
import '../../../shared/ask_ai.dart';
import '../../../shared/glass_scaffold.dart';
import '../../panels/providers/panel_list_provider.dart';
import '../../../shared/mono_text.dart';

class ApiDebugPage extends ConsumerWidget {
  const ApiDebugPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final log = ref.watch(apiDebugProvider);
    final panel = ref.watch(currentPanelProvider);

    return GlassScaffold(
      title: 'API 调试日志',
      actions: [
        AskAiButton(
          label: 'API 调试日志',
          source: 'api_debug_log',
          contentBuilder: () => log.export(),
          draft: '帮我分析这些 API 日志，看看哪里出了问题',
        ),
        IconButton(
          tooltip: '复制日志',
          onPressed: () {
            final text = log.export();
            Clipboard.setData(ClipboardData(text: text));
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('已复制 ${log.entries.length} 条日志')),
            );
          },
          icon: const Icon(Icons.copy_all_outlined),
        ),
        IconButton(
          tooltip: '清空',
          onPressed: log.clear,
          icon: const Icon(Icons.delete_sweep_outlined),
        ),
      ],
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: GlassCard(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '当前面板：${panel?.name ?? '未选择'}',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    panel?.baseUrl ?? '空',
                    style: TextStyle(
                      fontFamily: kMonoFamily,
                      fontFamilyFallback: kMonoFallback,
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '日志共 ${log.entries.length} 条，保留最近 ${ApiDebugLog.maxEntries} 条',
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
          Expanded(
            child: log.entries.isEmpty
                ? const Center(child: Text('暂无 API 日志'))
                : ListView.separated(
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 44),
                    itemCount: log.entries.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 8),
                    itemBuilder: (context, index) {
                      final e = log.entries[index];
                      return _ApiDebugTile(entry: e);
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class _ApiDebugTile extends StatelessWidget {
  const _ApiDebugTile({required this.entry});

  final ApiDebugEntry entry;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = switch (entry.kind) {
      ApiDebugKind.request => scheme.primary,
      ApiDebugKind.response => Colors.green.shade600,
      ApiDebugKind.error => scheme.error,
    };

    return GlassCard(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(entry.kind.icon, size: 16, color: color),
              const SizedBox(width: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  entry.kind.label,
                  style: TextStyle(
                    fontSize: 12,
                    color: color,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  entry.method,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
              Text(
                entry.timeText,
                style: TextStyle(fontSize: 12, color: scheme.outline),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            entry.uri,
            style: const TextStyle(
                fontFamily: kMonoFamily,
                fontFamilyFallback: kMonoFallback,
                fontSize: 12),
          ),
          if (entry.statusCode != null || entry.durationMs != null) ...[
            const SizedBox(height: 4),
            Wrap(
              spacing: 8,
              children: [
                if (entry.statusCode != null)
                  Text(
                    'HTTP ${entry.statusCode}',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: entry.statusCode! >= 400
                          ? scheme.error
                          : Colors.green.shade600,
                    ),
                  ),
                if (entry.durationMs != null)
                  Text(
                    '${entry.durationMs}ms',
                    style: TextStyle(fontSize: 12, color: scheme.outline),
                  ),
              ],
            ),
          ],
          if (entry.message != null && entry.message!.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(entry.message!, style: const TextStyle(fontSize: 13)),
          ],
          if (entry.detail != null && entry.detail!.isNotEmpty) ...[
            const SizedBox(height: 4),
            SelectableText(
              entry.detail!,
              style: TextStyle(
                fontFamily: kMonoFamily,
                fontFamilyFallback: kMonoFallback,
                fontSize: 12,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
