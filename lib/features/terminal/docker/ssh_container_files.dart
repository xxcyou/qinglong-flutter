import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/code_editor_page.dart';
import '../../../shared/confirm_dialog.dart';
import '../../../shared/file_kinds.dart';
import '../../../shared/image_viewer_page.dart';
import '../../../shared/text_input_dialog.dart';
import '../providers/shell_files_provider.dart';
import '../providers/ssh_session_provider.dart';
import 'container_file_relay.dart';
import 'docker_container.dart';
import 'ssh_floating_host.dart';

/// 悬浮窗容器内部文件管理：
/// 浏览/新建文件/新建目录/重命名/删除/改权限/复制/剪切/粘贴，
/// 点击文件可查看图片/编辑文本，并通过中转与外部（本地/SSH）文件管理器互通。
class SshFloatingFiles {
  static int? _id;

  static void show(
    BuildContext context, {
    required String sessionId,
    required String containerId,
    String? title,
  }) {
    if (_id != null) return;
    late final int id;
    id = SshFloatingHost.add(
      context,
      group: containerId,
      title: title ?? '容器文件',
      icon: Icons.folder_open,
      builder: (_) => SshFloatingFilesWindow(
        sessionId: sessionId,
        containerId: containerId,
        title: title,
        onFocus: () => SshFloatingHost.focus(id),
        onMinimize: () => SshFloatingHost.minimize(id),
        onClose: () {
          SshFloatingHost.close(id);
          _id = null;
        },
      ),
    );
    _id = id;
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
    required this.onFocus,
    required this.onMinimize,
    required this.onClose,
  });

  final String sessionId;
  final String containerId;
  final String? title;
  final VoidCallback onFocus;
  final VoidCallback onMinimize;
  final VoidCallback onClose;

  @override
  State<SshFloatingFilesWindow> createState() => _SshFloatingFilesWindowState();
}

class _SshFloatingFilesWindowState extends State<SshFloatingFilesWindow> {
  Offset _pos = const Offset(32, 100);
  Size _size = const Size(420, 360);

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final width = (_size.width).clamp(320.0, media.size.width - 12);
    final height = (_size.height).clamp(280.0, media.size.height - 100);
    final left = _pos.dx.clamp(0.0, media.size.width - width - 8);
    final top = _pos.dy.clamp(MediaQuery.paddingOf(context).top,
        media.size.height - height - 8);
    return Stack(
      fit: StackFit.expand,
      children: [
        Positioned(
          left: left,
          top: top,
          width: width,
          height: height,
          child: Stack(
            children: [
              Positioned.fill(
                child: GestureDetector(
                  onTapDown: (_) => widget.onFocus(),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: Material(
                      color: const Color(0xFFF2F2F6),
                      child: SshContainerFilesView(
                        sessionId: widget.sessionId,
                        containerId: widget.containerId,
                        title: widget.title,
                      ),
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
                  onTapDown: (_) => widget.onFocus(),
                  onPanUpdate: (d) => setState(() => _pos += d.delta),
                  child: Container(
                    color: const Color(0x00FFFFFF),
                    padding: const EdgeInsets.only(left: 8),
                    alignment: Alignment.centerLeft,
                    child: Text(
                      '${widget.title ?? '容器文件'} · ${widget.containerId.length > 8 ? widget.containerId.substring(0, 8) : widget.containerId}',
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
                right: 32,
                top: 0,
                child: IconButton(
                  tooltip: '最小化容器文件管理',
                  visualDensity: VisualDensity.compact,
                  constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
                  iconSize: 14,
                  padding: EdgeInsets.zero,
                  icon: const Icon(Icons.minimize, color: Colors.black54),
                  onPressed: widget.onMinimize,
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
                  onTapDown: (_) => widget.onFocus(),
                  onPanUpdate: (d) {
                    setState(() {
                      _size = Size(
                        (_size.width + d.delta.dx).clamp(320.0, 1200.0),
                        (_size.height + d.delta.dy).clamp(280.0, 1000.0),
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
        ),
      ],
    );
  }
}

class SshContainerFilesView extends ConsumerStatefulWidget {
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
  ConsumerState<SshContainerFilesView> createState() =>
      _SshContainerFilesViewState();
}

class _SshContainerFilesViewState extends ConsumerState<SshContainerFilesView> {
  String path = '/';
  List<ContainerFileEntry> entries = const [];
  bool loading = true;
  String? error;
  bool _busy = false;
  final Map<String, Uint8List> _thumbCache = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  String get _docker => 'docker exec ${widget.containerId}';

  static String _shq(String s) => "'${s.replaceAll("'", "'\\''")}'";

  Future<String> _runRemote(String command) async {
    setState(() => _busy = true);
    try {
      return await SshSessionManager.instance
          .executeFull(widget.sessionId, command);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _load() async {
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final cmd = "$_docker sh -c 'ls -la \"\$1\" 2>&1' sh ${_shq(path)}";
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

  /// 兼容常见 GNU/BusyBox `ls -la`：按空白拆分，取最后一段为名字。
  List<ContainerFileEntry> _parse(String raw) {
    final result = <ContainerFileEntry>[];
    for (final line in raw.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isEmpty || trimmed.startsWith('total ')) continue;
      final tokens = trimmed.split(RegExp(r'\s+'));
      if (tokens.length < 8) continue;
      final mode = tokens[0];
      if (mode.length < 2 || !mode.startsWith(RegExp(r'[-dlcbps]'))) continue;
      final name = tokens.sublist(8).join(' ');
      if (name.isEmpty || name == '.' || name == '..') continue;
      result.add(ContainerFileEntry(
        name: name,
        isDirectory: mode.startsWith('d'),
        size: int.tryParse(tokens[4]) ?? 0,
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

  String _abs(ContainerFileEntry e) => _join(path, e.name);

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
    final r = await _runRemote(
        "$_docker sh -c 'mkdir -p \"\$1\" 2>&1' sh ${_shq(dir)}");
    if (r.contains('[exit=')) return _toast('新建文件夹失败：$r');
    await _load();
  }

  Future<void> _newFile() async {
    final name = await showTextInputDialog(
      context,
      title: '新建文件',
      labelText: '文件名',
      confirmText: '创建',
    );
    if (name == null || name.trim().isEmpty || !mounted) return;
    final file = _join(path, name.trim());
    final r =
        await _runRemote("$_docker sh -c 'touch \"\$1\" 2>&1' sh ${_shq(file)}");
    if (r.contains('[exit=')) return _toast('新建文件失败：$r');
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
    final src = _abs(e);
    final dst = _join(path, name.trim());
    final r = await _runRemote(
        "$_docker sh -c 'mv -- \"\$1\" \"\$2\" 2>&1' sh ${_shq(src)} ${_shq(dst)}");
    if (r.contains('[exit=')) return _toast('重命名失败：$r');
    await _load();
  }

  Future<void> _chmod(ContainerFileEntry e) async {
    final mode = await showTextInputDialog(
      context,
      title: '修改权限',
      labelText: '权限（如 755 / 644）',
      initialValue: e.isDirectory ? '755' : '644',
      confirmText: '修改',
    );
    if (mode == null || mode.trim().isEmpty || !mounted) return;
    final target = _abs(e);
    final r = await _runRemote(
        "$_docker sh -c 'chmod \"\$1\" -- \"\$2\" 2>&1' sh ${_shq(mode.trim())} ${_shq(target)}");
    if (r.contains('[exit=')) return _toast('修改权限失败：$r');
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
    final flag = e.isDirectory ? 'rm -rf --' : 'rm -f --';
    final r = await _runRemote(
        "$_docker sh -c '$flag \"\$1\" 2>&1' sh ${_shq(_abs(e))}");
    if (r.contains('[exit=')) return _toast('删除失败：$r');
    await _load();
  }

  // ---------- 复制/剪切中转 ----------

  Future<void> _copyOrCut(ContainerFileEntry e, {required bool cut}) async {
    if (e.isDirectory) {
      _toast('中转暂只支持文件，文件夹请先进入后复制文件');
      return;
    }
    try {
      final bytes =
          await DockerService(widget.sessionId).readFileBytes(
        widget.containerId,
        _abs(e),
      );
      ContainerFileRelay.set(ContainerRelayItem(
        name: e.name,
        bytes: bytes,
        cut: cut,
        sourceType: ContainerRelaySourceType.container,
        sourcePath: _abs(e),
        sourceSshId: widget.sessionId,
        sourceContainerId: widget.containerId,
      ));
      _toast(cut ? '已剪切，到目标位置粘贴' : '已复制，到目标位置粘贴');
    } catch (err) {
      _toast('读取容器文件失败：$err');
    }
  }

  Future<void> _paste() async {
    final item = ContainerFileRelay.item;
    if (item != null) {
      final target = _join(path, item.name);
      try {
        await DockerService(widget.sessionId)
            .writeFileBytes(widget.containerId, target, item.bytes);
        if (item.cut) {
          if (item.sourceType == ContainerRelaySourceType.container) {
            await DockerService(item.sourceSshId!)
                .deleteFile(item.sourceContainerId!, item.sourcePath);
          } else if (item.sourceType == ContainerRelaySourceType.ssh) {
            await ref
                .read(shellFilesProvider.notifier)
                .deleteAtScope(item.sourcePath, FileScope.ssh, item.sourceSshId);
          } else {
            await ref
                .read(shellFilesProvider.notifier)
                .deleteAtScope(
                  item.sourcePath,
                  item.sourceType == ContainerRelaySourceType.app
                      ? FileScope.app
                      : FileScope.shell,
                  null,
                );
          }
        }
        ContainerFileRelay.clear();
        await _load();
        _toast('已粘贴到容器');
      } catch (err) {
        _toast('粘贴失败：$err');
      }
      return;
    }

    // 兼容旧剪贴板/未走中转的外部复制：直接从 provider 剪贴板取字节。
    final st = ref.read(shellFilesProvider);
    final sourcePath = st.clipboardPath;
    final sourceScopeName = st.clipboardScope;
    if (sourcePath == null || sourceScopeName == null) {
      _toast('没有可粘贴的内容');
      return;
    }
    final sourceScope = FileScope.values.firstWhere(
      (e) => e.name == sourceScopeName,
      orElse: () => FileScope.shell,
    );
    try {
      final bytes = await ref.read(shellFilesProvider.notifier).readBytesAtScope(
            sourcePath,
            sourceScope,
            st.clipboardSshId,
          );
      if (bytes == null) {
        _toast('读取源文件失败');
        return;
      }
      final target = _join(path, sourcePath.split('/').last);
      await DockerService(widget.sessionId)
          .writeFileBytes(widget.containerId, target, bytes);
      if (st.clipboardIsCut) {
        await ref.read(shellFilesProvider.notifier).deleteAtScope(
              sourcePath,
              sourceScope,
              st.clipboardSshId,
            );
      }
      await _load();
      _toast('已粘贴到容器');
    } catch (err) {
      _toast('粘贴失败：$err');
    }
  }

  // ---------- 打开文件：图片/文本编辑 ----------

  Future<void> _openWithAutoMinimize(Future<void> Function() open) async {
    // 打开编辑器前自动收缩本容器的所有悬浮窗，避免遮挡阅读。
    final expanded = SshFloatingHost.minimizeExpandedGroup(widget.containerId);
    try {
      await open();
    } finally {
      if (mounted) {
        SshFloatingHost.restoreExpandedGroup(widget.containerId, expanded);
      }
    }
  }

  Future<void> _openEntry(ContainerFileEntry e) async {
    if (e.isDirectory) return _enter(e.name);
    final absolute = _abs(e);
    final kind = FileKinds.of(e.name);
    try {
      final bytes =
          await DockerService(widget.sessionId).readFileBytes(
        widget.containerId,
        absolute,
      );
      if (kind.category == FileCategory.image) {
        if (!mounted || bytes.isEmpty) return;
        await _openWithAutoMinimize(() async {
          if (!mounted) return;
          await Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => ImageViewerPage(
                title: e.name,
                subtitle: '容器内图片 · ${FileKinds.sizeText(e.size)}',
                imageBytes: [bytes],
                imageNames: [e.name],
              ),
            ),
          );
        });
        return;
      }
      if (kind.needsExternalApp) {
        _toast('该类型暂不支持内置打开，可下载到本地后用其它应用打开');
        return;
      }
      final text = utf8.decode(bytes, allowMalformed: true);
      if (!mounted) return;
      await _openWithAutoMinimize(() async {
        if (!mounted) return;
        await Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => CodeEditorPage(
              path: absolute,
              initial: text,
              subtitle: '${kind.label} · 容器内文件',
              onSave: (content) async {
                try {
                  await DockerService(widget.sessionId).writeFileBytes(
                    widget.containerId,
                    absolute,
                    Uint8List.fromList(utf8.encode(content)),
                  );
                  return true;
                } catch (_) {
                  return false;
                }
              },
              onDelete: () async {
                final r = await DockerService(widget.sessionId)
                    .deleteFile(widget.containerId, absolute);
                return !r.contains('[exit=');
              },
            ),
          ),
        );
      });
    } catch (err) {
      _toast('打开文件失败：$err');
    }
  }

  Future<Uint8List?> _readThumb(String name) async {
    final abs = _join(path, name);
    final cached = _thumbCache[abs];
    if (cached != null) return cached;
    try {
      final bytes =
          await DockerService(widget.sessionId).readFileBytes(
        widget.containerId,
        abs,
      );
      if (bytes.isNotEmpty) _thumbCache[abs] = bytes;
      return bytes.isEmpty ? null : bytes;
    } catch (_) {
      return null;
    }
  }

  Widget _leading(ContainerFileEntry e) {
    final kind = FileKinds.of(e.name);
    if (kind.category == FileCategory.image && !e.isDirectory) {
      return FutureBuilder<Uint8List?>(
        future: _readThumb(e.name),
        builder: (context, snap) {
          final bytes = snap.data;
          if (bytes == null || bytes.isEmpty) {
            return const Icon(Icons.image_outlined);
          }
          return ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: Image.memory(
              bytes,
              width: 40,
              height: 40,
              fit: BoxFit.cover,
              gaplessPlayback: true,
            ),
          );
        },
      );
    }
    return Icon(
      e.isDirectory ? Icons.folder_outlined : Icons.insert_drive_file_outlined,
      color: e.isDirectory ? Colors.amber : null,
    );
  }

  Future<void> _showItemActions(ContainerFileEntry e) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text(e.name, maxLines: 1, overflow: TextOverflow.ellipsis),
              dense: true,
            ),
            const Divider(height: 1),
            if (!e.isDirectory) ...[
              ListTile(
                leading: const Icon(Icons.content_copy),
                title: const Text('复制'),
                onTap: () => Navigator.pop(context, 'copy'),
              ),
              ListTile(
                leading: const Icon(Icons.content_cut),
                title: const Text('剪切'),
                onTap: () => Navigator.pop(context, 'cut'),
              ),
            ],
            ListTile(
              leading: const Icon(Icons.drive_file_rename_outline),
              title: const Text('重命名'),
              onTap: () => Navigator.pop(context, 'rename'),
            ),
            ListTile(
              leading: const Icon(Icons.lock_outline),
              title: const Text('修改权限'),
              onTap: () => Navigator.pop(context, 'chmod'),
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline, color: Colors.red),
              title: const Text('删除', style: TextStyle(color: Colors.red)),
              onTap: () => Navigator.pop(context, 'delete'),
            ),
          ],
        ),
      ),
    );
    if (action == null || !mounted) return;
    switch (action) {
      case 'copy':
        await _copyOrCut(e, cut: false);
      case 'cut':
        await _copyOrCut(e, cut: true);
      case 'rename':
        await _rename(e);
      case 'chmod':
        await _chmod(e);
      case 'delete':
        await _delete(e);
    }
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
    final canPaste = ContainerFileRelay.hasValue;
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
                onPressed: _busy ? null : _up,
                icon: const Icon(Icons.arrow_upward),
              ),
              IconButton(
                tooltip: '刷新',
                visualDensity: VisualDensity.compact,
                iconSize: 18,
                onPressed: _busy ? null : _load,
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
                tooltip: '粘贴',
                visualDensity: VisualDensity.compact,
                iconSize: 18,
                onPressed: _busy || !canPaste ? null : _paste,
                icon: const Icon(Icons.content_paste_go),
                color: canPaste ? scheme.primary : null,
              ),
              IconButton(
                tooltip: '新建文件',
                visualDensity: VisualDensity.compact,
                iconSize: 18,
                onPressed: _busy ? null : _newFile,
                icon: const Icon(Icons.note_add_outlined),
              ),
              IconButton(
                tooltip: '新建文件夹',
                visualDensity: VisualDensity.compact,
                iconSize: 18,
                onPressed: _busy ? null : _mkdir,
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
                              leading: _leading(e),
                              title: Text(
                                e.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              subtitle: e.isDirectory
                                  ? null
                                  : Text(
                                      '${e.size} B',
                                      style: const TextStyle(fontSize: 10),
                                    ),
                              trailing: IconButton(
                                tooltip: '操作',
                                visualDensity: VisualDensity.compact,
                                iconSize: 18,
                                icon: const Icon(Icons.more_horiz),
                                onPressed:
                                    _busy ? null : () => _showItemActions(e),
                              ),
                              onTap: e.isDirectory
                                  ? () => _enter(e.name)
                                  : () => _openEntry(e),
                            );
                          },
                        ),
        ),
      ],
    );
  }
}
