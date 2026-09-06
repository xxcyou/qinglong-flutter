import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:xterm/xterm.dart';

import '../../../core/theme/glass.dart';

/// 终端选择/复制工具条。
///
/// xterm 的 `TerminalController` 只负责"记住选了哪一段"，长按能选词、拖动能
/// 扩选，但**没有任何复制入口**——选完了没处可用，等于白选。这条工具条补上
/// 复制、全选、清空，另外带一个关键字高亮框（终端里刷了几千行日志，靠眼睛找
/// 那个 error 太痛苦）。
class TerminalSelectionBar extends StatefulWidget {
  const TerminalSelectionBar({
    super.key,
    required this.terminal,
    required this.controller,
    required this.onHighlightChanged,
    this.highlight = '',
  });

  final Terminal terminal;
  final TerminalController controller;

  /// 高亮关键字变化时通知外部（终端页负责重建高亮）。
  final ValueChanged<String> onHighlightChanged;
  final String highlight;

  @override
  State<TerminalSelectionBar> createState() => _TerminalSelectionBarState();
}

class _TerminalSelectionBarState extends State<TerminalSelectionBar> {
  late final TextEditingController _search =
      TextEditingController(text: widget.highlight);
  bool _searchOpen = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onControllerChanged);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerChanged);
    _search.dispose();
    super.dispose();
  }

  void _onControllerChanged() {
    if (mounted) setState(() {});
  }

  String get _selectedText {
    final range = widget.controller.selection;
    if (range == null) return '';
    return widget.terminal.buffer.getText(range);
  }

  Future<void> _copy(String text, String toast) async {
    if (text.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: text));
    HapticFeedback.selectionClick();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(toast), duration: const Duration(seconds: 1)),
    );
  }

  /// 整屏 + 回滚缓冲全部文本。
  ///
  /// 尾部往往是几十行空行（终端高度撑出来的），去掉它们，粘出去干净些。
  String _allText() {
    final buffer = widget.terminal.buffer;
    final text = buffer.getText(
      BufferRangeLine(
        const CellOffset(0, 0),
        CellOffset(buffer.viewWidth - 1, buffer.height - 1),
      ),
    );
    return text.trimRight();
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text ?? '';
    if (text.isEmpty) return;
    widget.terminal.paste(text);
    HapticFeedback.selectionClick();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final selected = _selectedText;
    final hasSelection = selected.trim().isNotEmpty;
    return GlassPanel(
      radius: 14,
      blur: 16,
      margin: const EdgeInsets.fromLTRB(6, 0, 6, 4),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              if (hasSelection) ...[
                Expanded(
                  child: Text(
                    '已选 ${selected.length} 字符',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                      color: scheme.primary,
                    ),
                  ),
                ),
                _action(
                    '复制', Icons.copy_rounded, () => _copy(selected, '已复制选中内容')),
                _action('取消', Icons.close, widget.controller.clearSelection),
              ] else ...[
                Expanded(
                  child: Text(
                    '长按终端选词，拖动扩选',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11.5,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
                _action('复制全屏', Icons.select_all,
                    () => _copy(_allText(), '整屏内容已复制')),
                _action('粘贴', Icons.content_paste_go, _paste),
              ],
              _action(
                _searchOpen ? '收起高亮' : '高亮',
                Icons.highlight_alt,
                () => setState(() => _searchOpen = !_searchOpen),
                active: _searchOpen || widget.highlight.isNotEmpty,
              ),
            ],
          ),
          if (_searchOpen)
            SizedBox(
              height: 34,
              child: TextField(
                controller: _search,
                style: const TextStyle(fontSize: 12.5, fontFamily: 'monospace'),
                decoration: InputDecoration(
                  isDense: true,
                  filled: false,
                  border: InputBorder.none,
                  hintText: '输入关键字，终端里匹配处高亮（如 error）',
                  prefixIcon: Icon(
                    Icons.search,
                    size: 16,
                    color: scheme.onSurfaceVariant,
                  ),
                  suffixIcon: _search.text.isEmpty
                      ? null
                      : IconButton(
                          onPressed: () {
                            _search.clear();
                            widget.onHighlightChanged('');
                            setState(() {});
                          },
                          icon: const Icon(Icons.clear, size: 15),
                        ),
                ),
                onChanged: (value) {
                  widget.onHighlightChanged(value);
                  setState(() {});
                },
              ),
            ),
        ],
      ),
    );
  }

  Widget _action(
    String label,
    IconData icon,
    VoidCallback onTap, {
    bool active = false,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(left: 4),
      child: InkWell(
        borderRadius: BorderRadius.circular(9),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
          decoration: BoxDecoration(
            color: active
                ? scheme.primary.withValues(alpha: 0.16)
                : scheme.surfaceContainerHighest.withValues(alpha: 0.45),
            borderRadius: BorderRadius.circular(9),
          ),
          child: Row(
            children: [
              Icon(
                icon,
                size: 14,
                color: active ? scheme.primary : scheme.onSurfaceVariant,
              ),
              const SizedBox(width: 3),
              Text(
                label,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: active ? scheme.primary : scheme.onSurface,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
