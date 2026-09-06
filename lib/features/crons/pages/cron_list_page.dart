import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/glass.dart';
import '../../../core/utils/error_text.dart';
import '../../../core/utils/logger.dart';
import '../../../shared/ask_ai.dart';
import '../../../shared/confirm_dialog.dart';
import '../../../shared/empty_view.dart';
import '../../../shared/error_view.dart';
import '../../../shared/glass_scaffold.dart';
import '../../../shared/loading_view.dart';
import '../../../shared/search_field.dart';
import '../../panels/providers/panel_list_provider.dart';
import '../../scripts/pages/script_edit_page.dart';
import '../../settings/providers/settings_provider.dart';
import '../models/cron_task.dart';
import '../providers/cron_list_provider.dart';
import '../widgets/cron_run_log_sheet.dart';
import '../widgets/cron_tile.dart';
import 'cron_edit_page.dart';
import 'cron_log_page.dart';

class CronListPage extends ConsumerStatefulWidget {
  const CronListPage({super.key});

  @override
  ConsumerState<CronListPage> createState() => _CronListPageState();
}

class _CronListPageState extends ConsumerState<CronListPage> {
  final _searchController = TextEditingController();
  final _scrollController = ScrollController();
  final Set<int> _selectedIds = {};
  Timer? _pollTimer;

  bool get _selecting => _selectedIds.isNotEmpty;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    Future.microtask(() => ref.read(cronListProvider.notifier).loadFirst());
    _startPolling();
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _searchController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _startPolling() {
    _pollTimer?.cancel();
    final interval = ref.read(settingsProvider).pollIntervalSeconds;
    _pollTimer = Timer.periodic(
      Duration(seconds: interval),
      (_) {
        if (!mounted) return;
        final currentPanel = ref.read(currentPanelProvider);
        if (currentPanel != null) {
          final notifier = ref.read(cronListProvider.notifier);
          if (ref.read(cronListProvider).items.any(
                (t) => t.pid != null && t.pid != 0,
              )) {
            notifier.refresh();
          }
        }
      },
    );
  }

  void _onScroll() {
    if (_scrollController.position.pixels >=
        _scrollController.position.maxScrollExtent - 300) {
      ref.read(cronListProvider.notifier).loadMore();
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(cronListProvider);
    final currentPanel = ref.watch(currentPanelProvider);
    final notifier = ref.read(cronListProvider.notifier);

    // 未选面板时整页为空态。
    if (currentPanel == null) {
      return const GlassScaffold(
        title: '定时任务',
        body: EmptyView(message: '请先添加并切换面板'),
      );
    }

    final visibleItems = state.items.where((t) {
      if (state.filter == CronFilter.enabled && t.isDisabled) return false;
      if (state.filter == CronFilter.disabled && !t.isDisabled) return false;
      if (state.filter == CronFilter.running && (t.pid == null || t.pid == 0)) {
        return false;
      }
      return true;
    }).toList();

    return GlassScaffold(
      title: '定时任务',
      subtitle: state.total > 0
          ? '共 ${state.total} 个任务'
          : '共 ${visibleItems.length} 个任务',
      // 搜索框挤进动作行，筛选 chips 单独一排：比原来的"额头"省一半高度。
      headerInline: SearchField(
        controller: _searchController,
        hintText: '搜索任务名称/命令',
        onChanged: notifier.setSearch,
      ),
      headerBottom: Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
        child: SizedBox(
          height: 34,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: CronFilter.values.length,
            separatorBuilder: (_, __) => const SizedBox(width: 8),
            itemBuilder: (context, index) {
              final f = CronFilter.values[index];
              return ChoiceChip(
                label: Text(f.label),
                selected: state.filter == f,
                onSelected: (_) => notifier.setFilter(f),
              );
            },
          ),
        ),
      ),
      actions: [
        if (_selecting)
          IconButton(
            tooltip: '取消选择',
            onPressed: () => setState(_selectedIds.clear),
            icon: const Icon(Icons.close),
          )
        else
          IconButton(
            tooltip: '新建任务',
            onPressed: () => _openEdit(context),
            icon: const Icon(Icons.add),
          ),
      ],
      floatingActionButton: _selecting
          ? null
          : FloatingActionButton(
              onPressed: () => _openEdit(context),
              child: const Icon(Icons.add),
            ),
      bottomBar: _selecting
          ? _SelectionActionBar(
              selectedCount: _selectedIds.length,
              onRun: () => _batch(notifier.run),
              onStop: () => _batch(notifier.stop),
              onEnable: () => _batch((ids) => notifier.setEnabled(ids, true)),
              onDisable: () => _batch((ids) => notifier.setEnabled(ids, false)),
              onDelete: _deleteSelected,
            )
          : null,
      body: _buildBody(state, visibleItems),
    );
  }

  Widget _buildBody(CronListState state, List<CronTask> items) {
    if (state.isLoading && items.isEmpty) {
      return const LoadingView();
    }
    if (state.error != null && items.isEmpty) {
      return ErrorView(
        message: errorText(state.error!),
        onRetry: () => ref.read(cronListProvider.notifier).refresh(),
      );
    }
    if (items.isEmpty) {
      return EmptyView(
        message: state.search.isNotEmpty ? '没有匹配的任务' : '暂无定时任务\n点击右下角 + 新建',
        icon: Icons.event_note_outlined,
      );
    }

    return RefreshIndicator(
      onRefresh: () => ref.read(cronListProvider.notifier).refresh(),
      child: ListView.separated(
        controller: _scrollController,
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 110),
        itemCount: items.length + (state.isLoadingMore ? 1 : 0),
        separatorBuilder: (_, index) => index == items.length
            ? const SizedBox.shrink()
            : const SizedBox(height: 8),
        itemBuilder: (context, index) {
          if (index == items.length) {
            return const Padding(
              padding: EdgeInsets.all(16),
              child: Center(
                child: SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            );
          }
          final task = items[index];
          return CronTile(
            task: task,
            selected: _selectedIds.contains(task.id),
            onTap: () {
              if (_selecting) {
                setState(() {
                  if (task.id == null) return;
                  if (!_selectedIds.remove(task.id)) _selectedIds.add(task.id!);
                });
              } else {
                _openEdit(context, task: task);
              }
            },
            onLongPress: () {
              if (task.id != null) {
                setState(() => _selectedIds.add(task.id!));
              }
            },
            onRun: () => _runOne(task),
            onStop: () => _batch(ref.read(cronListProvider.notifier).stop,
                ids: [task.id!]),
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
            onDelete: () => _deleteOne(task),
            onSendToAi: () => _sendToAi(task),
            onOpenScript: _extractScriptPath(task) == null
                ? null
                : () => _openScript(task),
          );
        },
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

  void _openScript(CronTask task) {
    final path = _extractScriptPath(task);
    if (path == null || !mounted) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ScriptEditPage(path: path),
      ),
    );
  }

  void _sendToAi(CronTask task) {
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

  Future<void> _openEdit(BuildContext context, {CronTask? task}) async {
    final messenger = ScaffoldMessenger.of(context);
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
    if (saved == true) {
      messenger.showSnackBar(
        SnackBar(content: Text(task == null ? '任务已创建' : '任务已更新')),
      );
    }
  }

  /// 单个任务运行：发指令 + 立刻弹实时日志，别让用户猜有没有跑。
  Future<void> _runOne(CronTask task) async {
    final id = task.id;
    if (id == null) return;
    try {
      await ref.read(cronListProvider.notifier).run([id]);
      if (!mounted) return;
      await CronRunLogSheet.show(
        context,
        cronId: id,
        taskName: task.name,
      );
    } catch (e) {
      if (mounted) Logger.showError(context, e);
    }
  }

  Future<void> _batch(
    Future<void> Function(List<int> ids) action, {
    List<int>? ids,
  }) async {
    final target = ids ?? _selectedIds.toList();
    if (target.isEmpty) return;
    try {
      await action(target);
      if (mounted) {
        setState(_selectedIds.clear);
      }
    } catch (e) {
      if (mounted) Logger.showError(context, e);
    }
  }

  Future<void> _deleteOne(CronTask task) async {
    final ok = await showConfirmDialog(
      context,
      title: '删除任务',
      message: '确定删除「${task.name}」？',
      confirmText: '删除',
      destructive: true,
    );
    if (ok) {
      await _batch(ref.read(cronListProvider.notifier).delete, ids: [task.id!]);
    }
  }

  Future<void> _deleteSelected() async {
    final ok = await showConfirmDialog(
      context,
      title: '批量删除',
      message: '确定删除选中的 ${_selectedIds.length} 个任务？',
      confirmText: '删除',
      destructive: true,
    );
    if (ok) {
      await _batch(ref.read(cronListProvider.notifier).delete);
    }
  }
}

class _SelectionActionBar extends StatelessWidget {
  const _SelectionActionBar({
    required this.selectedCount,
    required this.onRun,
    required this.onStop,
    required this.onEnable,
    required this.onDisable,
    required this.onDelete,
  });

  final int selectedCount;
  final VoidCallback onRun;
  final VoidCallback onStop;
  final VoidCallback onEnable;
  final VoidCallback onDisable;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    return GlassPanel(
      radius: 22,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: Row(
        children: [
          Text('已选 $selectedCount',
              style: const TextStyle(fontWeight: FontWeight.w600)),
          const Spacer(),
          _BarButton(icon: Icons.play_arrow, tooltip: '运行', onTap: onRun),
          _BarButton(icon: Icons.stop, tooltip: '停止', onTap: onStop),
          _BarButton(
              icon: Icons.check_circle_outline, tooltip: '启用', onTap: onEnable),
          _BarButton(icon: Icons.block, tooltip: '禁用', onTap: onDisable),
          _BarButton(
              icon: Icons.delete_outline,
              tooltip: '删除',
              onTap: onDelete,
              danger: true),
        ],
      ),
    );
  }
}

class _BarButton extends StatelessWidget {
  const _BarButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.danger = false,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      onPressed: onTap,
      tooltip: tooltip,
      visualDensity: VisualDensity.compact,
      icon: Icon(icon,
          color: danger ? Theme.of(context).colorScheme.error : null),
    );
  }
}
