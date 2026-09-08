import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/theme/glass.dart';
import '../features/browser/browser_engine.dart';
import 'ask_ai.dart';
import 'code_editor.dart';
import 'code_language.dart';
import 'editor_bus.dart';
import 'glass_scaffold.dart';
import 'highlighting_code_controller.dart';

/// 通用「代码级」查看器 / 编辑器页。
///
/// 把脚本编辑页里那套完整能力（撤销/重做、查找上下条、字号、换行、
/// 选区发 AI、双指缩放）抽出来复用，任何拿到文本的地方都能直接开一个
/// 同等水平的编辑器，而不是丢个裸 TextField。
class CodeEditorPage extends ConsumerStatefulWidget {
  const CodeEditorPage({
    super.key,
    required this.path,
    required this.initial,
    this.onSave,
    this.onDelete,
    this.readOnly = false,
    this.aiSource = 'file',
    this.subtitle,
    this.editorKind = EditorKind.shellFile,
  });

  final String path;
  final String initial;

  /// 返回 true 表示保存成功。为 null 则是纯查看器（不显示保存按钮）。
  final Future<bool> Function(String content)? onSave;

  /// 删除这个文件本身（AI 的 editor_remove 会用；UI 上不画按钮，
  /// 文件管理器自己有删除入口）。
  final Future<bool> Function()? onDelete;
  final bool readOnly;
  final String aiSource;
  final String? subtitle;

  /// 挂到编辑器总线上的身份。
  final EditorKind editorKind;

  @override
  ConsumerState<CodeEditorPage> createState() => _CodeEditorPageState();
}

class _CodeEditorPageState extends ConsumerState<CodeEditorPage> {
  final _editorKey = GlobalKey<CodeEditorFieldState>();
  final _searchController = TextEditingController();

  late final HighlightingCodeController _controller;
  bool _dirty = false;
  bool _saving = false;
  bool _searching = false;
  bool _wrap = false;
  int _matchCount = 0;

  /// 编辑器总线上的注册 id：AI 的 editor_* 工具靠它找到这个编辑框。
  int? _busId;

  String get _fileName => widget.path.split('/').last;

  @override
  void initState() {
    super.initState();
    _controller = HighlightingCodeController(
      language: languageForPath(widget.path),
      languageName: languageNameForPath(widget.path),
      text: widget.initial,
    );
    _busId = EditorBus.instance.register(
      kind: widget.editorKind,
      title: _fileName,
      path: widget.path,
      controller: _controller,
      editorKey: _editorKey,
      language: languageNameForPath(widget.path),
      readOnly: widget.readOnly || widget.onSave == null,
      save: widget.onSave == null
          ? null
          : () async {
              final ok = await widget.onSave!(_controller.text);
              if (mounted) setState(() => _dirty = !ok);
              return ok ? '已保存 ${widget.path}' : '保存失败（看编辑器上的报错）。';
            },
      remove: widget.onDelete == null
          ? null
          : () async {
              final ok = await widget.onDelete!();
              if (ok && mounted) Navigator.of(context).maybePop();
              return ok ? '已删除 ${widget.path}' : '删除失败。';
            },
    );
  }

  @override
  void dispose() {
    final id = _busId;
    if (id != null) EditorBus.instance.unregister(id);
    _controller.dispose();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final onSave = widget.onSave;
    if (onSave == null) return;
    setState(() => _saving = true);
    final ok = await onSave(_controller.text);
    if (!mounted) return;
    setState(() {
      _saving = false;
      if (ok) _dirty = false;
    });
    if (!ok) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已保存'), duration: Duration(seconds: 1)),
    );
  }

  void _toggleSearch() {
    setState(() => _searching = !_searching);
    if (!_searching) {
      _searchController.clear();
      _matchCount = 0;
    }
  }

  void _onSearchChanged(String value) {
    setState(() {
      _matchCount = _editorKey.currentState?.countMatches(value) ?? 0;
    });
    if (_matchCount > 0) _editorKey.currentState?.selectNextMatch(value);
  }

  void _goNext() =>
      _editorKey.currentState?.selectNextMatch(_searchController.text);

  void _goPrev() => _editorKey.currentState
      ?.selectNextMatch(_searchController.text, reverse: true);

  void _sendSelectionToAi() {
    final selected = _editorKey.currentState?.selectedText ?? '';
    final hasSelection = selected.trim().isNotEmpty;
    AskAi.pushWithToast(
      context,
      ref,
      label: hasSelection ? '$_fileName（选区）' : _fileName,
      content: hasSelection ? selected : _controller.text,
      source: widget.aiSource,
      language: languageNameForPath(widget.path),
      draft: hasSelection ? '帮我看看这段选中的代码' : '帮我看看这个文件在做什么，有问题直接指出来',
    );
  }

  bool get _isHtml {
    final name = widget.path.toLowerCase();
    return name.endsWith('.html') || name.endsWith('.htm');
  }

  Future<void> _openInBrowser() async {
    // 有未保存的修改就先落盘，再打开；不然浏览器里看到的是旧文件。
    if (_dirty && !widget.readOnly && widget.onSave != null) {
      final ok = await widget.onSave!(_controller.text);
      if (!ok) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('保存失败，未打开浏览器')),
          );
        }
        return;
      }
      if (mounted) setState(() => _dirty = false);
    }
    try {
      await BrowserEngine.instance.openLocal(widget.path);
      if (!mounted) return;
      BrowserEngine.instance.show();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('打开网页失败：$e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final canSave = widget.onSave != null && !widget.readOnly;
    return PopScope(
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final navigator = Navigator.of(context);
        final leave = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('放弃修改？'),
            content: const Text('当前修改尚未保存。'),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('继续编辑'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('放弃'),
              ),
            ],
          ),
        );
        if (leave == true) navigator.pop();
      },
      child: GlassScaffold(
        title: _fileName,
        subtitle: widget.subtitle ??
            '${languageNameForPath(widget.path)} · ${widget.path}',
        showBack: true,
        actions: [
          if (_isHtml)
            IconButton(
              tooltip: '在悬浮浏览器中打开',
              onPressed: _openInBrowser,
              icon: const Icon(Icons.play_circle_outline),
            ),
          IconButton(
            tooltip: '复制全文',
            onPressed: () {
              Clipboard.setData(ClipboardData(text: _controller.text));
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('已复制'),
                  duration: Duration(seconds: 1),
                ),
              );
            },
            icon: const Icon(Icons.copy_all_outlined),
          ),
          if (canSave)
            IconButton(
              tooltip: '保存',
              onPressed: _saving ? null : _save,
              icon: _saving
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Icon(_dirty ? Icons.save : Icons.save_outlined),
            ),
        ],
        headerBottom: _searching ? _buildSearchBar() : null,
        bottomBar: _buildToolbar(),
        body: Padding(
          padding: const EdgeInsets.fromLTRB(4, 0, 4, 96),
          child: GestureDetector(
            // 用户戳一下这个编辑器就把它设成 AI 的默认改动目标：
            // 同时开着几个编辑器时，"当前"必须跟着用户的手走。
            behavior: HitTestBehavior.translucent,
            onTapDown: (_) {
              final id = _busId;
              if (id != null) EditorBus.instance.touch(id);
            },
            child: CodeEditorField(
              key: _editorKey,
              controller: _controller,
              path: widget.path,
              wrap: _wrap,
              readOnly: widget.readOnly,
              onChanged: (_) {
                if (!_dirty) setState(() => _dirty = true);
              },
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSearchBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
      child: GlassPanel(
        radius: 16,
        blur: 12,
        shadowY: 2,
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
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
                  hintText: '查找关键字',
                  border: InputBorder.none,
                  isDense: true,
                ),
                onChanged: _onSearchChanged,
                onSubmitted: (_) => _goNext(),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: Text(
                '$_matchCount',
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            IconButton(
              tooltip: '上一个',
              visualDensity: VisualDensity.compact,
              onPressed: _matchCount == 0 ? null : _goPrev,
              icon: const Icon(Icons.keyboard_arrow_up, size: 20),
            ),
            IconButton(
              tooltip: '下一个',
              visualDensity: VisualDensity.compact,
              onPressed: _matchCount == 0 ? null : _goNext,
              icon: const Icon(Icons.keyboard_arrow_down, size: 20),
            ),
            IconButton(
              tooltip: '关闭查找',
              visualDensity: VisualDensity.compact,
              onPressed: _toggleSearch,
              icon: const Icon(Icons.close, size: 18),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildToolbar() {
    return GlassPanel(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            GlassPill(
              icon: Icons.undo,
              tooltip: '撤销',
              dense: true,
              onTap: () => _editorKey.currentState?.undo(),
            ),
            const SizedBox(width: 6),
            GlassPill(
              icon: Icons.redo,
              tooltip: '重做',
              dense: true,
              onTap: () => _editorKey.currentState?.redo(),
            ),
            const SizedBox(width: 6),
            GlassPill(
              icon: Icons.search,
              tooltip: '查找',
              dense: true,
              onTap: _toggleSearch,
            ),
            const SizedBox(width: 6),
            GlassPill(
              icon: Icons.text_decrease,
              tooltip: '字号-',
              dense: true,
              onTap: () => _editorKey.currentState?.decreaseFontSize(),
            ),
            const SizedBox(width: 6),
            GlassPill(
              icon: Icons.text_increase,
              tooltip: '字号+',
              dense: true,
              onTap: () => _editorKey.currentState?.increaseFontSize(),
            ),
            const SizedBox(width: 6),
            GlassPill(
              icon: Icons.wrap_text,
              label: _wrap ? '换行开' : '换行',
              tooltip: '换行开关',
              dense: true,
              onTap: () => setState(() => _wrap = !_wrap),
            ),
            const SizedBox(width: 6),
            GlassPill(
              icon: Icons.auto_awesome,
              tooltip: '发给 AI',
              dense: true,
              onTap: _sendSelectionToAi,
            ),
          ],
        ),
      ),
    );
  }
}
