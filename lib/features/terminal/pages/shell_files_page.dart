import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/local_shell/proot_bridge.dart';
import '../../../core/theme/glass.dart';
import '../../../core/utils/formatter.dart';
import '../../../shared/ask_ai.dart';
import '../../../shared/code_editor_page.dart';
import '../../../shared/floating_editor_window.dart';
import '../../../shared/confirm_dialog.dart';
import '../../../shared/file_kinds.dart';
import '../../../shared/glass_scaffold.dart';
import '../../../shared/image_viewer_page.dart';
import '../../../shared/text_input_dialog.dart';
import '../providers/shell_files_provider.dart';
import '../widgets/file_action_sheet.dart';
import '../../../shared/mono_text.dart';

/// 完整文件管理器：终端（PRoot guest，含 rootfs 根目录）与 APP 沙箱两套根，
/// 支持新建/重命名/复制/剪切/粘贴/删除/权限/属性/搜索/排序/多选。
///
/// 它不再是独立一页——从终端页底部拉起来的面板，用完就收，
/// 终端本体始终占满整屏。
class ShellFilesPage extends ConsumerStatefulWidget {
  const ShellFilesPage({
    super.key,
    this.asSheet = false,
    this.floatingEditor = false,
    this.onClose,
    this.closeIcon,
  });

  /// 以底部面板形式出现时自带拖动把手与关闭按钮，不画返回箭头。
  final bool asSheet;

  /// 在 AI 半屏文件面板里使用时，点文本/代码文件弹出悬浮编辑器，
  /// 而不是全屏跳转。
  final bool floatingEditor;

  /// 面板模式的自定义收起回调；不传时默认 Navigator.maybePop。
  final VoidCallback? onClose;

  /// 面板模式收起按钮图标。
  final IconData? closeIcon;

  /// 从终端页底部拉起文件管理。
  static Future<void> showSheet(BuildContext context) {
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
          // 半透明 + 模糊：整块面板是玻璃，底下的页面还看得见轮廓。
          child: BackdropFilter(
            filter: ImageFilter.blur(
                sigmaX: Glass.blurStrong, sigmaY: Glass.blurStrong),
            child: Material(
              color:
                  Theme.of(context).colorScheme.surface.withValues(alpha: 0.86),
              child: const ShellFilesPage(asSheet: true),
            ),
          ),
        ),
      ),
    );
  }

  @override
  ConsumerState<ShellFilesPage> createState() => _ShellFilesPageState();
}

class _ShellFilesPageState extends ConsumerState<ShellFilesPage> {
  final _searchController = TextEditingController();
  bool _searchVisible = false;

  @override
  void initState() {
    super.initState();
    Future.microtask(() => ref.read(shellFilesProvider.notifier).open());
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  ShellFilesNotifier get _notifier => ref.read(shellFilesProvider.notifier);

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(shellFilesProvider);
    final entries = state.visibleEntries;

    final subtitle = state.isSearchMode
        ? '搜索结果 ${entries.length} 项'
        : '${state.scope.label} · ${entries.length} 项';
    final actions = <Widget>[
      IconButton(
        tooltip: '搜索',
        onPressed: () {
          setState(() => _searchVisible = !_searchVisible);
          if (!_searchVisible) {
            _searchController.clear();
            _notifier.setKeyword('');
            _notifier.exitSearch();
          }
        },
        icon: Icon(_searchVisible ? Icons.search_off : Icons.search),
      ),
      PopupMenuButton<String>(
        tooltip: '视图',
        icon: const Icon(Icons.tune),
        onSelected: (value) {
          switch (value) {
            case 'name':
              _notifier.setSort(FileSort.name);
            case 'size':
              _notifier.setSort(FileSort.size);
            case 'modified':
              _notifier.setSort(FileSort.modified);
            case 'hidden':
              _notifier.toggleHidden();
            case 'selectAll':
              _notifier.selectAll();
          }
        },
        itemBuilder: (_) => [
          for (final sort in FileSort.values)
            CheckedPopupMenuItem(
              value: sort.name,
              checked: state.sort == sort,
              child: Text(
                '按${sort.label}'
                '${state.sort == sort ? (state.descending ? ' ↓' : ' ↑') : ''}',
              ),
            ),
          const PopupMenuDivider(),
          CheckedPopupMenuItem(
            value: 'hidden',
            checked: state.showHidden,
            child: const Text('显示隐藏文件'),
          ),
          const PopupMenuItem(value: 'selectAll', child: Text('全选当前列表')),
        ],
      ),
    ];

    final content = Column(
      children: [
        _buildHeaderBottom(state),
        _PathBar(state: state, notifier: _notifier),
        if (state.error != null) _buildError(state),
        Expanded(child: _buildList(state, entries)),
      ],
    );

    if (!widget.asSheet) {
      return GlassScaffold(
        title: '文件',
        subtitle: subtitle,
        leading: const SizedBox.shrink(),
        bodyTopPadding: 0,
        actions: actions,
        bottomBar: state.isSelecting ? _buildSelectionBar(state) : null,
        body: content,
      );
    }

    return SafeArea(
      top: false,
      child: Stack(
        children: [
          Column(
            children: [
              // 拖动把手 + 标题行：面板模式下自己画，不借 GlassScaffold。
              Padding(
                padding: const EdgeInsets.only(top: 8, bottom: 2),
                child: Container(
                  width: 44,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Theme.of(context)
                        .colorScheme
                        .onSurfaceVariant
                        .withValues(alpha: 0.4),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 2, 4, 0),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            '文件管理',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          Text(
                            subtitle,
                            style: TextStyle(
                              fontSize: 11.5,
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                    // 半屏里标题和按钮抢宽度容易黄条，操作按钮横向可滚动。
                    Flexible(
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(children: actions),
                      ),
                    ),
                    IconButton(
                      tooltip: '收起',
                      onPressed: widget.onClose ??
                          () => Navigator.of(context).maybePop(),
                      icon: Icon(widget.closeIcon ?? Icons.close),
                    ),
                  ],
                ),
              ),
              Expanded(child: content),
            ],
          ),
          if (state.isSelecting)
            Positioned(
              left: 10,
              right: 10,
              bottom: 10,
              child: _buildSelectionBar(state),
            ),
        ],
      ),
    );
  }

  Widget _buildHeaderBottom(ShellFilesState state) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      child: Column(
        children: [
          SegmentedButton<FileScope>(
            segments: const [
              ButtonSegment(
                value: FileScope.shell,
                icon: Icon(Icons.terminal, size: 17),
                label: Text('终端文件'),
              ),
              ButtonSegment(
                value: FileScope.app,
                icon: Icon(Icons.phone_android, size: 17),
                label: Text('APP 文件'),
              ),
            ],
            selected: {state.scope},
            showSelectedIcon: false,
            onSelectionChanged: (v) => _notifier.switchScope(v.first),
          ),
          if (_searchVisible) ...[
            const SizedBox(height: 8),
            GlassPanel(
              radius: 16,
              blur: 12,
              shadowY: 2,
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              child: Row(
                children: [
                  const Icon(Icons.search, size: 18),
                  const SizedBox(width: 6),
                  Expanded(
                    child: TextField(
                      controller: _searchController,
                      autofocus: true,
                      style: const TextStyle(fontSize: 13),
                      decoration: const InputDecoration(
                        // 边输边过滤当前目录；回车才递归搜索子目录。
                        hintText: '正则/关键字；回车递归搜索',
                        border: InputBorder.none,
                        isDense: true,
                        filled: false,
                      ),
                      onChanged: _notifier.setKeyword,
                      onSubmitted: (v) => _notifier.search(v),
                    ),
                  ),
                  if (state.searching)
                    const SizedBox(
                      width: 15,
                      height: 15,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  else
                    IconButton(
                      tooltip: '正则 + 内容一起搜',
                      visualDensity: VisualDensity.compact,
                      onPressed: () => _notifier.search(
                        _searchController.text,
                        matchContent: true,
                      ),
                      icon: const Icon(Icons.manage_search, size: 20),
                    ),
                  if (state.isSearchMode)
                    IconButton(
                      tooltip: '退出搜索结果',
                      visualDensity: VisualDensity.compact,
                      onPressed: _notifier.exitSearch,
                      icon: const Icon(Icons.close, size: 18),
                    ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildError(ShellFilesState state) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(12, 4, 12, 0),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: scheme.errorContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              state.error!,
              style: TextStyle(color: scheme.onErrorContainer, fontSize: 12.5),
            ),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            onPressed: _notifier.clearError,
            icon: const Icon(Icons.close, size: 18),
          ),
        ],
      ),
    );
  }

  Widget _buildList(ShellFilesState state, List<ShellFileEntry> entries) {
    if (state.loading && entries.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (entries.isEmpty) {
      return RefreshIndicator(
        onRefresh: _notifier.refresh,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(0, 0, 0, 110),
          children: [
            const SizedBox(height: 120),
            Center(
              child: Text(
                state.isSearchMode
                    ? '没有匹配的文件'
                    : state.keyword.isNotEmpty
                        ? '当前目录没有匹配项'
                        : '这个目录是空的',
              ),
            ),
          ],
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _notifier.refresh,
      child: ListView.separated(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 110),
        itemCount: entries.length,
        separatorBuilder: (_, __) => const SizedBox(height: 8),
        itemBuilder: (context, index) {
          final entry = entries[index];
          return _FileTile(
            entry: entry,
            selected: state.selected.contains(entry.path),
            selecting: state.isSelecting,
            showPath: state.isSearchMode,
            onTap: () {
              if (state.isSelecting) {
                _notifier.toggleSelect(entry.path);
              } else {
                _open(entry);
              }
            },
            onLongPress: () => _showActions(entry),
            onAction: (action) => _handleAction(action, entry),
          );
        },
      ),
    );
  }

  Widget _buildSelectionBar(ShellFilesState state) {
    return GlassPanel(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      child: Row(
        children: [
          IconButton(
            tooltip: '取消选择',
            onPressed: _notifier.clearSelection,
            icon: const Icon(Icons.close),
          ),
          Expanded(
            child: Text(
              '已选 ${state.selected.length} 项',
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
          GlassPill(
            icon: Icons.delete_outline,
            label: '删除',
            dense: true,
            color: Theme.of(context).colorScheme.error,
            onTap: _deleteSelected,
          ),
        ],
      ),
    );
  }

  Future<void> _open(ShellFileEntry entry) async {
    if (entry.isDirectory) {
      await _notifier.open(entry.path);
      return;
    }
    final kind = FileKinds.of(entry.name);
    // 按文件类型分流：图片走内置查看器，压缩包/APK/PDF 这类交给系统 APP，
    // 其余（代码和纯文本）进带高亮的代码编辑器。
    if (kind.category == FileCategory.image) {
      await _openImage(entry, kind);
      return;
    }
    if (kind.needsExternalApp) {
      await _openBinary(entry, kind);
      return;
    }
    await _openText(entry);
  }

  Future<void> _openText(ShellFileEntry entry) async {
    final content = await _notifier.readFile(entry.path);
    if (content == null || !mounted) return;
    final kind = FileKinds.of(entry.name);
    if (widget.floatingEditor) {
      await showFloatingCodeEditor(
        context,
        path: entry.path,
        initial: content,
        subtitle: '${kind.label} · ${FileKinds.sizeText(entry.size)}',
        onSave: (text) => _notifier.saveFile(entry.path, text),
        onDelete: () => _notifier.delete(entry.path),
      );
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => CodeEditorPage(
          path: entry.path,
          initial: content,
          aiSource: 'file_manager',
          subtitle: '${kind.label} · ${FileKinds.sizeText(entry.size)}',
          onSave: (text) => _notifier.saveFile(entry.path, text),
          onDelete: () => _notifier.delete(entry.path),
        ),
      ),
    );
  }

  Future<void> _openImage(ShellFileEntry entry, FileKind kind) async {
    // Image.file 只认宿主真实路径，guest 路径（/workspace/...）读不到。
    final host = await _notifier.hostPath(entry.path);
    if (host == null || host.isEmpty || !mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ImageViewerPage(
          hostPath: host,
          title: entry.name,
          subtitle: FileKinds.sizeText(entry.size),
          onOpenExternal: () => _notifier.openExternal(
            entry.path,
            mime: FileKinds.mimeOf(entry.name),
          ),
        ),
      ),
    );
  }

  Future<void> _openBinary(ShellFileEntry entry, FileKind kind) async {
    await BinaryFileSheet.show(
      context,
      name: entry.name,
      kind: kind,
      sizeText: FileKinds.sizeText(entry.size),
      dateText: Formatter.dateTime(entry.modified),
      onOpenExternal: () => _notifier.openExternal(
        entry.path,
        mime: FileKinds.mimeOf(entry.name),
      ),
      onShare: () => _notifier.openExternal(
        entry.path,
        mime: FileKinds.mimeOf(entry.name),
        share: true,
      ),
      // 逃生口：有些"二进制"其实是文本（改错扩展名的日志、无扩展名的配置）。
      onForceText: () => _openText(entry),
    );
  }

  /// 长按（或点三点）弹出的 MT 风格操作菜单。
  Future<void> _showActions(ShellFileEntry entry) async {
    final state = ref.read(shellFilesProvider);
    // 多选进行中时长按就是继续勾选，不弹菜单——否则批量选文件会被打断。
    if (state.isSelecting) {
      _notifier.toggleSelect(entry.path);
      return;
    }
    await FileActionSheet.show(
      context,
      entry: entry,
      kind: FileKinds.of(entry.name, isDirectory: entry.isDirectory),
      canPaste: state.clipboardPath != null,
      onAction: (action) => _handleAction(action, entry),
    );
  }

  Future<void> _handleAction(String action, ShellFileEntry entry) async {
    final kind = FileKinds.of(entry.name, isDirectory: entry.isDirectory);
    switch (action) {
      case 'open':
        await _open(entry);
      case 'external':
        await _notifier.openExternal(
          entry.path,
          mime: FileKinds.mimeOf(entry.name),
        );
      case 'share':
        await _notifier.openExternal(
          entry.path,
          mime: FileKinds.mimeOf(entry.name),
          share: true,
        );
      case 'select':
        _notifier.toggleSelect(entry.path);
      case 'rename':
        await _rename(entry);
      case 'copy':
        _notifier.copyToClipboard(entry.path);
        _toast('已复制，进目标目录后点粘贴');
      case 'cut':
        _notifier.cutToClipboard(entry.path);
        _toast('已剪切，进目标目录后点粘贴');
      case 'pasteInto':
        await _notifier.paste(targetDir: entry.path);
      case 'copyPath':
        await Clipboard.setData(ClipboardData(text: entry.path));
        _toast('路径已复制到剪贴板');
      case 'askAi':
        await _askAi(entry, kind);
      case 'permissions':
        await _editPermissions(entry);
      case 'info':
        await _showInfo(entry);
      case 'delete':
        await _delete(entry);
    }
  }

  /// 把文件内容丢给 AI 悬浮窗（大文件截断，别把上下文一次吃光）。
  Future<void> _askAi(ShellFileEntry entry, FileKind kind) async {
    final content = await _notifier.readFile(entry.path);
    if (content == null || !mounted) return;
    const limit = 12000;
    final clipped = content.length > limit
        ? '${content.substring(0, limit)}\n…（文件共 ${content.length} 字符，已截断）'
        : content;
    AskAi.pushWithToast(
      context,
      ref,
      label: entry.name,
      content: clipped,
      source: 'file_manager',
      language: kind.language,
    );
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 1)),
    );
  }

  Future<void> _rename(ShellFileEntry entry) async {
    final name = await showTextInputDialog(
      context,
      title: '重命名',
      initialValue: entry.name,
      labelText: '新名称',
    );
    if (name == null || name.isEmpty || name == entry.name) return;
    await _notifier.rename(entry, name);
  }

  Future<void> _editPermissions(ShellFileEntry entry) async {
    var readable = entry.readable;
    var writable = entry.writable;
    var executable = entry.executable;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setLocal) => AlertDialog(
          title: const Text('权限'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                entry.name,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 4),
              const Text(
                'Android 沙箱只能改 owner 的 rwx；脚本要在终端里跑必须给执行位。',
                style: TextStyle(fontSize: 12),
              ),
              SwitchListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: const Text('可读 r'),
                value: readable,
                onChanged: (v) => setLocal(() => readable = v),
              ),
              SwitchListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: const Text('可写 w'),
                value: writable,
                onChanged: (v) => setLocal(() => writable = v),
              ),
              SwitchListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: const Text('可执行 x'),
                value: executable,
                onChanged: (v) => setLocal(() => executable = v),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('应用'),
            ),
          ],
        ),
      ),
    );
    if (ok != true) return;
    await _notifier.setPermissions(
      path: entry.path,
      readable: readable,
      writable: writable,
      executable: executable,
    );
  }

  Future<void> _showInfo(ShellFileEntry entry) async {
    final stat = await _notifier.stat(entry.path);
    if (stat == null || !mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(entry.name),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _InfoRow('路径', stat.entry.path),
              _InfoRow('类型', entry.isDirectory ? '目录' : '文件'),
              _InfoRow('大小', _size(stat.totalBytes)),
              if (entry.isDirectory)
                _InfoRow('内容', '${stat.fileCount} 个文件 · ${stat.dirCount} 个目录'),
              _InfoRow('权限', stat.entry.modeText),
              _InfoRow('修改时间', Formatter.dateTime(stat.entry.modified)),
              _InfoRow('宿主路径', stat.hostPath),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  Future<void> _delete(ShellFileEntry entry) async {
    final ok = await showConfirmDialog(
      context,
      title: '删除确认',
      message: entry.isDirectory
          ? '删除目录「${entry.name}」及其中所有内容？此操作不可恢复。'
          : '删除文件「${entry.name}」？此操作不可恢复。',
      confirmText: '删除',
      destructive: true,
    );
    if (!ok) return;
    await _notifier.delete(entry.path);
  }

  Future<void> _deleteSelected() async {
    final count = ref.read(shellFilesProvider).selected.length;
    final ok = await showConfirmDialog(
      context,
      title: '批量删除',
      message: '删除选中的 $count 项？目录会连同内容一起删除，不可恢复。',
      confirmText: '删除',
      destructive: true,
    );
    if (!ok) return;
    final done = await _notifier.deleteSelected();
    _toast('已删除 $done 项');
  }

  String _size(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / 1048576).toStringAsFixed(1)} MB';
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 64,
            child: Text(
              label,
              style: TextStyle(
                fontSize: 12.5,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(
            child: SelectableText(
              value,
              style: const TextStyle(fontSize: 12.5, fontFamily: 'monospace'),
            ),
          ),
        ],
      ),
    );
  }
}

class _PathBar extends StatelessWidget {
  const _PathBar({required this.state, required this.notifier});

  final ShellFilesState state;
  final ShellFilesNotifier notifier;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
      child: GlassPanel(
        radius: 18,
        blur: 14,
        shadowY: 3,
        padding: const EdgeInsets.fromLTRB(4, 4, 4, 6),
        child: Column(
          children: [
            Row(
              children: [
                IconButton(
                  tooltip: '上一级',
                  visualDensity: VisualDensity.compact,
                  onPressed: state.atRoot ? null : notifier.goUp,
                  icon: const Icon(Icons.arrow_upward, size: 20),
                ),
                Expanded(
                  child: Text(
                    state.path,
                    style: const TextStyle(
                      fontFamily: kMonoFamily,
                      fontFamilyFallback: kMonoFallback,
                      fontSize: 12.5,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            // 操作按钮横排可滚动：半屏侧滑面板宽度有限，硬塞一排会黄条溢出。
            SizedBox(
              height: 40,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 6),
                children: [
                  if (state.clipboardPath != null)
                    IconButton(
                      tooltip: state.clipboardIsCut ? '粘贴（移动）' : '粘贴（复制）',
                      visualDensity: VisualDensity.compact,
                      onPressed: () => notifier.paste(),
                      icon: Icon(
                        Icons.content_paste_go,
                        size: 20,
                        color: scheme.primary,
                      ),
                    ),
                  IconButton(
                    tooltip: '上传手机文件',
                    visualDensity: VisualDensity.compact,
                    onPressed: () => _import(context),
                    icon: Icon(
                      Icons.file_upload_outlined,
                      size: 20,
                      color: scheme.primary,
                    ),
                  ),
                  IconButton(
                    tooltip: '新建文件',
                    visualDensity: VisualDensity.compact,
                    onPressed: () => _create(context, directory: false),
                    icon: const Icon(Icons.note_add_outlined, size: 20),
                  ),
                  IconButton(
                    tooltip: '新建目录',
                    visualDensity: VisualDensity.compact,
                    onPressed: () => _create(context, directory: true),
                    icon:
                        const Icon(Icons.create_new_folder_outlined, size: 20),
                  ),
                  IconButton(
                    tooltip: '刷新',
                    visualDensity: VisualDensity.compact,
                    onPressed: notifier.refresh,
                    icon: const Icon(Icons.refresh, size: 20),
                  ),
                ],
              ),
            ),
            SizedBox(
              height: 34,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 6),
                children: [
                  for (var i = 0; i < state.roots.length; i++)
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: ChoiceChip(
                        visualDensity: VisualDensity.compact,
                        label: Text(
                          // APP 根用人话标签，guest 根直接显示挂载点路径。
                          i < state.rootLabels.length
                              ? state.rootLabels[i]
                              : state.roots[i],
                          style: const TextStyle(fontSize: 11.5),
                        ),
                        selected: state.path == state.roots[i] ||
                            state.path.startsWith('${state.roots[i]}/'),
                        onSelected: (_) => notifier.open(state.roots[i]),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 从别的 APP 挑文件传进当前目录。
  Future<void> _import(BuildContext context) async {
    final target = state.path;
    final result = await notifier.importFiles();
    if (!context.mounted || result == null || result.canceled) return;
    final ok = result.files.length;
    final bad = result.failed.length;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          bad == 0
              ? '已上传 $ok 个文件到 $target'
              : '已上传 $ok 个，$bad 个失败：${result.failed.first.error}',
        ),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  Future<void> _create(BuildContext context, {required bool directory}) async {
    final name = await showTextInputDialog(
      context,
      title: directory ? '新建目录' : '新建文件',
      labelText: '名称',
      hintText: directory ? 'my-folder' : 'script.py',
      confirmText: '创建',
    );
    if (name == null || name.isEmpty) return;
    if (directory) {
      await notifier.createDirectory(name);
    } else {
      await notifier.createFile(name);
    }
  }
}

class _FileTile extends StatelessWidget {
  const _FileTile({
    required this.entry,
    required this.selected,
    required this.selecting,
    required this.showPath,
    required this.onTap,
    required this.onLongPress,
    required this.onAction,
  });

  final ShellFileEntry entry;
  final bool selected;
  final bool selecting;

  /// 搜索结果里需要显示完整路径，否则同名文件分不清。
  final bool showPath;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final ValueChanged<String> onAction;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final kind = FileKinds.of(entry.name, isDirectory: entry.isDirectory);
    // 目录不显示大小（递归统计太贵，要看就点属性）；文件显示人类可读的大小。
    final sizeText = entry.isDirectory ? null : FileKinds.sizeText(entry.size);
    return GlassCard(
      selected: selected,
      onTap: onTap,
      onLongPress: onLongPress,
      padding: const EdgeInsets.fromLTRB(10, 9, 4, 9),
      child: Row(
        children: [
          if (selecting)
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: Icon(
                selected ? Icons.check_circle : Icons.circle_outlined,
                size: 20,
                color: selected ? scheme.primary : scheme.onSurfaceVariant,
              ),
            ),
          // 类型图标：按扩展名给形状 + 品牌色，扫一眼就知道是什么文件。
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: kind.color.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(kind.icon, color: kind.color, size: 21),
          ),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  entry.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                    // 隐藏文件压暗一档，和普通文件区分开。
                    color: entry.hidden
                        ? scheme.onSurface.withValues(alpha: 0.55)
                        : null,
                  ),
                ),
                const SizedBox(height: 3),
                // 第二行：日期/大小/权限。半屏侧滑面板窄，改横向滚动防黄条。
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      Text(
                        Formatter.dateTime(entry.modified),
                        style: TextStyle(
                          fontSize: 11,
                          fontFamily: kMonoFamily,
                          fontFamilyFallback: kMonoFallback,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(width: 8),
                      if (sizeText != null)
                        Text(
                          sizeText,
                          style: TextStyle(
                            fontSize: 11,
                            fontFamily: kMonoFamily,
                            fontFamilyFallback: kMonoFallback,
                            fontWeight: FontWeight.w600,
                            color: scheme.onSurfaceVariant,
                          ),
                        )
                      else
                        Text(
                          '文件夹',
                          style: TextStyle(
                            fontSize: 11,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      const SizedBox(width: 8),
                      Text(
                        entry.modeText,
                        style: TextStyle(
                          fontSize: 10.5,
                          fontFamily: kMonoFamily,
                          fontFamilyFallback: kMonoFallback,
                          color:
                              scheme.onSurfaceVariant.withValues(alpha: 0.75),
                        ),
                      ),
                      if (entry.matchedContent)
                        Padding(
                          padding: const EdgeInsets.only(left: 6),
                          child: Text(
                            '内容命中',
                            style: TextStyle(
                              fontSize: 10.5,
                              fontWeight: FontWeight.w600,
                              color: scheme.primary,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                if (showPath)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      entry.path,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 10.5,
                        fontFamily: kMonoFamily,
                        fontFamilyFallback: kMonoFallback,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          // 三点菜单保留：习惯点菜单的人不用非得学长按。
          IconButton(
            visualDensity: VisualDensity.compact,
            tooltip: '更多',
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
            onPressed: onLongPress,
            icon: Icon(
              Icons.more_vert,
              size: 19,
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}
