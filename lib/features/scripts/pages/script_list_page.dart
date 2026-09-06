import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/utils/error_text.dart';
import '../../../shared/confirm_dialog.dart';
import '../../../shared/text_input_dialog.dart';
import '../../../shared/empty_view.dart';
import '../../../shared/error_view.dart';
import '../../../shared/glass_scaffold.dart';
import '../../../shared/loading_view.dart';
import '../../../shared/search_field.dart';
import '../../ai/providers/chat_provider.dart';
import '../../home/home_navigation_provider.dart';
import '../models/script_node.dart';
import '../providers/script_list_provider.dart';
import 'script_edit_page.dart';

class ScriptListPage extends ConsumerStatefulWidget {
  const ScriptListPage({super.key});

  @override
  ConsumerState<ScriptListPage> createState() => _ScriptListPageState();
}

class _ScriptListPageState extends ConsumerState<ScriptListPage> {
  final _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    Future.microtask(() => ref.read(scriptListProvider.notifier).load());
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(scriptListProvider);
    final visible = _filterRoots(state.roots, state.search);

    return GlassScaffold(
      title: '脚本管理',
      actions: [
        IconButton(
          tooltip: '新建脚本',
          onPressed: _newScript,
          icon: const Icon(Icons.note_add_outlined),
        ),
        IconButton(
          tooltip: '上传脚本',
          onPressed: _upload,
          icon: const Icon(Icons.upload_file_outlined),
        ),
        IconButton(
          tooltip: '新建文件夹',
          onPressed: _newFolder,
          icon: const Icon(Icons.create_new_folder_outlined),
        ),
      ],
      headerInline: SearchField(
        controller: _searchController,
        hintText: '搜索脚本文件',
        onChanged: ref.read(scriptListProvider.notifier).setSearch,
      ),
      body: _buildBody(state, visible),
    );
  }

  Widget _buildBody(ScriptListState state, List<ScriptNode> roots) {
    if (state.isLoading && roots.isEmpty) return const LoadingView();
    if (state.error != null && roots.isEmpty) {
      return ErrorView(
        message: errorText(state.error!),
        onRetry: ref.read(scriptListProvider.notifier).refresh,
      );
    }
    if (roots.isEmpty) {
      return EmptyView(
        message: state.search.isNotEmpty ? '没有匹配的脚本' : '暂无脚本\n点右上角新建或上传',
        icon: Icons.description_outlined,
      );
    }
    return RefreshIndicator(
      onRefresh: ref.read(scriptListProvider.notifier).refresh,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 44),
        children: [
          for (final node in roots)
            _ScriptNodeTile(
              node: node,
              onOpen: _openFile,
              onDelete: _deleteFile,
              onRename: _renameNode,
              onSendToAi: _sendToAi,
            ),
        ],
      ),
    );
  }

  List<ScriptNode> _filterRoots(List<ScriptNode> roots, String search) {
    if (search.isEmpty) return roots;
    return [
      for (final node in roots)
        if (_filterNode(node, search) case final ScriptNode n) n,
    ];
  }

  ScriptNode? _filterNode(ScriptNode node, String search) {
    final match = node.title.toLowerCase().contains(search.toLowerCase());
    if (node.isLeaf) {
      return match ? node : null;
    }
    final children = [
      for (final child in node.children)
        if (_filterNode(child, search) case final ScriptNode c) c,
    ];
    if (children.isEmpty && !match) return null;
    return ScriptNode(
      title: node.title,
      key: node.key,
      isLeaf: false,
      children: children,
      size: node.size,
    );
  }

  Future<void> _newScript() async {
    final path = await showTextInputDialog(
      context,
      title: '新建脚本',
      labelText: '相对路径',
      hintText: '如 daily/checkin.js',
      confirmText: '下一步',
    );
    if (path == null || path.isEmpty || !mounted) return;
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
          builder: (_) => ScriptEditPage(path: path, isNew: true)),
    );
    if (saved == true) {
      Future.microtask(() => ref.read(scriptListProvider.notifier).refresh());
    }
  }

  Future<void> _upload() async {
    try {
      final result = await FilePicker.pickFiles(withData: true);
      if (result == null || result.files.isEmpty || !mounted) return;
      final file = result.files.single;
      final bytes = file.bytes;
      if (bytes == null) return;
      final content = utf8.decode(bytes);
      final path = file.name;
      await ref.read(scriptListProvider.notifier).create(path, content);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已上传 $path')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('上传失败：${errorText(e)}')),
        );
      }
    }
  }

  Future<void> _newFolder() async {
    final name = await showTextInputDialog(
      context,
      title: '新建文件夹',
      labelText: '文件夹名称',
      confirmText: '创建',
    );
    if (name == null || name.trim().isEmpty || !mounted) return;
    try {
      await ref
          .read(scriptListProvider.notifier)
          .createDirectory('', name.trim());
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已创建文件夹 ${name.trim()}')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('创建失败：${errorText(e)}')),
        );
      }
    }
  }

  Future<void> _renameNode(ScriptNode node) async {
    final current = node.key ?? node.title;
    final index = current.lastIndexOf('/');
    final parent = index < 0 ? '' : current.substring(0, index);
    final filename = index < 0 ? current : current.substring(index + 1);
    final newName = await showTextInputDialog(
      context,
      title: node.isLeaf ? '重命名脚本' : '重命名文件夹',
      labelText: '新名称',
      initialValue: filename,
      confirmText: '重命名',
    );
    if (newName == null || newName.trim().isEmpty || !mounted) return;
    final base = newName.trim().contains('/')
        ? newName.trim().split('/').last
        : newName.trim();
    try {
      await ref
          .read(scriptListProvider.notifier)
          .rename(parent.isEmpty ? base : '$parent/$base', base);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已重命名 $filename → $base')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('重命名失败：${errorText(e)}')),
        );
      }
    }
  }

  void _sendToAi(ScriptNode node) {
    ref.read(homeTabIndexProvider.notifier).state = 2;
    ref.read(chatProvider.notifier).send(
          '帮我看看这个脚本：${node.title}${node.key == null ? '' : '（路径：$node.key）'}',
        );
  }

  Future<void> _openFile(ScriptNode node) async {
    final key = node.key;
    if (key == null || !node.isLeaf) return;
    await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => ScriptEditPage(path: key)),
    );
    Future.microtask(() => ref.read(scriptListProvider.notifier).refresh());
  }

  Future<void> _deleteFile(ScriptNode node) async {
    final isDir = !node.isLeaf;
    final ok = await showConfirmDialog(
      context,
      title: isDir ? '删除文件夹' : '删除脚本',
      message: isDir ? '确定删除文件夹「${node.title}」及其内容？' : '确定删除「${node.title}」？',
      confirmText: '删除',
      destructive: true,
    );
    if (ok && node.key != null) {
      try {
        await ref
            .read(scriptListProvider.notifier)
            .remove(node.key!, isDirectory: isDir);
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('删除失败：${errorText(e)}')),
          );
        }
      }
    }
  }
}

class _ScriptNodeTile extends StatelessWidget {
  const _ScriptNodeTile({
    required this.node,
    required this.onOpen,
    required this.onDelete,
    required this.onRename,
    required this.onSendToAi,
    this.depth = 0,
  });

  final ScriptNode node;
  final ValueChanged<ScriptNode> onOpen;
  final ValueChanged<ScriptNode> onDelete;
  final ValueChanged<ScriptNode> onRename;
  final ValueChanged<ScriptNode> onSendToAi;
  final int depth;

  @override
  Widget build(BuildContext context) {
    if (node.isLeaf) {
      return _ScriptFileTile(
        node: node,
        onOpen: onOpen,
        onDelete: onDelete,
        onRename: onRename,
        onSendToAi: onSendToAi,
        depth: depth,
      );
    }
    return _ScriptDirectoryTile(
      node: node,
      onDelete: onDelete,
      onRename: onRename,
      onSendToAi: onSendToAi,
      onOpen: onOpen,
      depth: depth,
    );
  }
}

class _ScriptFileTile extends StatelessWidget {
  const _ScriptFileTile({
    required this.node,
    required this.onOpen,
    required this.onDelete,
    required this.onRename,
    required this.onSendToAi,
    required this.depth,
  });

  final ScriptNode node;
  final ValueChanged<ScriptNode> onOpen;
  final ValueChanged<ScriptNode> onDelete;
  final ValueChanged<ScriptNode> onRename;
  final ValueChanged<ScriptNode> onSendToAi;
  final int depth;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final sizeText = formatFileSize(node.size);
    return Padding(
      padding: EdgeInsets.only(left: depth * 12, bottom: 6),
      child: GlassCard(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        onTap: () => onOpen(node),
        child: Row(
          children: [
            const Icon(
              Icons.description_outlined,
              size: 20,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    node.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  if (sizeText != null)
                    Text(
                      sizeText,
                      style: TextStyle(
                        fontSize: 11,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
            ),
            PopupMenuButton<String>(
              onSelected: (value) {
                switch (value) {
                  case 'edit':
                    onOpen(node);
                  case 'rename':
                    onRename(node);
                  case 'ai':
                    onSendToAi(node);
                  case 'delete':
                    onDelete(node);
                }
              },
              itemBuilder: (context) => const [
                PopupMenuItem(value: 'edit', child: Text('编辑')),
                PopupMenuItem(value: 'rename', child: Text('重命名')),
                PopupMenuItem(value: 'ai', child: Text('发给 AI 分析')),
                PopupMenuItem(value: 'delete', child: Text('删除')),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ScriptDirectoryTile extends StatefulWidget {
  const _ScriptDirectoryTile({
    required this.node,
    required this.onOpen,
    required this.onDelete,
    required this.onRename,
    required this.onSendToAi,
    required this.depth,
  });

  final ScriptNode node;
  final ValueChanged<ScriptNode> onOpen;
  final ValueChanged<ScriptNode> onDelete;
  final ValueChanged<ScriptNode> onRename;
  final ValueChanged<ScriptNode> onSendToAi;
  final int depth;

  @override
  State<_ScriptDirectoryTile> createState() => _ScriptDirectoryTileState();
}

class _ScriptDirectoryTileState extends State<_ScriptDirectoryTile> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: GlassCard(
        padding: EdgeInsets.zero,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            InkWell(
              onTap: () => setState(() => _expanded = !_expanded),
              child: Padding(
                padding: EdgeInsets.only(
                  left: 12 + widget.depth * 12,
                  right: 4,
                  top: 6,
                  bottom: 6,
                ),
                child: Row(
                  children: [
                    const Icon(
                      Icons.folder_outlined,
                      size: 20,
                      color: Colors.amber,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        widget.node.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                    Icon(
                      _expanded ? Icons.expand_less : Icons.expand_more,
                      size: 18,
                      color: scheme.onSurfaceVariant,
                    ),
                    PopupMenuButton<String>(
                      onSelected: (value) {
                        switch (value) {
                          case 'rename':
                            widget.onRename(widget.node);
                          case 'delete':
                            widget.onDelete(widget.node);
                        }
                      },
                      itemBuilder: (context) => const [
                        PopupMenuItem(value: 'rename', child: Text('重命名')),
                        PopupMenuItem(value: 'delete', child: Text('删除')),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            AnimatedCrossFade(
              firstChild: const SizedBox(width: double.infinity),
              secondChild: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final child in widget.node.children)
                    _ScriptNodeTile(
                      node: child,
                      onOpen: widget.onOpen,
                      onDelete: widget.onDelete,
                      onRename: widget.onRename,
                      onSendToAi: widget.onSendToAi,
                      depth: widget.depth + 1,
                    ),
                ],
              ),
              crossFadeState: _expanded
                  ? CrossFadeState.showSecond
                  : CrossFadeState.showFirst,
              duration: const Duration(milliseconds: 180),
              sizeCurve: Curves.easeOut,
            ),
          ],
        ),
      ),
    );
  }
}

String? formatFileSize(int? bytes) {
  if (bytes == null || bytes < 0) return null;
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) {
    return '${(bytes / 1024).toStringAsFixed(1)} KB';
  }
  return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
}
