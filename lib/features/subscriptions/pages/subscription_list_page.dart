import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/glass.dart';
import '../../../core/utils/error_text.dart';
import '../../../shared/ask_ai.dart';
import '../../../shared/empty_view.dart';
import '../../../shared/error_view.dart';
import '../../../shared/glass_scaffold.dart';
import '../../../shared/loading_view.dart';
import '../../../shared/mono_text.dart';
import '../../../shared/search_field.dart';
import '../models/subscription.dart';
import '../providers/subscription_list_provider.dart';
import 'subscription_edit_page.dart';
import 'subscription_log_page.dart';

/// 订阅管理：拉脚本的入口。
///
/// 一条订阅 = 一个仓库/文件 + 拉取周期 + 白名单。点一下运行就等于网页版的
/// "立即同步"，跑的过程状态会自己从"运行中"变回"空闲"（列表在跑就 3 秒一刷）。
class SubscriptionListPage extends ConsumerStatefulWidget {
  const SubscriptionListPage({super.key});

  @override
  ConsumerState<SubscriptionListPage> createState() =>
      _SubscriptionListPageState();
}

class _SubscriptionListPageState
    extends ConsumerState<SubscriptionListPage> {
  final _searchController = TextEditingController();
  final Set<int> _selectedIds = {};

  @override
  void initState() {
    super.initState();
    Future.microtask(() => ref.read(subListProvider.notifier).load());
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(subListProvider);
    final notifier = ref.read(subListProvider.notifier);
    final items = state.visible;

    return GlassScaffold(
      title: '订阅管理',
      subtitle: '拉仓库脚本，自动建任务',
      showBack: true,
      actions: [
        if (_selectedIds.isNotEmpty)
          IconButton(
            tooltip: '取消选择',
            onPressed: () => setState(_selectedIds.clear),
            icon: const Icon(Icons.close),
          )
        else
          IconButton(
            tooltip: '新建订阅',
            onPressed: () => _openEdit(),
            icon: const Icon(Icons.add),
          ),
      ],
      headerInline: SearchField(
        controller: _searchController,
        hintText: '搜索名称 / 地址',
        onChanged: notifier.setSearch,
      ),
      headerBottom: Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
        child: SizedBox(
          height: 34,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: SubFilter.values.length,
            separatorBuilder: (_, __) => const SizedBox(width: 8),
            itemBuilder: (context, index) {
              final f = SubFilter.values[index];
              final count = state.items.where(f.matches).length;
              return ChoiceChip(
                label: Text('${f.label} $count'),
                selected: state.filter == f,
                onSelected: (_) => notifier.setFilter(f),
              );
            },
          ),
        ),
      ),
      bottomBar: _selectedIds.isEmpty
          ? null
          : _SelectionBar(
              count: _selectedIds.length,
              onRun: () => _batch(notifier.run),
              onStop: () => _batch(notifier.stop),
              onEnable: () => _batch((ids) => notifier.setEnabled(ids, true)),
              onDisable: () => _batch((ids) => notifier.setEnabled(ids, false)),
              onDelete: _deleteSelected,
            ),
      body: _buildBody(state, items),
    );
  }

  Widget _buildBody(SubListState state, List<Subscription> items) {
    if (state.isLoading && state.items.isEmpty) return const LoadingView();
    if (state.error != null && state.items.isEmpty) {
      return ErrorView(
        message: errorText(state.error!),
        onRetry: () => ref.read(subListProvider.notifier).load(force: true),
      );
    }
    if (items.isEmpty) {
      return EmptyView(
        message: state.search.isNotEmpty
            ? '没有匹配的订阅'
            : state.items.isEmpty
                ? '还没有订阅\n点右上角 + 添加一个仓库或脚本直链'
                : '这个筛选下没有订阅',
        icon: Icons.cloud_download_outlined,
      );
    }
    return RefreshIndicator(
      onRefresh: ref.read(subListProvider.notifier).refresh,
      child: ListView.separated(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 110),
        itemCount: items.length,
        separatorBuilder: (_, __) => const SizedBox(height: 8),
        itemBuilder: (context, index) => _buildTile(items[index]),
      ),
    );
  }

  Widget _buildTile(Subscription sub) {
    final scheme = Theme.of(context).colorScheme;
    final selected = sub.id != null && _selectedIds.contains(sub.id);
    return GlassCard(
      selected: selected,
      padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
      onTap: () {
        if (_selectedIds.isNotEmpty) {
          _toggleSelect(sub);
        } else {
          _openEdit(sub: sub);
        }
      },
      onLongPress: () => _toggleSelect(sub),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        sub.displayName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 14.5,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    _StatusBadge(sub: sub),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  sub.url,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: kMonoFamily,
                    fontFamilyFallback: kMonoFallback,
                    fontSize: 11.5,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: [
                    _MetaChip(icon: Icons.category_outlined, text: sub.type.label),
                    _MetaChip(icon: Icons.schedule, text: sub.scheduleLabel),
                    if (sub.alias.isNotEmpty)
                      _MetaChip(icon: Icons.folder_outlined, text: sub.alias),
                    if (sub.whitelist.isNotEmpty)
                      _MetaChip(
                        icon: Icons.filter_alt_outlined,
                        text: sub.whitelist,
                      ),
                  ],
                ),
              ],
            ),
          ),
          PopupMenuButton<String>(
            tooltip: '更多操作',
            onSelected: (value) => _onMenu(value, sub),
            itemBuilder: (context) => [
              PopupMenuItem(
                value: sub.isRunning ? 'stop' : 'run',
                child: Text(sub.isRunning ? '停止' : '立即拉取'),
              ),
              const PopupMenuItem(value: 'log', child: Text('查看日志')),
              PopupMenuItem(
                value: 'toggle',
                child: Text(sub.isDisabled ? '启用' : '禁用'),
              ),
              const PopupMenuItem(value: 'ai', child: Text('发给 AI')),
              const PopupMenuItem(value: 'delete', child: Text('删除')),
            ],
          ),
        ],
      ),
    );
  }

  void _toggleSelect(Subscription sub) {
    final id = sub.id;
    if (id == null) return;
    setState(() {
      if (!_selectedIds.remove(id)) _selectedIds.add(id);
    });
  }

  Future<void> _onMenu(String value, Subscription sub) async {
    final id = sub.id;
    if (id == null) return;
    final notifier = ref.read(subListProvider.notifier);
    switch (value) {
      case 'run':
        await _guard(() => notifier.run([id]), okMessage: '已开始拉取');
        break;
      case 'stop':
        await _guard(() => notifier.stop([id]), okMessage: '已发送停止');
        break;
      case 'log':
        await Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => SubscriptionLogPage(
              subId: id,
              title: sub.displayName,
            ),
          ),
        );
        break;
      case 'toggle':
        await _guard(
          () => notifier.setEnabled([id], sub.isDisabled),
          okMessage: sub.isDisabled ? '已启用' : '已禁用',
        );
        break;
      case 'ai':
        _sendToAi(sub);
        break;
      case 'delete':
        await _deleteOne(sub);
        break;
    }
  }

  void _sendToAi(Subscription sub) {
    // 私有仓库凭据绝不进这份内容：它会被原样塞进提示词发给 LLM。
    AskAi.push(
      ref,
      label: '订阅：${sub.displayName}',
      content: '订阅名称：${sub.displayName}\n'
          '类型：${sub.type.label}\n'
          '地址：${sub.url}\n'
          '分支：${sub.branch.isEmpty ? '默认' : sub.branch}\n'
          '别名：${sub.alias}\n'
          '定时：${sub.scheduleLabel}\n'
          '白名单：${sub.whitelist.isEmpty ? '无' : sub.whitelist}\n'
          '黑名单：${sub.blacklist.isEmpty ? '无' : sub.blacklist}\n'
          '依赖：${sub.dependences.isEmpty ? '无' : sub.dependences}\n'
          '扩展名：${sub.extensions.isEmpty ? '默认' : sub.extensions}\n'
          '状态：${sub.isDisabled ? '已禁用' : sub.status.label}\n'
          '自动建任务：${sub.autoAddCron} / 自动删任务：${sub.autoDelCron}\n'
          '执行命令：${sub.command.isEmpty ? sub.previewCommand : sub.command}',
      source: 'subscription',
      draft: '帮我看看这条订阅配置对不对',
    );
  }

  Future<void> _openEdit({Subscription? sub}) async {
    final notifier = ref.read(subListProvider.notifier);
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => SubscriptionEditPage(
          sub: sub,
          onSubmit: (value) =>
              sub == null ? notifier.create(value) : notifier.update(value),
        ),
      ),
    );
    if (saved == true && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(sub == null ? '订阅已创建' : '订阅已更新')),
      );
    }
  }

  Future<void> _deleteOne(Subscription sub) async {
    final id = sub.id;
    if (id == null) return;
    final force = await _askDeleteMode(1);
    if (force == null) return;
    await _guard(
      () => ref.read(subListProvider.notifier).delete([id], force: force),
      okMessage: '已删除',
    );
  }

  Future<void> _deleteSelected() async {
    final ids = _selectedIds.toList();
    if (ids.isEmpty) return;
    final force = await _askDeleteMode(ids.length);
    if (force == null) return;
    await _batch((list) =>
        ref.read(subListProvider.notifier).delete(list, force: force));
  }

  /// 删除前问一句"要不要连它建的定时任务一起删"。
  ///
  /// 面板的 force 参数就是这个语义。不问的话两种人都会被坑：想清干净的
  /// 留下一堆指向已删脚本的任务，想留着的又发现任务莫名消失。
  /// 返回 null 表示取消。
  Future<bool?> _askDeleteMode(int count) async {
    var withCrons = false;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setInner) => AlertDialog(
          title: Text(count > 1 ? '删除 $count 条订阅' : '删除订阅'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('订阅记录会被永久删除，已经拉下来的脚本文件保留。'),
              const SizedBox(height: 8),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                value: withCrons,
                onChanged: (v) => setInner(() => withCrons = v ?? false),
                title: const Text(
                  '同时删除它自动创建的定时任务',
                  style: TextStyle(fontSize: 13.5),
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
              child: const Text('删除'),
            ),
          ],
        ),
      ),
    );
    if (ok != true) return null;
    return withCrons;
  }

  Future<void> _batch(
    Future<void> Function(List<int> ids) action, {
    String okMessage = '操作完成',
  }) async {
    final ids = _selectedIds.toList();
    if (ids.isEmpty) return;
    try {
      await action(ids);
      if (!mounted) return;
      setState(_selectedIds.clear);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(okMessage)));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('操作失败：${errorText(e)}')),
        );
      }
    }
  }

  Future<void> _guard(
    Future<void> Function() action, {
    required String okMessage,
  }) async {
    try {
      await action();
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(okMessage)));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('操作失败：${errorText(e)}')),
        );
      }
    }
  }
}

/// 状态徽标：禁用优先于运行状态（禁用了就不会自动跑）。
class _StatusBadge extends StatelessWidget {
  const _StatusBadge({required this.sub});

  final Subscription sub;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (String label, IconData icon, Color color) = sub.isDisabled
        ? ('已禁用', Icons.block, scheme.outline)
        : switch (sub.status) {
            SubStatus.running => ('拉取中', Icons.downloading, Colors.green),
            SubStatus.queued => ('排队中', Icons.hourglass_bottom, Colors.orange),
            SubStatus.disabled => ('已禁用', Icons.block, scheme.outline),
            SubStatus.idle => ('空闲', Icons.schedule, scheme.outline),
          };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: color),
          const SizedBox(width: 4),
          Text(label, style: TextStyle(fontSize: 11.5, color: color)),
        ],
      ),
    );
  }
}

class _MetaChip extends StatelessWidget {
  const _MetaChip({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: scheme.onSurfaceVariant),
          const SizedBox(width: 4),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 150),
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }
}

class _SelectionBar extends StatelessWidget {
  const _SelectionBar({
    required this.count,
    required this.onRun,
    required this.onStop,
    required this.onEnable,
    required this.onDisable,
    required this.onDelete,
  });

  final int count;
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
          Text('已选 $count',
              style: const TextStyle(fontWeight: FontWeight.w600)),
          const Spacer(),
          IconButton(
            onPressed: onRun,
            tooltip: '立即拉取',
            icon: const Icon(Icons.play_arrow),
          ),
          IconButton(
            onPressed: onStop,
            tooltip: '停止',
            icon: const Icon(Icons.stop),
          ),
          IconButton(
            onPressed: onEnable,
            tooltip: '启用',
            icon: const Icon(Icons.check_circle_outline),
          ),
          IconButton(
            onPressed: onDisable,
            tooltip: '禁用',
            icon: const Icon(Icons.block),
          ),
          IconButton(
            onPressed: onDelete,
            tooltip: '删除',
            icon: Icon(
              Icons.delete_outline,
              color: Theme.of(context).colorScheme.error,
            ),
          ),
        ],
      ),
    );
  }
}
