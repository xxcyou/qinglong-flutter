import 'package:flutter/material.dart';

import '../providers/ssh_session_provider.dart';
import '../../../shared/text_input_dialog.dart';
import '../../../shared/confirm_dialog.dart';

/// 悬浮窗容器内部文件管理：通过 docker exec 浏览/新建/重命名/删除容器内文件。
class SshFloatingFiles {
  static OverlayEntry? _entry;

  static void show(
    BuildContext context, {
    required String sessionId,
    required String containerId,
    String? title,
  }) {
    if (_entry != null) return;
    final overlay = Overlay.of(context, rootOverlay: true);
    final entry = OverlayEntry(
      builder: (_) => SshFloatingFilesWindow(
        sessionId: sessionId,
        containerId: containerId,
        title: title,
        onClose: () {
          _entry?.remove();
          _entry = null;
        },
      ),
    );
    _entry = entry;
    overlay.insert(entry);
  }
}

class ContainerFileEntry {
  const ContainerFileEntry({
    required this.name,
    required this.isDirectory,
    required this.size,
  });

  final String name;
  final bool isDirectory;
  final int size;
}

class SshFloatingFilesWindow extends StatefulWidget {
  const SshFloatingFilesWindow({
    super.key,
    required this.sessionId,
    required this.containerId,
    required this.title,
    required this.onClose,
  });

  final String sessionId;
  final String containerId;
  final String? title;
  final VoidCallback onClose;

  @override
  State<SshFloatingFilesWindow> createState() => _SshFloatingFilesWindowState();
}

class _SshFloatingFilesWindowState extends State<SshFloatingFilesWindow> {
  Offset _pos = const Offset(32, 100);
  Size _size = const Size(380, 320);

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final width = (_size.width).clamp(260.0, media.size.width - 16);
    final height = (_size.height).clamp(220.0, media.size.height - 100);
    final left = _pos.dx.clamp(0.0, media.size.width - width - 8);
    final top = _pos.dy.clamp(MediaQuery.paddingOf(context).top,
        media.size.height - height - 8);
    return Positioned(
      left: left,
      top: top,
      width: width,
      height: height,
      child: Stack(
        children: [
          Positioned.fill(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Material(
                color: const Color(0xEFF0F0F4),
                child: SshContainerFilesView(
                  sessionId: widget.sessionId,
                  containerId: widget.containerId,
                  title: widget.title,
                ),
              ),
            ),
          ),
          Positioned(
            left: 0,
            right: 36,
            top: 0,
            height: 20,
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onPanUpdate: (d) => setState(() => _pos += d.delta),
              child: Container(
                color: const Color(0x00FFFFFF),
                padding: const EdgeInsets.only(left: 8),
                alignment: Alignment.centerLeft,
                child: Text(
                  '${widget.title ?? '容器文件'} · ${widget.containerId.substring(0, widget.containerId.length > 8 ? 8 : widget.containerId.length)}',
                  style: const TextStyle(
                    fontSize: 11,
                    color: Colors.black54,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            right: 2,
            top: 0,
            child: IconButton(
              tooltip: '关闭容器文件管理',
              visualDensity: VisualDensity.compact,
              constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
              iconSize: 14,
              padding: EdgeInsets.zero,
              icon: const Icon(Icons.close_rounded, color: Colors.black54),
              onPressed: widget.onClose,
            ),
          ),
          Positioned(
            right: 0,
            bottom: 0,
            width: 20,
            height: 20,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onPanUpdate: (d) {
                setState(() {
                  _size = Size(
                    (_size.width + d.delta.dx).clamp(260.0, 900.0),
                    (_size.height + d.delta.dy).clamp(220.0, 800.0),
                  );
                });
              },
              child: const Icon(
                Icons.open_in_full_rounded,
                size: 13,
                color: Colors.black38,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class SshContainerFilesView extends StatefulWidget {
  const SshContainerFilesView({
    super.key,
    required this.sessionId,
    required this.containerId,
    this.title,
  });

  final String sessionId;
  final String containerId;
  final String? title;

  @override
  State<SshContainerFilesView> createState() => _SshContainerFilesViewState();
}

class _SshContainerFilesViewState extends State<SshContainerFilesView> {
  String path = '/';
  List<ContainerFileEntry> entries = const [];
  bool loading = true;
  String? error;
  @override
  void initState() {
    super.initState();
    _load();
  }

  String get _docker => 'docker exec ${widget.containerId}';

  static String _shq(String s) => "'${s.replaceAll("'", "'\\''")}'";

  Future<void> _load() async {
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final cmd =
          "$_docker sh -c 'ls -la \"\$1\" 2>&1' sh ${_shq(path)}";
      final raw =
          await SshSessionManager.instance.executeFull(widget.sessionId, cmd);
      final parsed = _parse(raw);
      if (!mounted) return;
      setState(() {
        entries = parsed;
        loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        error = '$e';
        loading = false;
      });
    }
  }

  List<ContainerFileEntry> _parse(String raw) {
    final result = <ContainerFileEntry>[];
    final lines = raw.split('\n');
    final re = RegExp(r'^([bcdlps-])[rwxStTs-]{9}\s+\d+\s+\S+\s+\S+\s+(\d+)\s+.+?\s+(.+)$');
    for (final line in lines) {
      final m = re.firstMatch(line.trim());
      if (m == null) continue;
      final name = m.group(2)?.trim() ?? '';
      if (name == '.' || name == '..' || name.isEmpty) continue;
      result.add(ContainerFileEntry(
        name: name,
        isDirectory: m.group(1) == 'd',
        size: int.tryParse(m.group(2) ?? '') ?? 0,
      ));
    }
    result.sort((a, b) {
      if (a.isDirectory != b.isDirectory) return a.isDirectory ? -1 : 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return result;
  }

  String _join(String dir, String name) {
    if (dir.endsWith('/')) return '$dir$name';
    return '$dir/$name';
  }

  Future<void> _enter(String name) async {
    path = _join(path, name);
    await _load();
  }

  Future<void> _up() async {
    if (path == '/' || path.isEmpty) return;
    final idx = path.lastIndexOf('/');
    path = idx <= 0 ? '/' : path.substring(0, idx);
    await _load();
  }

  Future<void> _mkdir() async {
    final name = await showTextInputDialog(
      context,
      title: '新建文件夹',
      labelText: '文件夹名',
      confirmText: '创建',
    );
    if (name == null || name.trim().isEmpty || !mounted) return;
    final dir = _join(path, name.trim());
    final cmd =
        "$_docker sh -c 'mkdir -p \"\$1\" 2>&1' sh ${_shq(dir)}";
    final r = await SshSessionManager.instance.executeFull(widget.sessionId, cmd);
    if (r.contains('[exit=')) {
      if (mounted) _toast('新建失败：$r');
      return;
    }
    await _load();
  }

  Future<void> _rename(ContainerFileEntry e) async {
    final name = await showTextInputDialog(
      context,
      title: '重命名',
      labelText: '新名称',
      initialValue: e.name,
    );
    if (name == null || name.trim().isEmpty || !mounted) return;
    final src = _join(path, e.name);
    final dst = _join(path, name.trim());
    final cmd =
        "$_docker sh -c 'mv -- \"\$1\" \"\$2\" 2>&1' sh ${_shq(src)} ${_shq(dst)}";
    final r = await SshSessionManager.instance.executeFull(widget.sessionId, cmd);
    if (r.contains('[exit=')) {
      if (mounted) _toast('重命名失败：$r');
      return;
    }
    await _load();
  }

  Future<void> _delete(ContainerFileEntry e) async {
    final ok = await showConfirmDialog(
      context,
      title: '删除 ${e.name}？',
      message: e.isDirectory ? '目录会被整个删除，且不可恢复。' : '文件删除后不可恢复。',
      confirmText: '删除',
      destructive: true,
    );
    if (!ok || !mounted) return;
    final target = _join(path, e.name);
    final flag = e.isDirectory ? 'rm -rf --' : 'rm -f --';
    final cmd =
        "$_docker sh -c '$flag \"\$1\" 2>&1' sh ${_shq(target)}";
    final r = await SshSessionManager.instance.executeFull(widget.sessionId, cmd);
    if (r.contains('[exit=')) {
      if (mounted) _toast('删除失败：$r');
      return;
    }
    await _load();
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      behavior: SnackBarBehavior.floating,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 22, 6, 4),
          child: Row(
            children: [
              IconButton(
                tooltip: '上一级',
                visualDensity: VisualDensity.compact,
                iconSize: 18,
                onPressed: _up,
                icon: const Icon(Icons.arrow_upward),
              ),
              IconButton(
                tooltip: '刷新',
                visualDensity: VisualDensity.compact,
                iconSize: 18,
                onPressed: _load,
                icon: const Icon(Icons.refresh),
              ),
              Expanded(
                child: Text(
                  path,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: scheme.onSurface,
                  ),
                ),
              ),
              IconButton(
                tooltip: '新建文件夹',
                visualDensity: VisualDensity.compact,
                iconSize: 18,
                onPressed: _mkdir,
                icon: const Icon(Icons.create_new_folder_outlined),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: loading
              ? const Center(child: CircularProgressIndicator())
              : error != null
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Text(error!, style: TextStyle(color: scheme.error)),
                      ),
                    )
                  : entries.isEmpty
                      ? const Center(child: Text('空目录'))
                      : ListView.builder(
                          itemCount: entries.length,
                          itemBuilder: (context, i) {
                            final e = entries[i];
                            return ListTile(
                              dense: true,
                              leading: Icon(
                                e.isDirectory
                                    ? Icons.folder_outlined
                                    : Icons.insert_drive_file_outlined,
                                color: e.isDirectory ? Colors.amber : null,
                              ),
                              title: Text(e.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                              trailing: PopupMenuButton<String>(
                                onSelected: (v) {
                                  if (v == 'rename') _rename(e);
                                  if (v == 'delete') _delete(e);
                                },
                                itemBuilder: (_) => [
                                  const PopupMenuItem(
                                    value: 'rename',
                                    child: Text('重命名'),
                                  ),
                                  const PopupMenuItem(
                                    value: 'delete',
                                    child: Text('删除'),
                                  ),
                                ],
                              ),
                              onTap: e.isDirectory ? () => _enter(e.name) : null,
                            );
                          },
                        ),
        ),
      ],
    );
  }
}
