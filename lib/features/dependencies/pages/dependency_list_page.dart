import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/utils/error_text.dart';
import '../../../shared/ask_ai.dart';
import '../../../shared/confirm_dialog.dart';
import '../../../shared/empty_view.dart';
import '../../../shared/error_view.dart';
import '../../../shared/glass_scaffold.dart';
import '../../../shared/loading_view.dart';
import '../../../shared/text_input_dialog.dart';
import '../models/dependency.dart';
import '../providers/dependency_list_provider.dart';
import '../../../shared/mono_text.dart';

class DependencyListPage extends ConsumerStatefulWidget {
  const DependencyListPage({super.key});

  @override
  ConsumerState<DependencyListPage> createState() => _DependencyListPageState();
}

class _DependencyListPageState extends ConsumerState<DependencyListPage> {
  @override
  void initState() {
    super.initState();
    Future.microtask(() => ref.read(dependencyListProvider.notifier).load());
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(dependencyListProvider);
    final notifier = ref.read(dependencyListProvider.notifier);

    return GlassScaffold(
      title: '依赖管理',
      actions: [
        IconButton(
          tooltip: '安装依赖',
          onPressed: _installDialog,
          icon: const Icon(Icons.add),
        ),
      ],
      headerBottom: Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
        child: SizedBox(
          height: 36,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: _dependencyTypeFilters.length,
            separatorBuilder: (_, __) => const SizedBox(width: 8),
            itemBuilder: (context, index) {
              final t = _dependencyTypeFilters[index];
              return ChoiceChip(
                label: Text(t.$2),
                selected: state.type == t.$1,
                onSelected: (_) => notifier.setType(t.$1),
              );
            },
          ),
        ),
      ),
      body: _buildBody(state),
    );
  }

  Widget _buildBody(DependencyListState state) {
    if (state.isLoading && state.items.isEmpty) return const LoadingView();
    if (state.error != null && state.items.isEmpty) {
      return ErrorView(
        message: errorText(state.error!),
        onRetry: ref.read(dependencyListProvider.notifier).refresh,
      );
    }
    if (state.items.isEmpty) {
      return const EmptyView(
        message: '暂无依赖\n点右上角 + 安装',
        icon: Icons.inventory_2_outlined,
      );
    }
    return RefreshIndicator(
      onRefresh: ref.read(dependencyListProvider.notifier).refresh,
      child: ListView.separated(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 54),
        itemCount: state.items.length,
        separatorBuilder: (_, __) => const SizedBox(height: 8),
        itemBuilder: (context, index) {
          final dep = state.items[index];
          return _DependencyTile(
            dep: dep,
            onRemove: () => _confirmRemove(dep),
            onReinstall: () => _reinstall(dep),
            onShowLog: () => _showDependencyLog(dep),
            onSendToAi: () => _sendDependencyToAi(dep),
          );
        },
      ),
    );
  }

  void _showDependencyLog(Dependency dep) {
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('${dep.name} 日志'),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: SelectableText(
              dep.log?.isNotEmpty == true ? dep.log! : '暂无日志',
              style: const TextStyle(
                fontFamily: kMonoFamily,
                fontFamilyFallback: kMonoFallback,
                fontSize: 12,
                height: 1.4,
              ),
            ),
          ),
        ),
        actions: [
          TextButton.icon(
            onPressed: () {
              Navigator.pop(dialogContext);
              AskAi.push(
                ref,
                label: '依赖日志：${dep.name}',
                content: dep.log?.isNotEmpty == true ? dep.log! : '暂无日志',
                source: 'dependency_log',
                draft: '这个依赖装失败了吗？帮我分析并给出修复方案',
              );
            },
            icon: const Icon(Icons.auto_awesome, size: 18),
            label: const Text('发给 AI'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  void _sendDependencyToAi(Dependency dep) {
    final log = dep.log?.isNotEmpty == true ? dep.log!.trim() : '';
    AskAi.push(
      ref,
      label: '依赖：${dep.name}',
      content: '依赖名称：${dep.name}\n'
          '类型：${_dependencyTypeLabel(dep.type)}\n'
          '状态：${_dependencyStatusLabel(dep.status)}\n'
          '日志：${log.isEmpty ? '暂无日志' : log}',
      source: 'dependency',
      draft: '这个依赖装失败了吗？帮我分析并给出修复方案',
    );
  }

  Future<void> _installDialog() async {
    final input = await showTextInputDialog(
      context,
      title: '安装依赖',
      labelText: '依赖名',
      hintText: '多个用逗号分隔，如 requests,numpy',
      confirmText: '安装',
    );
    if (input == null || input.trim().isEmpty || !mounted) return;
    final names = input
        .split(RegExp(r'[,，]'))
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
    try {
      await ref.read(dependencyListProvider.notifier).install(names);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已开始安装 ${names.length} 个依赖')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('安装失败：${errorText(e)}')),
        );
      }
    }
  }

  Future<void> _confirmRemove(Dependency dep) async {
    final ok = await showConfirmDialog(
      context,
      title: '卸载依赖',
      message: '确定卸载「${dep.name}」？',
      confirmText: '卸载',
      destructive: true,
    );
    if (ok) {
      try {
        await ref.read(dependencyListProvider.notifier).remove([dep.id!]);
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('卸载失败：${errorText(e)}')),
          );
        }
      }
    }
  }

  Future<void> _reinstall(Dependency dep) async {
    try {
      await ref.read(dependencyListProvider.notifier).reinstall([dep.id!]);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已开始重装 ${dep.name}')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('重装失败：${errorText(e)}')),
        );
      }
    }
  }
}

const _dependencyTypeFilters = [
  (-1, '全部'),
  (0, 'NodeJs'),
  (1, 'Python3'),
  (2, 'Linux'),
];

String _dependencyTypeLabel(int type) {
  return switch (type) {
    0 => 'NodeJs',
    1 => 'Python3',
    2 => 'Linux',
    _ => '未知',
  };
}

String _dependencyStatusLabel(String status) {
  return switch (status) {
    'installed' => '已安装',
    'installing' => '安装中',
    'installFailed' => '安装失败',
    'removing' => '卸载中',
    'removed' => '已卸载',
    'removeFailed' => '卸载失败',
    'queued' => '排队中',
    'cancelled' => '已取消',
    _ => '未知',
  };
}

class _DependencyTile extends StatelessWidget {
  const _DependencyTile({
    required this.dep,
    required this.onRemove,
    required this.onReinstall,
    required this.onShowLog,
    required this.onSendToAi,
  });

  final Dependency dep;
  final VoidCallback onRemove;
  final VoidCallback onReinstall;
  final VoidCallback onShowLog;
  final VoidCallback onSendToAi;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (label, color) = switch (dep.status) {
      'installed' => ('已安装', Colors.green),
      'installing' => ('安装中', Colors.orange),
      'installFailed' => ('安装失败', scheme.error),
      'removing' => ('卸载中', Colors.orange),
      'removed' => ('已卸载', Colors.grey),
      'removeFailed' => ('卸载失败', scheme.error),
      'queued' => ('排队中', Colors.blueGrey),
      'cancelled' => ('已取消', Colors.grey),
      _ => ('未知', scheme.outline),
    };
    final subtitle = [
      _dependencyTypeLabel(dep.type),
      label,
      if (dep.remark?.isNotEmpty == true) dep.remark!,
    ].join(' · ');

    return GlassCard(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(
        children: [
          Icon(Icons.extension_outlined, color: color),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  dep.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12.5,
                    color: scheme.onSurfaceVariant,
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
                  onSendToAi();
                  break;
                case 'log':
                  onShowLog();
                  break;
                case 'reinstall':
                  onReinstall();
                  break;
                case 'remove':
                  onRemove();
                  break;
              }
            },
            itemBuilder: (context) => [
              const PopupMenuItem(value: 'ai', child: Text('发给 AI')),
              if (dep.log?.isNotEmpty == true)
                const PopupMenuItem(value: 'log', child: Text('查看日志')),
              const PopupMenuItem(value: 'reinstall', child: Text('重装')),
              const PopupMenuItem(value: 'remove', child: Text('卸载')),
            ],
          ),
        ],
      ),
    );
  }
}
