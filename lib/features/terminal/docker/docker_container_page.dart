import 'package:flutter/material.dart';

import 'docker_container.dart';
import 'ssh_container_files.dart';
import 'ssh_floating_logs.dart';
import 'ssh_floating_terminal.dart';

/// 从 SSH 会话进入的 Docker 容器管理页。
/// 全功能：启动/停止/重启/暂停/恢复/强制结束/删除/重命名，并可打开容器终端、日志、文件管理。
class DockerContainerPage extends StatefulWidget {
  const DockerContainerPage({super.key, required this.sessionId});

  final String sessionId;

  @override
  State<DockerContainerPage> createState() => _DockerContainerPageState();
}

class _DockerContainerPageState extends State<DockerContainerPage> {
  List<DockerContainer>? _containers;
  String? _error;
  String _busyContainerId = '';
  String _busyAction = '';
  final Set<String> _expanded = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _containers = null;
      _error = null;
    });
    try {
      final real = await DockerService(widget.sessionId).list();
      if (!mounted) return;
      setState(() => _containers = real);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '$e');
    }
  }

  Future<void> _action(
    DockerContainer c,
    String action, {
    String? name,
  }) async {
    if (_busyContainerId.isNotEmpty) return;
    setState(() {
      _busyContainerId = c.id;
      _busyAction = action;
    });
    try {
      final r = await DockerService(widget.sessionId).run(
        c.id,
        action,
        name: name,
      );
      if (!mounted) return;
      if (r.toLowerCase().contains('error') || r.contains('[exit=')) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('${c.name} $action 失败：$r'),
          behavior: SnackBarBehavior.floating,
        ));
      } else {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('${c.name} $action 成功'),
          behavior: SnackBarBehavior.floating,
        ));
      }
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('$action 失败：$e'),
        behavior: SnackBarBehavior.floating,
      ));
    } finally {
      if (mounted) {
        setState(() {
          _busyContainerId = '';
          _busyAction = '';
        });
      }
    }
  }

  Future<void> _rename(DockerContainer c) async {
    final controller = TextEditingController(text: c.name);
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('重命名容器'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: '新名称'),
          onSubmitted: (v) => Navigator.pop(context, v.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    if (name == null || name.isEmpty || !mounted) return;
    await _action(c, 'rename', name: name);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Docker 容器管理'),
        actions: [
          IconButton(
            tooltip: '刷新',
            onPressed: _load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: _buildBody(scheme),
    );
  }

  Widget _buildBody(ColorScheme scheme) {
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.inventory_2, size: 52, color: scheme.error.withValues(alpha: 0.6)),
              const SizedBox(height: 12),
              const Text('Docker 不可用或连接失败'),
              const SizedBox(height: 8),
              Text(
                _error!,
                style: TextStyle(
                  fontSize: 12,
                  color: scheme.onSurfaceVariant,
                  fontFamily: 'monospace',
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: _load,
                icon: const Icon(Icons.refresh),
                label: const Text('重试'),
              ),
            ],
          ),
        ),
      );
    }
    if (_containers == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_containers!.isEmpty) {
      return const Center(child: Text('没有任何 Docker 容器'));
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.separated(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
        itemCount: _containers!.length,
        separatorBuilder: (_, __) => const SizedBox(height: 8),
        itemBuilder: (context, i) {
          final c = _containers![i];
          return _ContainerCard(
            sessionId: widget.sessionId,
            container: c,
            expanded: _expanded.contains(c.id),
            busy: _busyContainerId == c.id,
            busyAction: _busyAction,
            onToggle: () => setState(() {
              if (!_expanded.remove(c.id)) _expanded.add(c.id);
            }),
            onAction: (action) => _action(c, action),
            onRename: () => _rename(c),
          );
        },
      ),
    );
  }
}

class _ContainerCard extends StatelessWidget {
  const _ContainerCard({
    required this.sessionId,
    required this.container,
    required this.expanded,
    required this.busy,
    required this.busyAction,
    required this.onToggle,
    required this.onAction,
    required this.onRename,
  });

  final String sessionId;
  final DockerContainer container;
  final bool expanded;
  final bool busy;
  final String busyAction;
  final VoidCallback onToggle;
  final ValueChanged<String> onAction;
  final VoidCallback onRename;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final c = container;
    final color = c.running ? Colors.greenAccent : scheme.outline;
    return Card(
      child: InkWell(
        onTap: onToggle,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.circle, size: 12, color: color),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      c.name,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.bold,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      c.running ? '运行中' : '已停止',
                      style: TextStyle(fontSize: 11, color: color),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              _InfoRow(label: '镜像', value: c.image),
              const SizedBox(height: 3),
              _InfoRow(label: '状态', value: c.status),
              const SizedBox(height: 3),
              _InfoRow(
                label: '端口',
                value: c.ports.isEmpty ? '无端口映射' : c.ports,
              ),
              const SizedBox(height: 3),
              _InfoRow(
                label: '容器ID',
                value: c.id.length > 24 ? '${c.id.substring(0, 24)}…' : c.id,
                mono: true,
              ),
              const SizedBox(height: 3),
              _InfoRow(label: '创建时间', value: c.createdAt),
              if (expanded) ...[
                const Divider(height: 16),
                _InfoRow(label: 'State', value: c.state),
                const SizedBox(height: 3),
                _InfoRow(label: '完整ID', value: c.id, mono: true),
                const Divider(height: 16),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    _ActionChip(
                      label: '启动',
                      icon: Icons.play_arrow,
                      enabled: !c.running,
                      busy: busy,
                      busyAction: busyAction,
                      action: 'start',
                      onPressed: onAction,
                    ),
                    _ActionChip(
                      label: '停止',
                      icon: Icons.stop,
                      enabled: c.running,
                      busy: busy,
                      busyAction: busyAction,
                      action: 'stop',
                      onPressed: onAction,
                    ),
                    _ActionChip(
                      label: '重启',
                      icon: Icons.restart_alt,
                      enabled: c.running,
                      busy: busy,
                      busyAction: busyAction,
                      action: 'restart',
                      onPressed: onAction,
                    ),
                    _ActionChip(
                      label: '暂停',
                      icon: Icons.pause,
                      enabled: c.running && !c.status.contains('Paused'),
                      busy: busy,
                      busyAction: busyAction,
                      action: 'pause',
                      onPressed: onAction,
                    ),
                    _ActionChip(
                      label: '恢复',
                      icon: Icons.play_circle_outline,
                      enabled: c.running && c.status.contains('Paused'),
                      busy: busy,
                      busyAction: busyAction,
                      action: 'unpause',
                      onPressed: onAction,
                    ),
                    _ActionChip(
                      label: '强杀',
                      icon: Icons.power_off,
                      enabled: c.running,
                      busy: busy,
                      busyAction: busyAction,
                      action: 'kill',
                      onPressed: onAction,
                    ),
                    _ActionChip(
                      label: '删除',
                      icon: Icons.delete_outline,
                      enabled: true,
                      busy: busy,
                      busyAction: busyAction,
                      action: 'remove',
                      onPressed: onAction,
                      destructive: true,
                    ),
                    _ActionChip(
                      label: '重命名',
                      icon: Icons.drive_file_rename_outline,
                      enabled: true,
                      busy: busy,
                      busyAction: busyAction,
                      action: 'rename',
                      onPressed: (_) => onRename(),
                    ),
                  ],
                ),
                const Divider(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: busy ? null : () => SshDockerOpen.terminal(context, sessionId: sessionId, containerId: c.id, title: c.name),
                        icon: const Icon(Icons.terminal, size: 16),
                        label: const Text('终端'),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: busy ? null : () => SshDockerOpen.logs(context, sessionId: sessionId, containerId: c.id, title: c.name),
                        icon: const Icon(Icons.receipt_long, size: 16),
                        label: const Text('日志'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: busy ? null : () => SshDockerOpen.files(context, sessionId: sessionId, containerId: c.id, title: c.name),
                    icon: const Icon(Icons.folder_open, size: 16),
                    label: const Text('容器文件管理'),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({
    required this.label,
    required this.value,
    this.mono = false,
  });

  final String label;
  final String value;
  final bool mono;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 62,
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12,
              color: scheme.onSurfaceVariant,
            ),
          ),
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            value,
            style: TextStyle(
              fontSize: 12,
              color: mono ? scheme.primary : scheme.onSurface,
              fontFamily: mono ? 'monospace' : null,
            ),
          ),
        ),
      ],
    );
  }
}

class _ActionChip extends StatelessWidget {
  const _ActionChip({
    required this.label,
    required this.icon,
    required this.enabled,
    required this.busy,
    required this.busyAction,
    required this.action,
    required this.onPressed,
    this.destructive = false,
  });

  final String label;
  final IconData icon;
  final bool enabled;
  final bool busy;
  final String busyAction;
  final String action;
  final ValueChanged<String> onPressed;
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final active = busy && busyAction == action;
    return ActionChip(
      avatar: active
          ? SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Icon(icon, size: 16),
      label: Text(label),
      backgroundColor: destructive
          ? scheme.errorContainer.withValues(alpha: 0.5)
          : null,
      onPressed: enabled && !busy ? () => onPressed(action) : null,
    );
  }
}

/// 统一入口：打开容器终端/日志/文件悬浮窗。
class SshDockerOpen {
  const SshDockerOpen._();

  static void terminal(
    BuildContext context, {
    required String sessionId,
    required String containerId,
    String? title,
  }) {
    SshFloatingTerminal.show(
      context,
      sessionId: sessionId,
      containerId: containerId,
      title: title,
    );
  }

  static void logs(
    BuildContext context, {
    required String sessionId,
    required String containerId,
    String? title,
  }) {
    SshFloatingLogs.show(
      context,
      sessionId: sessionId,
      containerId: containerId,
      title: title,
    );
  }

  static void files(
    BuildContext context, {
    required String sessionId,
    required String containerId,
    String? title,
  }) {
    SshFloatingFiles.show(
      context,
      sessionId: sessionId,
      containerId: containerId,
      title: title,
    );
  }
}

/// 供 SSH 管理页调用的打开方式。
Future<void> showDockerPage(BuildContext context, String sessionId) {
  return Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) => DockerContainerPage(sessionId: sessionId),
    ),
  );
}
