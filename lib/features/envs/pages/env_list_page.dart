import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/glass.dart';
import '../../../core/utils/error_text.dart';
import '../../../shared/ask_ai.dart';
import '../../../shared/confirm_dialog.dart';
import '../../../shared/empty_view.dart';
import '../../../shared/error_view.dart';
import '../../../shared/glass_scaffold.dart';
import '../../../shared/loading_view.dart';
import '../../../shared/search_field.dart';
import '../models/env_var.dart';
import '../providers/env_list_provider.dart';
import 'env_edit_page.dart';
import '../../../shared/mono_text.dart';

class EnvListPage extends ConsumerStatefulWidget {
  const EnvListPage({super.key});

  @override
  ConsumerState<EnvListPage> createState() => _EnvListPageState();
}

class _EnvListPageState extends ConsumerState<EnvListPage> {
  final _searchController = TextEditingController();
  final Set<int> _selectedIds = {};
  final Set<int> _revealedIds = {};

  @override
  void initState() {
    super.initState();
    Future.microtask(() => ref.read(envListProvider.notifier).load());
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(envListProvider);
    final notifier = ref.read(envListProvider.notifier);
    final visible = state.items.where((e) {
      if (state.filter == EnvStatusFilter.enabled && !e.isEnabled) return false;
      if (state.filter == EnvStatusFilter.disabled && e.isEnabled) return false;
      return true;
    }).toList();

    return GlassScaffold(
      title: '环境变量',
      actions: [
        if (_selectedIds.isNotEmpty)
          IconButton(
            tooltip: '取消选择',
            onPressed: () => setState(_selectedIds.clear),
            icon: const Icon(Icons.close),
          )
        else
          IconButton(
            tooltip: '新增',
            onPressed: () => _openEdit(),
            icon: const Icon(Icons.add),
          ),
      ],
      headerInline: SearchField(
        controller: _searchController,
        hintText: '搜索名称 / 备注',
        onChanged: notifier.setSearch,
      ),
      headerBottom: Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
        child: SizedBox(
          height: 34,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: EnvStatusFilter.values.length,
            separatorBuilder: (_, __) => const SizedBox(width: 8),
            itemBuilder: (context, index) {
              final f = EnvStatusFilter.values[index];
              return ChoiceChip(
                label: Text(f.label),
                selected: state.filter == f,
                onSelected: (_) => notifier.setFilter(f),
              );
            },
          ),
        ),
      ),
      bottomBar: _selectedIds.isEmpty
          ? null
          : _EnvSelectionBar(
              count: _selectedIds.length,
              onEnable: () => _batch((ids) => notifier.setEnabled(ids, true)),
              onDisable: () => _batch((ids) => notifier.setEnabled(ids, false)),
              onDelete: _deleteSelected,
            ),
      body: _buildBody(state, visible),
    );
  }

  Widget _buildBody(EnvListState state, List<EnvVar> items) {
    if (state.isLoading && items.isEmpty) return const LoadingView();
    if (state.error != null && items.isEmpty) {
      return ErrorView(
        message: errorText(state.error!),
        onRetry: ref.read(envListProvider.notifier).refresh,
      );
    }
    if (items.isEmpty) {
      return EmptyView(
        message: state.search.isNotEmpty ? '没有匹配的环境变量' : '暂无环境变量\n点击右上角 + 新增',
        icon: Icons.key_outlined,
      );
    }
    return RefreshIndicator(
      onRefresh: ref.read(envListProvider.notifier).refresh,
      child: ListView.separated(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 110),
        itemCount: items.length,
        separatorBuilder: (_, __) => const SizedBox(height: 8),
        itemBuilder: (context, index) {
          final env = items[index];
          final selected = _selectedIds.contains(env.id);
          final revealed = env.id != null && _revealedIds.contains(env.id);
          return GlassCard(
            selected: selected,
            onTap: () {
              if (_selectedIds.isNotEmpty) {
                setState(() {
                  if (env.id == null) return;
                  if (!_selectedIds.remove(env.id)) _selectedIds.add(env.id!);
                });
              } else {
                _openEdit(env: env);
              }
            },
            onLongPress: () {
              if (env.id != null) setState(() => _selectedIds.add(env.id!));
            },
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Row(
              children: [
                Icon(
                  env.isEnabled ? Icons.check_circle : Icons.cancel,
                  color: env.isEnabled
                      ? Colors.green
                      : Theme.of(context).colorScheme.outline,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        env.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        revealed ? env.value : _mask(env.value),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontFamily: kMonoFamily,
                          fontFamilyFallback: kMonoFallback,
                          fontSize: 12.5,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 4),
                PopupMenuButton<String>(
                  tooltip: '更多操作',
                  onSelected: (value) {
                    switch (value) {
                      case 'ai':
                        _sendToAi(env);
                        break;
                      case 'toggle':
                        setState(() {
                          if (env.id == null) return;
                          if (!_revealedIds.remove(env.id)) {
                            _revealedIds.add(env.id!);
                          }
                        });
                        break;
                    }
                  },
                  itemBuilder: (context) => [
                    const PopupMenuItem(value: 'ai', child: Text('发给 AI')),
                    PopupMenuItem(
                      value: 'toggle',
                      child: Text(revealed ? '隐藏值' : '显示值'),
                    ),
                  ],
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  String _mask(String value) {
    if (value.isEmpty) return '(空)';
    if (value.length <= 4) return '****';
    return '${value.substring(0, 2)}****${value.substring(value.length - 2)}';
  }

  /// 发给 AI 时对值做脱敏：只保留前 4 个字符，避免泄露完整密钥。
  String _maskForAi(String value) {
    if (value.isEmpty) return '(空)';
    if (value.length <= 4) return '****…（已脱敏）';
    return '${value.substring(0, 4)}…（已脱敏）';
  }

  void _sendToAi(EnvVar env) {
    AskAi.push(
      ref,
      label: '环境变量：${env.name}',
      content: '环境变量名称：${env.name}\n'
          '备注：${env.remarks ?? '无'}\n'
          '状态：${env.isEnabled ? '启用' : '禁用'}\n'
          '值（已脱敏）：${_maskForAi(env.value)}',
      source: 'env',
      draft: '帮我看看这个环境变量配置对不对',
    );
  }

  Future<void> _openEdit({EnvVar? env}) async {
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => EnvEditPage(env: env)),
    );
    if (saved == true) {
      Future.microtask(() => ref.read(envListProvider.notifier).refresh());
    }
  }

  Future<void> _batch(Future<void> Function(List<int> ids) action) async {
    final ids = _selectedIds.toList();
    if (ids.isEmpty) return;
    try {
      await action(ids);
      if (mounted) setState(_selectedIds.clear);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('操作失败：${errorText(e)}')),
        );
      }
    }
  }

  Future<void> _deleteSelected() async {
    final ok = await showConfirmDialog(
      context,
      title: '批量删除',
      message: '确定删除选中的 ${_selectedIds.length} 个环境变量？',
      confirmText: '删除',
      destructive: true,
    );
    if (ok) {
      await _batch(ref.read(envListProvider.notifier).delete);
    }
  }
}

class _EnvSelectionBar extends StatelessWidget {
  const _EnvSelectionBar({
    required this.count,
    required this.onEnable,
    required this.onDisable,
    required this.onDelete,
  });

  final int count;
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
