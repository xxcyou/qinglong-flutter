import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/adb_session_provider.dart';
import 'adb_connect_dialog.dart';

class AdbManagerSheet extends ConsumerWidget {
  const AdbManagerSheet({super.key, this.asSheet = false, this.onClose});

  final bool asSheet;
  final VoidCallback? onClose;

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
              child: const AdbManagerSheet(),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(adbSessionsProvider);
    final notifier = ref.read(adbSessionsProvider.notifier);
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
                child: Icon(Icons.smartphone, color: scheme.primary),
              ),
              const SizedBox(width: 12),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'ADB 设备管理',
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    Text(
                      '网络无线调试，连接后可进文件管理操作设备文件',
                      style: TextStyle(fontSize: 12),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: '新建 ADB 连接',
                onPressed: () async {
                  final draft = await AdbConnectDialog.show(context);
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
                onPressed:
                    onClose ?? (asSheet ? () {} : () => Navigator.pop(context)),
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
                      Icon(Icons.smartphone_outlined,
                          size: 48, color: scheme.onSurfaceVariant),
                      const SizedBox(height: 12),
                      const Text('还没有 ADB 设备连接'),
                      const SizedBox(height: 4),
                      Text(
                        '点右上角 + 添加无线调试设备',
                        style: TextStyle(
                            fontSize: 12, color: scheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                )
              : ListView.separated(
                  padding: const EdgeInsets.all(16),
                  itemCount: sessions.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 8),
                  itemBuilder: (context, i) {
                    final s = sessions[i];
                    return ListTile(
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                        side: BorderSide(color: scheme.outlineVariant),
                      ),
                      leading: Icon(
                        s.isConnected
                            ? Icons.smartphone
                            : Icons.smartphone_outlined,
                        color: s.isConnected ? Colors.green : null,
                      ),
                      title: Text(s.name),
                      subtitle: Text(
                        '${s.host}:${s.port} · ${s.status}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: Wrap(
                        spacing: 4,
                        children: [
                          if (s.isConnected)
                            IconButton(
                              tooltip: '断开',
                              onPressed: () => notifier.disconnect(s.id),
                              icon: const Icon(Icons.link_off),
                            )
                          else
                            IconButton(
                              tooltip: '连接',
                              onPressed: () {
                                final draft = AdbSessionDraft(
                                  name: s.name,
                                  host: s.host,
                                  port: s.port,
                                  pairingPort: s.pairingPort,
                                  pairingCode: s.pairingCode,
                                );
                                notifier.connect(draft, id: s.id);
                              },
                              icon: const Icon(Icons.link),
                            ),
                          IconButton(
                            tooltip: '删除',
                            onPressed: () => notifier.remove(s.id),
                            icon: Icon(Icons.delete_outline,
                                color: scheme.error),
                          ),
                        ],
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}
