import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/glass.dart';
import '../providers/ssh_session_provider.dart';
import 'ssh_connect_dialog.dart';

class SshManagerSheet extends ConsumerWidget {
  const SshManagerSheet({super.key});

  static Future<void> show(BuildContext context) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => ClipRRect(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        child: Material(
          color: Theme.of(context).colorScheme.surface.withValues(alpha: 0.96),
          child: SafeArea(
            child: SizedBox(
              height: MediaQuery.sizeOf(context).height * 0.88,
              child: const SshManagerSheet(),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(sshSessionsProvider);
    final notifier = ref.read(sshSessionsProvider.notifier);
    final scheme = Theme.of(context).colorScheme;
    final sessions = state.sessions;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 12, 10),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: scheme.primaryContainer,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(Icons.dns_outlined, color: scheme.primary),
              ),
              const SizedBox(width: 12),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'SSH 会话管理',
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    Text(
                      '连接、断开、删除，连接后实时显示 CPU / 内存',
                      style: TextStyle(fontSize: 12),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: '新建 SSH 会话',
                onPressed: () async {
                  final draft = await SshConnectDialog.show(context);
                  if (draft == null || !context.mounted) return;
                  final session = await notifier.connect(draft);
                  if (!context.mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(
                        session.isConnected
                            ? '✅ ${session.name} 已连接'
                            : '❌ ${session.name} 连接失败\n${session.status}',
                      ),
                      behavior: SnackBarBehavior.floating,
                    ),
                  );
                },
                icon: const Icon(Icons.add_box_outlined),
              ),
              IconButton(
                tooltip: '关闭',
                onPressed: () => Navigator.pop(context),
                icon: const Icon(Icons.close),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: sessions.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.cloud_outlined,
                        size: 56,
                        color: scheme.onSurfaceVariant.withValues(alpha: 0.4),
                      ),
                      const SizedBox(height: 12),
                      const Text('还没有 SSH 会话'),
                      const SizedBox(height: 6),
                      Text(
                        '点右上角 + 新建',
                        style: TextStyle(
                          fontSize: 12,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                )
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(14, 10, 14, 24),
                  itemCount: sessions.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 8),
                  itemBuilder: (context, i) {
                    final s = sessions[i];
                    return _SshSessionCard(
                      session: s,
                      onConnect: () async {
                        final draft = SshSessionManager.instance.draftOf(s.id);
                        if (draft == null) return;
                        final result = await notifier.connect(draft, id: s.id);
                        if (!context.mounted) return;
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(
                              result.isConnected
                                  ? '✅ ${result.name} 已连接'
                                  : '❌ ${result.name} 连接失败\n${result.status}',
                            ),
                            behavior: SnackBarBehavior.floating,
                          ),
                        );
                      },
                      onDisconnect: () async {
                        await notifier.disconnect(s.id);
                        if (!context.mounted) return;
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('已断开连接'),
                            behavior: SnackBarBehavior.floating,
                          ),
                        );
                      },
                      onDelete: () async {
                        await notifier.remove(s.id);
                        if (!context.mounted) return;
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('会话已删除'),
                            behavior: SnackBarBehavior.floating,
                          ),
                        );
                      },
                    );
                  },
                ),
        ),
      ],
    );
  }
}

class _SshSessionCard extends ConsumerWidget {
  const _SshSessionCard({
    required this.session,
    required this.onConnect,
    required this.onDisconnect,
    required this.onDelete,
  });

  final SshSession session;
  final VoidCallback onConnect;
  final VoidCallback onDisconnect;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final connected = session.isConnected;
    final connecting = session.status == 'connecting';
    final statusColor = connected
        ? Colors.greenAccent
        : connecting
            ? Colors.amber
            : session.status.startsWith('error')
                ? scheme.error
                : scheme.outline;

    return GlassPanel(
      radius: 18,
      blur: 12,
      padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
      borderWidth: connected ? 1.2 : 0.8,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 320),
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: statusColor.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(13),
                  border: Border.all(
                    color: statusColor.withValues(alpha: 0.6),
                    width: 1.2,
                  ),
                ),
                child: Center(
                  child: Icon(
                    connected
                        ? Icons.dns_outlined
                        : connecting
                            ? Icons.sync
                            : Icons.cloud_outlined,
                    color: statusColor,
                    size: 20,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      session.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${session.username}@${session.host}:${session.port}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12.5,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 6),
                    AnimatedSwitcher(
                      duration: const Duration(milliseconds: 220),
                      child: Container(
                        key: ValueKey(
                            '${session.id}_${session.status}_$connected'),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 2),
                        decoration: BoxDecoration(
                          color: statusColor.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          session.status,
                          style: TextStyle(
                            fontSize: 11,
                            color: statusColor,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              PopupMenuButton<String>(
                tooltip: '操作',
                onSelected: (v) {
                  if (v == 'connect') onConnect();
                  if (v == 'disconnect') onDisconnect();
                  if (v == 'delete') onDelete();
                },
                itemBuilder: (_) => [
                  if (!connected)
                    const PopupMenuItem(
                      value: 'connect',
                      child: ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(Icons.power_settings_new),
                        title: Text('连接'),
                      ),
                    ),
                  if (connected)
                    const PopupMenuItem(
                      value: 'disconnect',
                      child: ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(Icons.link_off),
                        title: Text('断开'),
                      ),
                    ),
                  const PopupMenuItem(
                    value: 'delete',
                    child: ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(Icons.delete_outline),
                      title: Text('删除'),
                    ),
                  ),
                ],
              ),
            ],
          ),
          AnimatedSize(
            duration: const Duration(milliseconds: 260),
            curve: Curves.easeOutCubic,
            child: connected
                ? Padding(
                    padding: const EdgeInsets.fromLTRB(52, 8, 8, 4),
                    child: _SshResourceStats(sessionId: session.id),
                  )
                : const SizedBox.shrink(),
          ),
          if (!connected)
            Padding(
              padding: const EdgeInsets.fromLTRB(52, 0, 8, 0),
              child: Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: onConnect,
                  icon: const Icon(Icons.power_settings_new, size: 16),
                  label: const Text('连接'),
                  style: TextButton.styleFrom(
                    foregroundColor: scheme.primary,
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _SshResourceStats extends StatefulWidget {
  const _SshResourceStats({required this.sessionId});

  final String sessionId;

  @override
  State<_SshResourceStats> createState() => _SshResourceStatsState();
}

class _SshResourceStatsState extends State<_SshResourceStats> {
  Timer? _timer;
  bool _loading = true;
  String? _error;
  double? _cpu;
  double? _memoryUsedPercent;
  double? _memoryTotalKb;
  double? _memoryAvailableKb;
  String? _load;
  int? _cores;

  static const _command = r'''
echo _STATS_BEGIN
echo _LOAD
cat /proc/loadavg
echo _MEM
grep -E 'MemTotal|MemAvailable' /proc/meminfo
echo _CPU1
awk '/^cpu /{for(i=2;i<=8;i++) printf "%s\n", $i}' /proc/stat
sleep 1
echo _CPU2
awk '/^cpu /{for(i=2;i<=8;i++) printf "%s\n", $i}' /proc/stat
echo _NCORES
nproc
''';

  @override
  void initState() {
    super.initState();
    _refresh();
    _timer = Timer.periodic(const Duration(seconds: 2), (_) => _refresh());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    try {
      final raw = await SshSessionManager.instance.execute(
        widget.sessionId,
        _command,
      );
      _parse(raw);
      if (mounted) {
        setState(() {
          _loading = false;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = '资源读取失败';
        });
      }
    }
  }

  void _parse(String raw) {
    final section = <String, List<String>>{};
    String? current;
    for (final line in raw.split('\n')) {
      final t = line.trim();
      if (t.isEmpty) continue;
      if (t.startsWith('_LOAD') ||
          t.startsWith('_MEM') ||
          t.startsWith('_CPU1') ||
          t.startsWith('_CPU2') ||
          t.startsWith('_NCORES')) {
        current = t;
        section[current] = [];
        continue;
      }
      if (current != null) section[current]!.add(t);
    }

    _load =
        section['_LOAD']?.isNotEmpty == true ? section['_LOAD']!.first : null;
    final memLines = section['_MEM'] ?? const [];
    double? totalKb;
    double? availableKb;
    for (final line in memLines) {
      final parts = line.split(RegExp(r'\s+'));
      if (parts.length >= 2) {
        final v = double.tryParse(parts[1]);
        if (line.startsWith('MemTotal')) totalKb = v;
        if (line.startsWith('MemAvailable')) availableKb = v;
      }
    }
    _memoryTotalKb = totalKb;
    _memoryAvailableKb = availableKb;
    if (totalKb != null && totalKb > 0) {
      _memoryUsedPercent =
          ((totalKb - (availableKb ?? totalKb)) / totalKb * 100).clamp(0, 100);
    } else {
      _memoryUsedPercent = null;
    }

    final cpu1 = (section['_CPU1'] ?? const [])
        .map(double.tryParse)
        .whereType<double>()
        .toList();
    final cpu2 = (section['_CPU2'] ?? const [])
        .map(double.tryParse)
        .whereType<double>()
        .toList();
    if (cpu1.length >= 4 && cpu2.length >= 4) {
      double sum(List<double> v) => v.fold(0, (a, b) => a + b);
      final prevIdle = cpu1[3] + (cpu1.length > 4 ? cpu1[4] : 0);
      final currIdle = cpu2[3] + (cpu2.length > 4 ? cpu2[4] : 0);
      final prevTotal = sum(cpu1);
      final currTotal = sum(cpu2);
      final diffTotal = currTotal - prevTotal;
      final diffIdle = currIdle - prevIdle;
      if (diffTotal > 0) {
        _cpu = ((diffTotal - diffIdle) / diffTotal * 100).clamp(0, 100);
      }
    }
    _cores = section['_NCORES']?.isNotEmpty == true
        ? int.tryParse(section['_NCORES']!.first)
        : null;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 8),
        child: LinearProgressIndicator(minHeight: 2),
      );
    }
    if (_error != null) {
      return Text(
        _error!,
        style: TextStyle(fontSize: 11.5, color: scheme.error),
      );
    }
    final cpu = (_cpu ?? 0) / 100;
    final mem = (_memoryUsedPercent ?? 0) / 100;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _ResourceBar(
          label: 'CPU',
          valueLabel: _cpu == null
              ? '--'
              : '${_cpu!.toStringAsFixed(1)}%'
                  '${_load != null ? '  ·  负载 $_load' : ''}'
                  '${_cores != null && _cores! > 0 ? '  ·  $_cores 核' : ''}',
          value: cpu,
          color: Colors.lightBlueAccent,
        ),
        const SizedBox(height: 8),
        _ResourceBar(
          label: '内存',
          valueLabel: _memoryTotalKb == null
              ? '--'
              : '${_formatKb(_memoryTotalKb! - (_memoryAvailableKb ?? _memoryTotalKb!))} / ${_formatKb(_memoryTotalKb!)}'
                  '  (${(_memoryUsedPercent ?? 0).toStringAsFixed(1)}%)',
          value: mem,
          color: Colors.greenAccent,
        ),
      ],
    );
  }

  String _formatKb(double kb) {
    if (kb >= 1024 * 1024) return '${(kb / 1024 / 1024).toStringAsFixed(1)} GB';
    if (kb >= 1024) return '${(kb / 1024).toStringAsFixed(1)} MB';
    return '${kb.toStringAsFixed(0)} KB';
  }
}

class _ResourceBar extends StatelessWidget {
  const _ResourceBar({
    required this.label,
    required this.valueLabel,
    required this.value,
    required this.color,
  });

  final String label;
  final String valueLabel;
  final double value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              label,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: scheme.onSurfaceVariant,
              ),
            ),
            const Spacer(),
            Text(
              valueLabel,
              style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
            ),
          ],
        ),
        const SizedBox(height: 4),
        TweenAnimationBuilder<double>(
          tween: Tween(begin: 0, end: value.clamp(0, 1)),
          duration: const Duration(milliseconds: 500),
          curve: Curves.easeOutCubic,
          builder: (context, v, _) => ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: LinearProgressIndicator(
              value: v,
              minHeight: 6,
              backgroundColor: scheme.surfaceContainerHighest,
              valueColor: AlwaysStoppedAnimation(color),
            ),
          ),
        ),
      ],
    );
  }
}
