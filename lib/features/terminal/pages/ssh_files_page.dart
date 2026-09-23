import 'dart:async';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../providers/ssh_session_provider.dart';

class SshFilesPage extends ConsumerStatefulWidget {
  const SshFilesPage({super.key, this.sessionId});

  final String? sessionId;

  /// 从文件夹管理/侧滑/附件面板弹起 SFTP 文件管理。
  static Future<void> showSheet(BuildContext context, {String? sessionId}) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.92,
        minChildSize: 0.5,
        maxChildSize: 0.96,
        builder: (context, _) => ClipRRect(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          child: Material(
            color: Theme.of(context).colorScheme.surface.withValues(alpha: 0.9),
            child: SshFilesPage(sessionId: sessionId),
          ),
        ),
      ),
    );
  }

  @override
  ConsumerState<SshFilesPage> createState() => _SshFilesPageState();
}

class _SftpEntry {
  const _SftpEntry({
    required this.name,
    required this.isDirectory,
    required this.longname,
  });

  final String name;
  final bool isDirectory;
  final String longname;
}

class _SshFilesPageState extends ConsumerState<SshFilesPage> {
  String? _sessionId;
  String _path = '.';
  List<_SftpEntry> _entries = [];
  final Map<String, SftpClient> _sftpClients = {};
  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final sessions = SshSessionManager.instance.sessions
        .where((s) => s.status == 'connected')
        .toList();
    _sessionId =
        widget.sessionId ?? (sessions.isEmpty ? null : sessions.first.id);
    if (_sessionId != null) Future.microtask(_load);
  }

  @override
  void didUpdateWidget(SshFilesPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.sessionId != oldWidget.sessionId) {
      _sessionId = widget.sessionId;
      _path = '.';
      _load();
    }
  }

  Future<SftpClient> _sftpFor(String id) async {
    final existing = _sftpClients[id];
    if (existing != null) return existing;
    final client = SshSessionManager.instance.clientOf(id);
    if (client == null) throw StateError('SSH 未连接');
    final sftp = await client.sftp();
    _sftpClients[id] = sftp;
    return sftp;
  }

  Future<void> _load() async {
    final id = _sessionId;
    if (id == null) return;
    try {
      final sftp = await _sftpFor(id);
      final items = await sftp.listdir(_path);
      final entries = <_SftpEntry>[];
      for (final item in items) {
        final name = item.filename;
        if (name.isEmpty || name == '.' || name == '..') continue;
        entries.add(_SftpEntry(
          name: name,
          isDirectory: item.attr.isDirectory,
          longname: item.longname.isEmpty ? name : item.longname,
        ));
      }
      if (mounted) {
        setState(() {
          _entries = entries;
          _loading = false;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = '$e';
        });
      }
    }
  }

  Future<void> _open(String name) async {
    final sep = _path.endsWith('/') || _path == '.' ? '' : '/';
    _path = _path == '.' ? name : '$_path$sep$name';
    setState(() => _loading = true);
    await _load();
  }

  void _goUp() {
    if (_path == '.' || _path.isEmpty) return;
    final idx = _path.lastIndexOf('/');
    _path = idx <= 0 ? '.' : _path.substring(0, idx);
    setState(() => _loading = true);
    _load();
  }

  Future<void> _mkdir() async {
    final name = await _prompt('新建文件夹', '文件夹名');
    if (name == null || name.trim().isEmpty) return;
    try {
      final sftp = await _sftpFor(_sessionId!);
      await sftp.mkdir(_path == '.' ? name : '$_path/$name');
      await _load();
    } catch (e) {
      _showError('$e');
    }
  }

  Future<void> _rename(_SftpEntry entry) async {
    final name = await _prompt('重命名', '新名称', initial: entry.name);
    if (name == null || name.trim().isEmpty) return;
    final base = _path == '.' ? '' : '$_path/';
    try {
      final sftp = await _sftpFor(_sessionId!);
      await sftp.rename('$base${entry.name}', '$base${name.trim()}');
      await _load();
    } catch (e) {
      _showError('$e');
    }
  }

  Future<void> _delete(_SftpEntry entry) async {
    try {
      final sftp = await _sftpFor(_sessionId!);
      final base = _path == '.' ? '' : '$_path/';
      if (entry.isDirectory) {
        await sftp.rmdir('$base${entry.name}');
      } else {
        await sftp.remove('$base${entry.name}');
      }
      await _load();
    } catch (e) {
      _showError('$e');
    }
  }

  Future<void> _upload() async {
    final result = await FilePicker.pickFiles();
    if (result == null || result.files.isEmpty) return;
    final file = result.files.single;
    final localPath = file.path;
    if (localPath == null) return;
    try {
      final sftp = await _sftpFor(_sessionId!);
      final remote = _path == '.'
          ? file.name
          : _path.endsWith('/')
              ? '$_path${file.name}'
              : '$_path/${file.name}';
      final remoteFile = await sftp.open(
        remote,
        mode: SftpFileOpenMode.write |
            SftpFileOpenMode.create |
            SftpFileOpenMode.truncate,
      );
      await remoteFile.write(File(localPath).openRead().cast()).done;
      await remoteFile.close();
      await _load();
      _showError('上传完成：${file.name}');
    } catch (e) {
      _showError('上传失败：$e');
    }
  }

  Future<void> _download(_SftpEntry entry) async {
    try {
      final sftp = await _sftpFor(_sessionId!);
      final base = _path == '.' ? '' : '$_path/';
      final remoteFile = await sftp.open('$base${entry.name}');
      final dir = await getDownloadsDirectory();
      final toPath = dir == null
          ? '/sdcard/Download/${entry.name}'
          : '${dir.path}/${entry.name}';
      final sink = File(toPath).openWrite();
      await remoteFile.downloadTo(sink, closeDestination: true);
      await remoteFile.close();
      _showError('已下载到 $toPath');
    } catch (e) {
      _showError('下载失败：$e');
    }
  }

  Future<String?> _prompt(String title, String label,
      {String initial = ''}) async {
    final controller = TextEditingController(text: initial);
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(labelText: label),
          onSubmitted: (v) => Navigator.pop(context, v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    controller.dispose();
    return value;
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final sshState = ref.watch(sshSessionsProvider);
    final connected = [
      for (final s in sshState.sessions)
        if (s.isConnected) s
    ];
    final scheme = Theme.of(context).colorScheme;

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          child: Row(
            children: [
              Expanded(
                child: DropdownButton<String?>(
                  value: _sessionId,
                  isExpanded: true,
                  hint: const Text('选择已连接的 SSH 终端'),
                  items: [
                    for (final s in connected)
                      DropdownMenuItem(
                        value: s.id,
                        child: Text('${s.name} (${s.username}@${s.host})',
                            overflow: TextOverflow.ellipsis),
                      ),
                  ],
                  onChanged: (v) {
                    setState(() {
                      _sessionId = v;
                      _path = '.';
                    });
                    _load();
                  },
                ),
              ),
              IconButton(
                tooltip: '刷新',
                onPressed: _load,
                icon: const Icon(Icons.refresh),
              ),
              IconButton(
                tooltip: '新建文件夹',
                onPressed: connected.isEmpty ? null : _mkdir,
                icon: const Icon(Icons.create_new_folder_outlined),
              ),
              IconButton(
                tooltip: '上传文件',
                onPressed: connected.isEmpty ? null : _upload,
                icon: const Icon(Icons.upload_file),
              ),
              IconButton(
                tooltip: '上一级',
                onPressed: _path == '.' ? null : _goUp,
                icon: const Icon(Icons.arrow_upward),
              ),
            ],
          ),
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Text(
              _error!,
              style: TextStyle(color: scheme.error),
            ),
          ),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : connected.isEmpty
                  ? const Center(child: Text('还没有已连接的 SSH 终端，请先在终端页新建 SSH'))
                  : _entries.isEmpty
                      ? const Center(child: Text('空目录'))
                      : ListView.separated(
                          padding: const EdgeInsets.all(12),
                          itemCount: _entries.length,
                          separatorBuilder: (_, __) =>
                              const SizedBox(height: 6),
                          itemBuilder: (context, i) {
                            final e = _entries[i];
                            return ListTile(
                              dense: true,
                              leading: Icon(
                                e.isDirectory
                                    ? Icons.folder_outlined
                                    : Icons.insert_drive_file_outlined,
                                color: e.isDirectory
                                    ? scheme.primary
                                    : scheme.onSurfaceVariant,
                              ),
                              title: Text(e.name),
                              subtitle: Text(e.longname,
                                  maxLines: 1, overflow: TextOverflow.ellipsis),
                              onTap: e.isDirectory
                                  ? () => _open(e.name)
                                  : () {
                                      Clipboard.setData(ClipboardData(
                                          text: '$currentRemote${e.name}'));
                                      _showErrorOnCopy(e.name);
                                    },
                              trailing: PopupMenuButton<String>(
                                onSelected: (v) {
                                  if (v == 'download') _download(e);
                                  if (v == 'rename') _rename(e);
                                  if (v == 'delete') _delete(e);
                                },
                                itemBuilder: (_) => const [
                                  PopupMenuItem(
                                    value: 'download',
                                    child: Text('下载'),
                                  ),
                                  PopupMenuItem(
                                    value: 'rename',
                                    child: Text('重命名'),
                                  ),
                                  PopupMenuItem(
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

  String get currentRemote {
    final p = _path == '.'
        ? ''
        : _path.endsWith('/')
            ? _path
            : '$_path/';
    return p;
  }

  void _showErrorOnCopy(String name) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已复制远程路径：$currentRemote$name')),
    );
  }
}
