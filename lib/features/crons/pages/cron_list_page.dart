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
import '../../scripts/api/script_api.dart';
import '../../subscriptions/providers/subscription_list_provider.dart';
import '../../scripts/pages/script_edit_page.dart';
import '../../settings/providers/settings_provider.dart';
import '../api/cron_api.dart';
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
    Future.microtask(() {
      ref.read(cronListProvider.notifier).loadFirst();
      if (ref.read(currentPanelProvider) != null) {
        ref.read(subListProvider.notifier).load();
      }
    });
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
    final subState = ref.watch(subListProvider);
    final subNames = <int, String>{
      for (final sub in subState.items)
        if (sub.id != null) sub.id!: sub.name.isNotEmpty ? sub.name : sub.alias,
    };
    final notifier = ref.read(cronListProvider.notifier);

    // 未选面板时整页为空态。
    if (currentPanel == null) {
      return const GlassScaffold(
        title: '定时任务',
        body: EmptyView(message: '请先添加并切换面板'),
      );
    }

    final allTags = <String>{
      for (final t in state.items) ...t.labels,
    };
    var visibleItems = state.items.where((t) {
      if (state.filter == CronFilter.enabled && t.isDisabled) return false;
      if (state.filter == CronFilter.disabled && !t.isDisabled) return false;
      if (state.filter == CronFilter.running && (t.pid == null || t.pid == 0)) {
        return false;
      }
      return true;
    }).toList();
    if (state.viewMode == CronViewMode.tag &&
        state.selectedTag != null &&
        state.selectedTag!.isNotEmpty) {
      visibleItems = visibleItems
          .where((t) => t.labels.contains(state.selectedTag))
          .toList();
    }

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
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              height: 32,
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
            const SizedBox(height: 4),
            SizedBox(
              height: 30,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: CronViewMode.values.length,
                separatorBuilder: (_, __) => const SizedBox(width: 8),
                itemBuilder: (context, index) {
                  final mode = CronViewMode.values[index];
                  return ChoiceChip(
                    label: Text(mode.label),
                    selected: state.viewMode == mode,
                    onSelected: (_) {
                      notifier.setViewMode(mode);
                      if (mode != CronViewMode.tag) {
                        notifier.setSelectedTag(null);
                      }
                    },
                  );
                },
              ),
            ),
            if (state.viewMode == CronViewMode.tag) ...[
              const SizedBox(height: 4),
              SizedBox(
                height: 30,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: allTags.length + 1,
                  separatorBuilder: (_, __) => const SizedBox(width: 6),
                  itemBuilder: (context, index) {
                    if (index == 0) {
                      return ChoiceChip(
                        label: const Text('全部标签'),
                        selected: state.selectedTag == null,
                        onSelected: (_) => notifier.setSelectedTag(null),
                      );
                    }
                    final tag = allTags.elementAt(index - 1);
                    return ChoiceChip(
                      label: Text(tag),
                      selected: state.selectedTag == tag,
                      onSelected: (_) => notifier.setSelectedTag(tag),
                    );
                  },
                ),
              ),
            ],
          ],
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
      body: _buildBody(state, visibleItems, subNames),
    );
  }

  Widget _buildBody(
    CronListState state,
    List<CronTask> items,
    Map<int, String> subNames,
  ) {
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
        message: state.viewMode == CronViewMode.tag && state.selectedTag != null
            ? '该标签下没有任务'
            : state.search.isNotEmpty
                ? '没有匹配的任务'
                : '暂无定时任务\n点击右下角 + 新建',
        icon: Icons.event_note_outlined,
      );
    }

    if (state.viewMode == CronViewMode.source) {
      return _buildSourceBody(state, items, subNames);
    }
    return _buildFlatBody(state, items);
  }

  Widget _buildFlatBody(CronListState state, List<CronTask> items) {
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
            return const _LoadingMoreItem();
          }
          return _taskTile(context, items[index]);
        },
      ),
    );
  }

  Widget _buildSourceBody(
    CronListState state,
    List<CronTask> items,
    Map<int, String> subNames,
  ) {
    final groups = _sourceSubGroups(items, subNames);
    if (groups.isEmpty) {
      return const EmptyView(
        message: '当前已加载的任务里没有订阅任务\n可在「管理 → 订阅管理」添加订阅',
        icon: Icons.cloud_outlined,
      );
    }

    return RefreshIndicator(
      onRefresh: () => ref.read(cronListProvider.notifier).refresh(),
      child: ListView.separated(
        controller: _scrollController,
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 110),
        itemCount: groups.length + (state.isLoadingMore ? 1 : 0),
        separatorBuilder: (_, index) => index == groups.length
            ? const SizedBox.shrink()
            : const SizedBox(height: 8),
        itemBuilder: (context, index) {
          if (index == groups.length) {
            return const _LoadingMoreItem();
          }
          final group = groups[index];
          return _SubscriptionTile(
            name: group.title,
            tasks: group.tasks,
            onDelete: () => _deleteSubscription(
              group.subId!,
              group.title,
              group.tasks,
            ),
            taskBuilder: (task) => _taskTile(context, task),
          );
        },
      ),
    );
  }

  List<_TaskGroup> _sourceSubGroups(
    List<CronTask> items,
    Map<int, String> subNames,
  ) {
    final bySub = <int, List<CronTask>>{};
    for (final task in items) {
      final subId = task.subId;
      if (subId == null) continue;
      bySub.putIfAbsent(subId, () => []).add(task);
    }

    final subIds = bySub.keys.toList()
      ..sort((a, b) {
        final na = (subNames[a] ?? '').toLowerCase();
        final nb = (subNames[b] ?? '').toLowerCase();
        return na.compareTo(nb);
      });
    return [
      for (final subId in subIds)
        _TaskGroup(subNames[subId] ?? '订阅 #$subId', bySub[subId]!,
            subId: subId),
    ];
  }

  /// 删除订阅前先确认，并可选连它带来的任务和脚本文件一起清掉。
  Future<void> _deleteSubscription(
    int subId,
    String subName,
    List<CronTask> loadedTasks,
  ) async {
    var deleteAssociated = false;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setInner) => AlertDialog(
          title: Text('删除订阅「$subName」？'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('订阅记录会被永久删除。'),
              const SizedBox(height: 8),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                value: deleteAssociated,
                onChanged: (v) => setInner(() => deleteAssociated = v ?? false),
                title: const Text(
                  '同时删除这个订阅带来的定时任务和脚本文件',
                  style: TextStyle(fontSize: 13.5),
                ),
                subtitle: const Text(
                  '不勾选只删订阅，任务和脚本保留',
                  style: TextStyle(fontSize: 11.5),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              style: FilledButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.error,
              ),
              child: const Text('确认删除'),
            ),
          ],
        ),
      ),
    );
    if (confirmed != true || !mounted) return;

    final messenger = ScaffoldMessenger.of(context);
    try {
      // 勾选一起删时，先抓这个订阅下的全部任务，删完订阅/任务后再删脚本文件。
      final allSubTasks =
          deleteAssociated ? await _fetchAllSubTasks(subId) : <CronTask>[];
      final scriptPaths = <String>{
        for (final task in deleteAssociated ? allSubTasks : loadedTasks)
          if (_extractScriptPath(task) != null) _extractScriptPath(task)!,
      };

      await ref.read(subListProvider.notifier).delete(
        [subId],
        force: deleteAssociated,
      );

      if (deleteAssociated) {
        final panel = ref.read(currentPanelProvider);
        if (panel != null) {
          for (final path in scriptPaths) {
            try {
              await ScriptApi.delete(
                apiBaseUrl: panel.apiBaseUrl,
                path: path,
              );
            } catch (_) {
              // 单个脚本删不掉（可能已被订阅删除或权限限制）不阻断整体流程。
            }
          }
        }
      }

      await ref.read(cronListProvider.notifier).refresh();
      if (mounted) {
        messenger.showSnackBar(
          SnackBar(
            content: Text(
              deleteAssociated ? '已删除订阅及其任务和脚本' : '已删除订阅，任务和脚本已保留',
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) Logger.showError(context, e);
    }
  }

  Future<List<CronTask>> _fetchAllSubTasks(int subId) async {
    final panel = ref.read(currentPanelProvider);
    if (panel == null) return const [];
    const pageSize = 100;
    final result = <CronTask>[];
    var page = 1;
    while (true) {
      final batch = await CronApi.list(
        apiBaseUrl: panel.apiBaseUrl,
        page: page,
        pageSize: pageSize,
      );
      result.addAll(batch.items.where((t) => t.subId == subId));
      if (batch.items.isEmpty || batch.items.length < pageSize) break;
      page++;
    }
    return result;
  }

  Widget _taskTile(BuildContext context, CronTask task) {
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
      onStop: () =>
          _batch(ref.read(cronListProvider.notifier).stop, ids: [task.id!]),
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
      onOpenScript:
          _extractScriptPath(task) == null ? null : () => _openScript(task),
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

class _TaskGroup {
  const _TaskGroup(this.title, this.tasks, {this.subId});

  final String title;
  final List<CronTask> tasks;
  final int? subId;
}

class _SubscriptionTile extends StatelessWidget {
  const _SubscriptionTile({
    required this.name,
    required this.tasks,
    required this.onDelete,
    required this.taskBuilder,
  });

  final String name;
  final List<CronTask> tasks;
  final VoidCallback onDelete;
  final Widget Function(CronTask task) taskBuilder;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      elevation: 0,
      clipBehavior: Clip.antiAlias,
      color: scheme.surfaceContainerLow.withValues(alpha: 0.55),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(
          color: scheme.outlineVariant.withValues(alpha: 0.35),
        ),
      ),
      child: ExpansionTile(
        leading: Container(
          width: 38,
          height: 38,
          decoration: BoxDecoration(
            color: scheme.primaryContainer.withValues(alpha: 0.6),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Icon(
            Icons.cloud_download_outlined,
            size: 20,
            color: scheme.primary,
          ),
        ),
        title: Text(
          name,
          style: TextStyle(
            fontSize: 14.5,
            fontWeight: FontWeight.w700,
            color: scheme.onSurface,
          ),
        ),
        subtitle: Text(
          '${tasks.length} 个任务',
          style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              tooltip: '删除订阅',
              icon: Icon(
                Icons.delete_outline,
                size: 20,
                color: scheme.error,
              ),
              onPressed: onDelete,
            ),
            Icon(Icons.expand_more, color: scheme.onSurfaceVariant),
          ],
        ),
        expandedCrossAxisAlignment: CrossAxisAlignment.start,
        childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
        children: [
          for (final task in tasks)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: taskBuilder(task),
            ),
        ],
      ),
    );
  }
}

class _LoadingMoreItem extends StatelessWidget {
  const _LoadingMoreItem();

  @override
  Widget build(BuildContext context) {
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
