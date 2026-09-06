import 'package:flutter/material.dart';

import '../../../core/theme/glass.dart';
import 'shell_highlighter.dart';
import '../../../shared/mono_text.dart';

/// 终端底部快捷键条 + 命令输入行。
///
/// 手机软键盘没有方向键、没有 Ctrl、没有 Tab，纯软键盘用 shell 等于半残。
/// 这一条把这些键补齐：方向键直接发 ESC 序列（bash readline 天然把 ↑↓
/// 解释成历史命令，所以"上下切换历史输入"用的就是它），Ctrl 组合走弹出菜单，
/// 另外自带一行命令输入框，输入框本身也维护一份本地历史，↑↓ 可回溯。
class TerminalKeyBar extends StatefulWidget {
  const TerminalKeyBar({
    super.key,
    required this.onSend,
    required this.onToggleKeyboard,
    this.onInstallPackage,
    this.highlightCommands = true,
    this.fontSize = 13,
  });

  /// 把原始字节序列写进 pty。
  final ValueChanged<String> onSend;

  /// 呼出/收起软键盘。
  final VoidCallback onToggleKeyboard;

  /// 打开装包面板。
  final VoidCallback? onInstallPackage;

  /// 命令输入框是否做 shell 语法高亮（设置里可关）。
  final bool highlightCommands;

  /// 输入框字号，跟终端字号一起调。
  final double fontSize;

  @override
  State<TerminalKeyBar> createState() => TerminalKeyBarState();
}

class TerminalKeyBarState extends State<TerminalKeyBar> {
  final _controller = ShellCommandController();
  final _focusNode = FocusNode();

  /// 本地命令历史（最新在后），供输入框的 ↑↓ 回溯。
  final List<String> _history = [];
  int _historyIndex = -1;
  bool _expanded = false;

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _send(String data) => widget.onSend(data);

  void _submit() {
    final text = _controller.text;
    if (text.isEmpty) {
      _send('\r');
      return;
    }
    _send('$text\r');
    _history.remove(text);
    _history.add(text);
    if (_history.length > 100) _history.removeAt(0);
    _historyIndex = -1;
    _controller.clear();
    // 连续敲命令时保持焦点，不用每次重新点输入框。
    _focusNode.requestFocus();
  }

  /// 输入框里的历史回溯：-1 表示"当前正在编辑的新命令"。
  void _stepHistory(int delta) {
    if (_history.isEmpty) return;
    var index = _historyIndex;
    if (index == -1) {
      index = delta < 0 ? _history.length - 1 : -1;
    } else {
      index += delta < 0 ? -1 : 1;
    }
    if (index < 0) index = 0;
    if (index >= _history.length) {
      // 越过最新一条就回到空白输入。
      setState(() {
        _historyIndex = -1;
        _controller.clear();
      });
      return;
    }
    setState(() {
      _historyIndex = index;
      _controller.text = _history[index];
      _controller.selection =
          TextSelection.collapsed(offset: _controller.text.length);
    });
  }

  @override
  Widget build(BuildContext context) {
    // 高亮配色跟着当前主题走，明暗切换时不用手动改。
    final dark = Theme.of(context).brightness == Brightness.dark;
    _controller
      ..enabled = widget.highlightCommands
      ..updateHighlighter(
        ShellHighlighter.fromScheme(Theme.of(context).colorScheme, dark: dark),
      );
    return GlassPanel(
      radius: 18,
      blur: Glass.blur,
      margin: const EdgeInsets.fromLTRB(6, 0, 6, 6),
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildInputRow(),
          const SizedBox(height: 6),
          _buildPrimaryKeys(),
          if (_expanded) ...[
            const SizedBox(height: 6),
            _buildExtraKeys(),
          ],
        ],
      ),
    );
  }

  Widget _buildInputRow() {
    return Row(
      children: [
        _Key(
          label: '↑',
          tooltip: '上一条历史（输入框）',
          onTap: () => _stepHistory(-1),
        ),
        _Key(
          label: '↓',
          tooltip: '下一条历史（输入框）',
          onTap: () => _stepHistory(1),
        ),
        const SizedBox(width: 4),
        Expanded(
          child: TextField(
            controller: _controller,
            focusNode: _focusNode,
            style: TextStyle(
              fontFamily: kMonoFamily,
              fontFamilyFallback: kMonoFallback,
              fontSize: widget.fontSize,
              height: 1.3,
            ),
            textInputAction: TextInputAction.send,
            // 玻璃背景下不能填充底色，否则 BackdropFilter 的模糊被盖住。
            decoration: const InputDecoration(
              isDense: true,
              filled: false,
              border: InputBorder.none,
              hintText: '输入命令后回车',
              contentPadding: EdgeInsets.symmetric(horizontal: 6, vertical: 8),
            ),
            onSubmitted: (_) => _submit(),
          ),
        ),
        IconButton(
          visualDensity: VisualDensity.compact,
          tooltip: '发送',
          onPressed: _submit,
          icon: const Icon(Icons.keyboard_return, size: 19),
        ),
      ],
    );
  }

  Widget _buildPrimaryKeys() {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          _Key(label: 'Esc', onTap: () => _send('\x1b')),
          _Key(label: 'Tab', onTap: () => _send('\t')),
          _CtrlKey(onSend: _send),
          _Key(
            label: 'Shift+Tab',
            onTap: () => _send('\x1b[Z'),
            wide: true,
          ),
          const _Divider(),
          // 方向键：bash readline 把 ↑↓ 解释成历史命令，←→ 是行内移动。
          _Key(label: '←', onTap: () => _send('\x1b[D')),
          _Key(
              label: '↑', onTap: () => _send('\x1b[A'), tooltip: 'Shell 历史上一条'),
          _Key(
              label: '↓', onTap: () => _send('\x1b[B'), tooltip: 'Shell 历史下一条'),
          _Key(label: '→', onTap: () => _send('\x1b[C')),
          const _Divider(),
          _Key(label: 'Ctrl+C', onTap: () => _send('\x03'), wide: true),
          IconButton(
            visualDensity: VisualDensity.compact,
            tooltip: '软键盘',
            onPressed: widget.onToggleKeyboard,
            icon: const Icon(Icons.keyboard_alt_outlined, size: 19),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            tooltip: _expanded ? '收起更多按键' : '更多按键',
            onPressed: () => setState(() => _expanded = !_expanded),
            icon: Icon(
              _expanded ? Icons.expand_more : Icons.expand_less,
              size: 20,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildExtraKeys() {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          _Key(label: 'Home', onTap: () => _send('\x1b[H'), wide: true),
          _Key(label: 'End', onTap: () => _send('\x1b[F'), wide: true),
          _Key(label: 'PgUp', onTap: () => _send('\x1b[5~'), wide: true),
          _Key(label: 'PgDn', onTap: () => _send('\x1b[6~'), wide: true),
          _Key(label: 'Del', onTap: () => _send('\x1b[3~'), wide: true),
          const _Divider(),
          for (final ch in const [
            '|',
            '/',
            '~',
            '-',
            '_',
            '\$',
            '*',
            '&',
            '>',
            '<',
            '"',
            "'"
          ])
            _Key(label: ch, onTap: () => _send(ch)),
          const _Divider(),
          if (widget.onInstallPackage != null)
            TextButton.icon(
              onPressed: widget.onInstallPackage,
              icon: const Icon(Icons.inventory_2_outlined, size: 17),
              label: const Text('装包'),
            ),
          TextButton.icon(
            onPressed: () => _send('clear\r'),
            icon: const Icon(Icons.cleaning_services_outlined, size: 17),
            label: const Text('清屏'),
          ),
        ],
      ),
    );
  }
}

/// Ctrl 组合：手机上没法"按住 Ctrl 再按字母"，所以列成菜单一次选定。
class _CtrlKey extends StatelessWidget {
  const _CtrlKey({required this.onSend});

  final ValueChanged<String> onSend;

  static const _combos = <String, String>{
    'Ctrl+C 中断': '\x03',
    'Ctrl+D 结束输入': '\x04',
    'Ctrl+Z 挂起': '\x1a',
    'Ctrl+L 清屏': '\x0c',
    'Ctrl+A 行首': '\x01',
    'Ctrl+E 行尾': '\x05',
    'Ctrl+K 删到行尾': '\x0b',
    'Ctrl+U 删到行首': '\x15',
    'Ctrl+W 删一个词': '\x17',
    'Ctrl+R 搜索历史': '\x12',
    'Ctrl+P 上一条': '\x10',
    'Ctrl+N 下一条': '\x0e',
  };

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      tooltip: 'Ctrl 组合键',
      onSelected: onSend,
      itemBuilder: (_) => [
        for (final entry in _combos.entries)
          PopupMenuItem(value: entry.value, child: Text(entry.key)),
      ],
      child: const _KeyFace(label: 'Ctrl', wide: true),
    );
  }
}

class _Key extends StatelessWidget {
  const _Key({
    required this.label,
    required this.onTap,
    this.tooltip,
    this.wide = false,
  });

  final String label;
  final VoidCallback onTap;
  final String? tooltip;
  final bool wide;

  @override
  Widget build(BuildContext context) {
    final face = InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: onTap,
      child: _KeyFace(label: label, wide: wide),
    );
    if (tooltip == null) return face;
    return Tooltip(message: tooltip!, child: face);
  }
}

class _KeyFace extends StatelessWidget {
  const _KeyFace({required this.label, this.wide = false});

  final String label;
  final bool wide;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 2),
      constraints: BoxConstraints(minWidth: wide ? 0 : 38),
      padding: EdgeInsets.symmetric(horizontal: wide ? 10 : 6, vertical: 7),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.55),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.5)),
      ),
      child: Text(
        label,
        textAlign: TextAlign.center,
        style: const TextStyle(
          fontSize: 12.5,
          fontWeight: FontWeight.w600,
          fontFamily: kMonoFamily,
          fontFamilyFallback: kMonoFallback,
        ),
      ),
    );
  }
}

class _Divider extends StatelessWidget {
  const _Divider();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 1,
      height: 22,
      margin: const EdgeInsets.symmetric(horizontal: 5),
      color:
          Theme.of(context).colorScheme.outlineVariant.withValues(alpha: 0.5),
    );
  }
}
