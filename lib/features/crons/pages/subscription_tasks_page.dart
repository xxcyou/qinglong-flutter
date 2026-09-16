import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/utils/logger.dart';
import '../../../shared/ask_ai.dart';
import '../../../shared/confirm_dialog.dart';
import '../../../shared/empty_view.dart';
import '../../../shared/glass_scaffold.dart';
import '../../../shared/loading_view.dart';
import '../../scripts/pages/script_edit_page.dart';
import '../models/cron_task.dart';
import '../providers/cron_list_provider.dart';
import '../widgets/cron_run_log_sheet.dart';
import '../widgets/cron_tile.dart';
import 'cron_edit_page.dart';
import 'cron_log_page.dart';

/// 单个订阅下的任务二级页。
///
/// 用独立的 ListView.builder 而不是在任务页里内联展开，滚动/展开只构建
/// 当前屏幕可见的任务卡片，避免一个订阅几十个任务把整页卡死。
class SubscriptionTasksPage extends ConsumerWidget {
  const SubscriptionTasksPage({
    super.key,
    required this.subId,
    required this.subName,
  });

  final int subId;
  final String subName;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(cronListProvider);
    final tasks = state.items.where((t) => t.subId == subId).toList();

    return GlassScaffold(
      title: subName,
      subtitle: '${tasks.length} 个订阅任务',
      body: tasks.isEmpty
          ? (state.isLoading
              ? const LoadingView()
              : const EmptyView(message: '这个订阅下暂无任务'))
          : RefreshIndicator(
              onRefresh: () => ref.read(cronListProvider.notifier).refresh(),
              child: ListView.builder(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 110),
                itemCount: tasks.length,
                itemBuilder: (context, index) {
                  final task = tasks[index];
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: CronTile(
                      task: task,
                      selected: false,
                      onTap: () => _openEdit(context, ref, task: task),
                      onLongPress: () {},
                      onRun: () => _runOne(context, ref, task),
                      onStop: () => _batch(
                        context,
                        ref,
                        (ids) => ref.read(cronListProvider.notifier).stop(ids),
                        ids: [task.id!],
                      ),
                      onLog: task.id == null
                          ? () {}
                          : () => Navigator.of(context).push(
                                MaterialPageRoute(
                                  builder: (_) => CronLogPage(
                                    cronId: task.id!,
                                    taskName: task.name,
                                    logPath: task.logPath,
                                  ),
                                ),
                              ),
                      onDelete: () => _deleteOne(context, ref, task),
                      onSendToAi: () => _sendToAi(ref, task),
                      onOpenScript: _extractScriptPath(task) == null
                          ? null
                          : () => _openScript(context, task),
                    ),
                  );
                },
              ),
            ),
    );
  }

  String? _extractScriptPath(CronTask task) {
    final command = task.command.trim();
    var file = command;
    if (command.startsWith('task ')) {
      file = command.substring(5).trim().split(RegExp(r'\s+')).first;
    } else if (command.startsWith('python3 ') ||
        command.startsWith('python ')) {
      file = command.split(RegExp(r'\s+')).skip(1).first;
    }
    if (file.isEmpty) return null;
    final lower = file.toLowerCase();
    if (lower.endsWith('.js') ||
        lower.endsWith('.py') ||
        lower.endsWith('.ts') ||
        lower.endsWith('.sh')) {
      return file;
    }
    return null;
  }

  void _openScript(BuildContext context, CronTask task) {
    final path = _extractScriptPath(task);
    if (path == null) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ScriptEditPage(path: path),
      ),
    );
  }

  void _sendToAi(WidgetRef ref, CronTask task) {
    AskAi.push(
      ref,
      label: '定时任务：${task.name}',
      content: '任务名称：${task.name}\n'
          '命令：${task.command}\n'
          '计划：${task.schedule}\n'
          '状态：${task.isDisabled ? '禁用' : '启用'}\n'
          '最近结果：${task.lastResult == null || task.lastResult!.isEmpty ? '暂无' : task.lastResult}\n'
          '标签：${task.labels.isEmpty ? '无' : task.labels.join('、')}',
      source: 'cron',
      draft: '帮我分析这个定时任务，是否有问题、能不能优化',
    );
  }

  Future<void> _openEdit(
    BuildContext context,
    WidgetRef ref, {
    CronTask? task,
  }) async {
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => CronEditPage(
          task: task,
          onSubmit: (value) async {
            if (task == null) {
              await ref.read(cronListProvider.notifier).create(value);
            } else {
              await ref.read(cronListProvider.notifier).update(value);
            }
          },
        ),
      ),
    );
    if (saved == true && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(task == null ? '任务已创建' : '任务已更新')),
      );
    }
  }

  Future<void> _runOne(
    BuildContext context,
    WidgetRef ref,
    CronTask task,
  ) async {
    final id = task.id;
    if (id == null) return;
    try {
      await ref.read(cronListProvider.notifier).run([id]);
      if (!context.mounted) return;
      await CronRunLogSheet.show(
        context,
        cronId: id,
        taskName: task.name,
      );
    } catch (e) {
      if (context.mounted) Logger.showError(context, e);
    }
  }

  Future<void> _batch(
    BuildContext context,
    WidgetRef ref,
    Future<void> Function(List<int> ids) action, {
    List<int>? ids,
  }) async {
    final target = ids ?? const <int>[];
    if (target.isEmpty) return;
    try {
      await action(target);
    } catch (e) {
      if (context.mounted) Logger.showError(context, e);
    }
  }

  Future<void> _deleteOne(
    BuildContext context,
    WidgetRef ref,
    CronTask task,
  ) async {
    final ok = await showConfirmDialog(
      context,
      title: '删除任务',
      message: '确定删除「${task.name}」？',
      confirmText: '删除',
      destructive: true,
    );
    if (!ok) return;
    try {
      await ref.read(cronListProvider.notifier).delete([task.id!]);
    } catch (e) {
      if (context.mounted) Logger.showError(context, e);
    }
  }
}
