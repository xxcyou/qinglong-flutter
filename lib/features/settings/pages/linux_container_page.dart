import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/local_shell/proot_bridge.dart';
import '../../../shared/confirm_dialog.dart';
import '../../terminal/providers/terminal_session_provider.dart';

class LinuxContainerPage extends ConsumerStatefulWidget {
  const LinuxContainerPage({super.key});

  @override
  ConsumerState<LinuxContainerPage> createState() => _LinuxContainerPageState();
}

class _LinuxContainerPageState extends ConsumerState<LinuxContainerPage> {
  late final ProotBridge _bridge = ProotBridge();
  List<Map<String, dynamic>> _containers = [];
  List<Map<String, dynamic>> _online = [];
  bool _loading = true;
  String? _error;
  bool _busy = false;

  Color _distroColor(String distro) {
    switch (distro.toLowerCase()) {
      case 'debian':
        return const Color(0xFFA81D33);
      case 'ubuntu':
        return const Color(0xFFE95420);
      case 'alpine':
        return const Color(0xFF0D597F);
      default:
        return Theme.of(context).colorScheme.primary;
    }
  }

  IconData _distroIcon(String distro) {
    switch (distro.toLowerCase()) {
      case 'debian':
        return Icons.verified_user_rounded;
      case 'ubuntu':
        return Icons.circle_rounded;
      case 'alpine':
        return Icons.landscape_rounded;
      default:
        return Icons.dns_outlined;
    }
  }

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    try {
      final status = await _bridge.status();
      final list = await _bridge.containerList();
      final online = await _bridge.containerCatalog();
      if (!mounted) return;
      setState(() {
        _containers = list;
        _online = online;
        _error = status.installed ? null : 'Linux Runtime 尚未安装';
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _install() async {
    setState(() { _busy = true; _error = null; });
    final notifier = ref.read(terminalSessionProvider.notifier);
    await notifier.install();
    if (!mounted) return;
    setState(() { _busy = false; });
    await _reload();
  }

  Future<void> _clone() async {
    setState(() { _busy = true; _error = null; });
    try {
      final nameCtrl = TextEditingController();
      final name = await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('克隆当前容器'),
          content: TextField(
            controller: nameCtrl,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: '新容器名称（可留空）',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(nameCtrl.text.trim()),
              child: const Text('克隆'),
            ),
          ],
        ),
      );
      if (name == null) {
        if (mounted) setState(() { _busy = false; });
        return;
      }
      await _bridge.containerClone(name: name);
      if (!mounted) return;
      setState(() { _busy = false; });
      await _reload();
    } catch (e) {
      if (!mounted) return;
      setState(() { _busy = false; _error = e.toString(); });
    }
  }

  Future<void> _download(Map<String, dynamic> online) async {
    final id = online['id']?.toString() ?? '';
    final name = online['name']?.toString() ?? id;
    final ok = await showConfirmDialog(
      context,
      title: '下载容器',
      message: '下载「$name」，完成后不会自动切换。\n下载体积较大请保持网络稳定。',
      confirmText: '开始下载',
    );
    if (!ok) return;
    setState(() { _busy = true; _error = null; });
    try {
      final r = await _bridge.containerDownload(id);
      if (!mounted) return;
      setState(() { _busy = false; });
      await _reload();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('「${r['name'] ?? name}」下载完成')),
        );
      }
    } catch (e) {
      if (!mounted) return;
      setState(() { _busy = false; _error = e.toString(); });
    }
  }

  Future<void> _export(String id) async {
    setState(() { _busy = true; _error = null; });
    try {
      final r = await _bridge.containerExport(id);
      if (!mounted) return;
      setState(() { _busy = false; });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已导出：${r['filename'] ?? 'linux-container-$id.tar.gz'}（下载/Download/qinglong_linux）')),
        );
      }
    } catch (e) {
      if (!mounted) return;
      setState(() { _busy = false; _error = e.toString(); });
    }
  }

  Future<void> _import() async {
    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['tar', 'gz', 'tgz'],
    );
    final path = result?.files.single.path;
    if (path == null) return;
    setState(() { _busy = true; _error = null; });
    try {
      final r = await _bridge.containerImport(path);
      if (!mounted) return;
      setState(() { _busy = false; });
      await _reload();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已导入容器：${r['name']}')),
        );
      }
    } catch (e) {
      if (!mounted) return;
      setState(() { _busy = false; _error = e.toString(); });
    }
  }

  Future<void> _switch(String id) async {
    final ok = await showConfirmDialog(
      context,
      title: '切换 Linux 容器',
      message: '切换后会停掉所有正在跑的终端，再切到「$id」。',
      confirmText: '切换',
    );
    if (!ok) return;
    setState(() { _busy = true; _error = null; });
    try {
      await _bridge.containerSwitch(id);
      if (!mounted) return;
      setState(() { _busy = false; });
      await _reload();
    } catch (e) {
      if (!mounted) return;
      setState(() { _busy = false; _error = e.toString(); });
    }
  }

  Future<void> _delete(String id) async {
    final ok = await showConfirmDialog(
      context,
      title: '删除容器',
      message: '确定删除容器「$id」吗？这个操作不可恢复。\n当前激活的容器不能删除。',
      confirmText: '删除',
      destructive: true,
    );
    if (!ok) return;
    setState(() { _busy = true; _error = null; });
    try {
      await _bridge.containerDelete(id);
      if (!mounted) return;
      setState(() { _busy = false; });
      await _reload();
    } catch (e) {
      if (!mounted) return;
      setState(() { _busy = false; _error = e.toString(); });
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Linux 容器'),
        actions: [
          IconButton(
            tooltip: '导入容器',
            onPressed: _busy ? null : _import,
            icon: const Icon(Icons.file_download_outlined),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _reload,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 40),
          children: [
            Text(
              '每个容器是一套独立的 Linux 根文件系统，可以下载、克隆、删除和切换。',
              style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 12),
            if (_loading)
              const Center(child: Padding(padding: EdgeInsets.all(32), child: CircularProgressIndicator()))
            else if (_error != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  _error!,
                  style: TextStyle(fontSize: 12, color: scheme.error),
                ),
              ),
            if (_online.isNotEmpty && !_loading) ...[
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(
                  '在线下载',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
              for (final online in _online) ...[
                _OnlineContainerCard(
                  online: online,
                  color: _distroColor(online['distro']?.toString() ?? ''),
                  icon: _distroIcon(online['distro']?.toString() ?? ''),
                  busy: _busy,
                  onDownload: () => _download(online),
                ),
              ],
              const SizedBox(height: 4),
            ],
            if (_containers.isNotEmpty) ...[
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(
                  '已安装容器',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                    color: scheme.tertiary,
                  ),
                ),
              ),
            ],
            if (_containers.isEmpty && !_loading)
              GlassCard(
                child: Column(
                  children: [
                    const Icon(Icons.dns_outlined, size: 38),
                    const SizedBox(height: 8),
                    const Text('还没有可用的 Linux 容器'),
                    const SizedBox(height: 10),
                    FilledButton.icon(
                      onPressed: _busy ? null : _install,
                      icon: const Icon(Icons.download),
                      label: Text(_busy ? '正在下载…' : '下载并安装 Debian'),
                    ),
                  ],
                ),
              ),
            for (final c in _containers)
              GlassCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          c['isActive'] == true
                              ? Icons.check_circle
                              : Icons.circle_outlined,
                          color: c['isActive'] == true
                              ? scheme.primary
                              : scheme.onSurfaceVariant,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            c['name']?.toString() ?? '',
                            style: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        if (c['isActive'] == true)
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 3,
                            ),
                            decoration: BoxDecoration(
                              color: scheme.primaryContainer,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Text(
                              '当前',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                                color: scheme.onPrimaryContainer,
                              ),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'id：${c['id']}',
                      style: TextStyle(
                        fontSize: 10.5,
                        fontFamily: 'monospace',
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        if (c['isActive'] != true)
                          Expanded(
                            child: FilledButton.tonalIcon(
                              onPressed: _busy ? null : () => _switch(c['id']!.toString()),
                              icon: const Icon(Icons.swap_horiz, size: 16),
                              label: const Text('切换'),
                            ),
                          ),
                        if (c['isActive'] != true) const SizedBox(width: 8),
                        if (c['isActive'] != true)
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: _busy ? null : () => _delete(c['id']!.toString()),
                              icon: const Icon(Icons.delete_outline, size: 16),
                              label: const Text('删除'),
                            ),
                          ),
                        if (c['isActive'] != true) const SizedBox(width: 8),
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: _busy ? null : _clone,
                            icon: const Icon(Icons.copy_outlined, size: 16),
                            label: const Text('克隆'),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: _busy
                            ? null
                            : () => _export(c['id']!.toString()),
                        icon: const Icon(Icons.upload_file_outlined, size: 16),
                        label: const Text('导出容器'),
                      ),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 12),
            GlassCard(
              child: ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.science_outlined),
                title: const Text('说明'),
                subtitle: const Text(
                  '“在线下载”：Debian / Alpine / Ubuntu 等；\n“导入/导出”：tar.gz 容器镜像；\n“克隆”：复制当前容器；\n切换后终端里的所有会话都会重开。',
                  style: TextStyle(fontSize: 12),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _OnlineContainerCard extends StatelessWidget {
  const _OnlineContainerCard({
    required this.online,
    required this.color,
    required this.icon,
    required this.busy,
    required this.onDownload,
  });

  final Map<String, dynamic> online;
  final Color color;
  final IconData icon;
  final bool busy;
  final VoidCallback onDownload;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final size = (online['sizeBytes'] is num) ? (online['sizeBytes'] as num).toDouble() : 0.0;
    final sizeText = size > 0 ? '${(size / 1048576).toStringAsFixed(1)} MB' : '未知大小';
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: scheme.outlineVariant.withValues(alpha: 0.5),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.18),
                  shape: BoxShape.circle,
                  border: Border.all(color: color.withValues(alpha: 0.4)),
                ),
                child: Icon(icon, size: 20, color: color),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      online['name']?.toString() ?? '',
                      style: const TextStyle(
                        fontSize: 14.5,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      online['description']?.toString() ?? '',
                      style: TextStyle(
                        fontSize: 11,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Icon(Icons.storage_outlined, size: 13, color: scheme.onSurfaceVariant),
              const SizedBox(width: 4),
              Text(
                sizeText,
                style: TextStyle(
                  fontSize: 11,
                  color: scheme.onSurfaceVariant,
                ),
              ),
              const Spacer(),
              FilledButton.tonalIcon(
                onPressed: busy ? null : onDownload,
                style: FilledButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  textStyle: const TextStyle(fontSize: 11),
                ),
                icon: const Icon(Icons.download_rounded, size: 15),
                label: Text(busy ? '下载中…' : '下载'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class GlassCard extends StatelessWidget {
  const GlassCard({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.3)),
      ),
      child: child,
    );
  }
}
