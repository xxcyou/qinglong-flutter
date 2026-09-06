import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/utils/formatter.dart';
import '../../../shared/confirm_dialog.dart';
import '../../../shared/empty_view.dart';
import '../../../shared/glass_scaffold.dart';
import '../../../shared/status_donut.dart';
import '../models/panel_info.dart';
import '../providers/panel_health_provider.dart';
import '../providers/panel_list_provider.dart';
import 'panel_edit_page.dart';

class PanelListPage extends ConsumerStatefulWidget {
  const PanelListPage({super.key});

  @override
  ConsumerState<PanelListPage> createState() => _PanelListPageState();
}

class _PanelListPageState extends ConsumerState<PanelListPage> {
  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final notifier = ref.read(panelListProvider.notifier);
    if (!notifier.loaded) {
      await notifier.load();
    }
    final panels = ref.read(panelListProvider);
    if (panels.isNotEmpty) {
      final current = ref.read(currentPanelProvider);
      final defaultPanel = panels.where((p) => p.isDefault).isEmpty
          ? null
          : panels.where((p) => p.isDefault).first;
      ref.read(currentPanelIdProvider.notifier).state =
          current?.id ?? defaultPanel?.id ?? panels.first.id;
      // 进页面就把每台面板的状态探一遍：列表上直接看到在线/任务分布。
      await ref.read(panelHealthProvider.notifier).refreshAll();
    }
  }

  @override
  Widget build(BuildContext context) {
    final panels = ref.watch(panelListProvider);
    final current = ref.watch(currentPanelProvider);

    return GlassScaffold(
      title: '面板管理',
      actions: [
        IconButton(
          tooltip: '刷新所有面板状态',
          onPressed: () => ref.read(panelHealthProvider.notifier).refreshAll(),
          icon: const Icon(Icons.monitor_heart_outlined),
        ),
        IconButton(
          tooltip: '添加面板',
          onPressed: () => _openEdit(context),
          icon: const Icon(Icons.add),
        ),
      ],
      body: panels.isEmpty
          ? EmptyView(
              message: '还没有面板\n点击右上角 + 添加你的青龙面板',
              icon: Icons.dns_outlined,
              action: FilledButton.icon(
                onPressed: () => _openEdit(context),
                icon: const Icon(Icons.add),
                label: const Text('添加面板'),
              ),
            )
          : RefreshIndicator(
              onRefresh: () async {
                await ref.read(panelListProvider.notifier).load();
                await ref.read(panelHealthProvider.notifier).refreshAll();
              },
              child: ListView.separated(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 44),
                itemCount: panels.length,
                separatorBuilder: (_, __) => const SizedBox(height: 8),
                itemBuilder: (context, index) {
                  final panel = panels[index];
                  final selected = current?.id == panel.id;
                  return _PanelTile(
                    panel: panel,
                    selected: selected,
                    health: ref.watch(panelHealthProvider)[panel.id] ??
                        const PanelHealth(),
                    onCheck: () =>
                        ref.read(panelHealthProvider.notifier).refresh(panel),
                    onTap: () {
                      ref.read(currentPanelIdProvider.notifier).state =
                          panel.id;
                    },
                    onEdit: () => _openEdit(context, panel: panel),
                    onDelete: () => _delete(context, panel),
                    onDefault: () => ref
                        .read(panelListProvider.notifier)
                        .markDefault(panel.id),
                  );
                },
              ),
            ),
    );
  }

  Future<void> _openEdit(BuildContext context, {PanelInfo? panel}) async {
    final result = await Navigator.of(context).push<PanelInfo>(
      MaterialPageRoute(builder: (_) => PanelEditPage(panel: panel)),
    );
    if (result != null && mounted) {
      Future.microtask(() async {
        if (panel == null) {
          await ref.read(panelListProvider.notifier).add(result);
        } else {
          await ref.read(panelListProvider.notifier).update(result);
        }
        ref.read(currentPanelIdProvider.notifier).state = result.id;
      });
    }
  }

  Future<void> _delete(BuildContext context, PanelInfo panel) async {
    final messenger = ScaffoldMessenger.of(context);
    final ok = await showConfirmDialog(
      context,
      title: '删除面板',
      message: '删除「${panel.name}」？\n本机保存的登录状态也会一并清除。',
      confirmText: '删除',
      destructive: true,
    );
    if (ok) {
      await ref.read(panelListProvider.notifier).remove(panel.id);
      if (ref.read(currentPanelIdProvider.notifier).state == panel.id) {
        final panels = ref.read(panelListProvider);
        ref.read(currentPanelIdProvider.notifier).state =
            panels.isEmpty ? null : panels.first.id;
      }
      messenger.showSnackBar(
        SnackBar(content: Text('已删除面板「${panel.name}」')),
      );
    }
  }
}

class _PanelTile extends StatelessWidget {
  const _PanelTile({
    required this.panel,
    required this.selected,
    required this.health,
    required this.onTap,
    required this.onCheck,
    required this.onEdit,
    required this.onDelete,
    required this.onDefault,
  });

  final PanelInfo panel;
  final bool selected;
  final PanelHealth health;
  final VoidCallback onTap;
  final VoidCallback onCheck;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final VoidCallback onDefault;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return GlassCard(
      selected: selected,
      onTap: onTap,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _statusAvatar(scheme),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            panel.name,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                        ),
                        if (selected) ...[
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: scheme.primary.withValues(alpha: 0.14),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Text(
                              '当前',
                              style: TextStyle(
                                fontSize: 10.5,
                                color: scheme.primary,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ],
                        if (panel.isDefault) ...[
                          const SizedBox(width: 6),
                          Icon(Icons.star, size: 16, color: scheme.primary),
                        ],
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      panel.baseUrl,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12.5,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _statusLine(),
                      maxLines: 2,
                      style: TextStyle(
                        fontSize: 12,
                        color: health.online == false
                            ? scheme.error
                            : scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 4),
              PopupMenuButton<String>(
                onSelected: (value) {
                  switch (value) {
                    case 'check':
                      onCheck();
                    case 'edit':
                      onEdit();
                    case 'default':
                      onDefault();
                    case 'delete':
                      onDelete();
                  }
                },
                itemBuilder: (context) => [
                  const PopupMenuItem(value: 'check', child: Text('检测状态')),
                  const PopupMenuItem(value: 'edit', child: Text('编辑')),
                  const PopupMenuItem(value: 'default', child: Text('设为默认')),
                  const PopupMenuItem(value: 'delete', child: Text('删除')),
                ],
              ),
            ],
          ),
          // 任务分布环形图：在线且有任务时才画，省地方。
          if (health.online == true && health.total > 0) ...[
            const SizedBox(height: 10),
            Row(
              children: [
                StatusDonut(
                  segments: [
                    (health.running, Colors.blue.shade400),
                    (health.failed, scheme.error),
                    (health.disabled, scheme.outline),
                    (health.idle, Colors.green.shade400),
                  ],
                  centerLabel: '${health.total}',
                  centerSub: '任务',
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Wrap(
                    spacing: 10,
                    runSpacing: 4,
                    children: [
                      DonutLegend(
                        color: Colors.green.shade400,
                        label: '正常',
                        count: health.idle,
                      ),
                      DonutLegend(
                        color: Colors.blue.shade400,
                        label: '运行中',
                        count: health.running,
                      ),
                      DonutLegend(
                        color: scheme.error,
                        label: '失败',
                        count: health.failed,
                      ),
                      DonutLegend(
                        color: scheme.outline,
                        label: '已停用',
                        count: health.disabled,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  /// 头像兼状态灯：绿=在线，红=连不上，灰=还没探测。
  Widget _statusAvatar(ColorScheme scheme) {
    final color = switch (health.online) {
      true => Colors.green.shade500,
      false => scheme.error,
      _ => scheme.outline,
    };
    return Stack(
      children: [
        CircleAvatar(
          backgroundColor: scheme.primaryContainer,
          child: Text(panel.name.isEmpty ? '?' : panel.name.substring(0, 1)),
        ),
        Positioned(
          right: 0,
          bottom: 0,
          child: health.checking
              ? SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: scheme.primary,
                  ),
                )
              : Container(
                  width: 12,
                  height: 12,
                  decoration: BoxDecoration(
                    color: color,
                    shape: BoxShape.circle,
                    border: Border.all(color: scheme.surface, width: 2),
                  ),
                ),
        ),
      ],
    );
  }

  String _statusLine() {
    if (health.checking) return '${panel.loginType.label} · 检测中…';
    if (health.online == null) return '${panel.loginType.label} · 未检测';
    if (health.online == false) {
      return '${panel.loginType.label} · 离线：${health.error}';
    }
    return [
      panel.loginType.label,
      if (health.version.isNotEmpty) 'v${health.version}',
      '${health.latencyMs}ms',
      if (health.checkedAt != null) Formatter.dateTime(health.checkedAt!),
    ].join(' · ');
  }
}
