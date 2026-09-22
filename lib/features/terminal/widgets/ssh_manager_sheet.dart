import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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
          child: const SafeArea(
            child: SizedBox(height: 520, child: SshManagerSheet()),
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
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
          child: Row(
            children: [
              const Expanded(
                child: Text(
                  'SSH 会话管理',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              IconButton(
                tooltip: '新建 SSH 终端',
                onPressed: () async {
                  final draft = await SshConnectDialog.show(context);
                  if (draft == null || !context.mounted) return;
                  final session = await notifier.connect(draft);
                  if (session.status != 'connected' && context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('SSH 连接失败：${session.status}')),
                    );
                  }
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
              ? const Center(child: Text('还没有 SSH 会话，点右上角新增'))
              : ListView.separated(
                  padding: const EdgeInsets.all(12),
                  itemCount: sessions.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 6),
                  itemBuilder: (context, i) {
                    final s = sessions[i];
                    final connected = s.isConnected;
                    return ListTile(
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                        side: BorderSide(
                          color: connected
                              ? scheme.primary
                              : scheme.outlineVariant,
                          width: connected ? 1.2 : 0.6,
                        ),
                      ),
                      leading: Icon(
                        connected ? Icons.dns_outlined : Icons.cloud_outlined,
                        color: connected
                            ? scheme.primary
                            : scheme.onSurfaceVariant,
                      ),
                      title: Text(s.name),
                      subtitle: Text(
                        '${s.username}@${s.host}:${s.port}  ·  ${s.status}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      onTap: connected
                          ? null
                          : () async {
                              final draft =
                                  SshSessionManager.instance.draftOf(s.id);
                              if (draft == null) return;
                              await notifier.connect(draft, id: s.id);
                            },
                      trailing: PopupMenuButton<String>(
                        onSelected: (v) async {
                          if (v == 'connect') {
                            final draft =
                                SshSessionManager.instance.draftOf(s.id);
                            if (draft != null) {
                              await notifier.connect(draft, id: s.id);
                            }
                          } else if (v == 'disconnect') {
                            await notifier.disconnect(s.id);
                          } else if (v == 'delete') {
                            await notifier.remove(s.id);
                          }
                        },
                        itemBuilder: (_) => [
                          if (!connected)
                            const PopupMenuItem(
                              value: 'connect',
                              child: Text('连接'),
                            ),
                          if (connected)
                            const PopupMenuItem(
                              value: 'disconnect',
                              child: Text('断开'),
                            ),
                          const PopupMenuItem(
                            value: 'delete',
                            child: Text('删除'),
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
