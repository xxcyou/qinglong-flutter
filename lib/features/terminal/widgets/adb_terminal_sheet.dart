import 'package:flutter/material.dart';

import '../../../shared/mono_text.dart';
import '../providers/adb_session_provider.dart';

/// ADB 命令终端。
///
/// ADB 没有像 SSH 那样现成的持久 PTY 通道，这里用单条命令执行 + 输出回显
/// 的方式做一个轻量终端：`ls`、`pm`、`am`、`getprop`、`dumpsys` 等一次性
/// 命令都够用，也避免交互式程序把 60 秒超时占满。
class AdbTerminalSheet extends StatefulWidget {
  const AdbTerminalSheet({
    super.key,
    required this.sessionId,
    required this.title,
  });

  final String sessionId;
  final String title;

  static Future<void> show(
    BuildContext context, {
    required String sessionId,
    required String title,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => ClipRRect(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        child: Material(
          color: Theme.of(context).colorScheme.surface.withValues(alpha: 0.97),
          child: SafeArea(
            child: SizedBox(
              height: MediaQuery.sizeOf(context).height * 0.9,
              child: AdbTerminalSheet(
                sessionId: sessionId,
                title: title,
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  State<AdbTerminalSheet> createState() => _AdbTerminalSheetState();
}

class _AdbTerminalSheetState extends State<AdbTerminalSheet> {
  final _input = TextEditingController();
  final _focus = FocusNode();
  final _scroll = ScrollController();
  final _lines = <_AdbTerminalLine>[];
  final _history = <String>[];
  int _historyIndex = -1;
  bool _running = false;

  static const _quickCommands = <String>[
    'id',
    'getprop ro.product.model',
    'ls -la /storage/emulated/0',
    'pm list packages | head -50',
    'dumpsys battery | head -30',
    'ip addr show wlan0',
  ];

  @override
  void initState() {
    super.initState();
    _lines.add(const _AdbTerminalLine.output(
      'ADB 终端已就绪。\n'
      '输入一句 shell 命令，按 Enter 或右边发送键执行。\n'
      '长按输出可复制。',
    ));
  }

  @override
  void dispose() {
    _input.dispose();
    _focus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.animateTo(
        _scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
      );
    });
  }

  Future<void> _run(String raw) async {
    final cmd = raw.trim();
    if (cmd.isEmpty || _running) return;
    if (cmd == 'clear') {
      setState(() => _lines.clear());
      return;
    }

    _input.clear();
    _history.remove(cmd);
    _history.add(cmd);
    _historyIndex = _history.length;
    setState(() {
      _lines.add(_AdbTerminalLine.command(cmd));
      _running = true;
    });
    _scrollToBottom();

    try {
      final out = await AdbSessionManager.instance.execute(widget.sessionId, cmd);
      final text = out.trimRight();
      setState(() {
        _lines.add(_AdbTerminalLine.output(
          text.isEmpty ? '(命令没有输出)' : text,
        ));
      });
    } catch (e) {
      setState(() {
        _lines.add(_AdbTerminalLine.error('执行失败：$e'));
      });
    } finally {
      if (mounted) setState(() => _running = false);
      _scrollToBottom();
    }
  }

  void _recallHistory(bool older) {
    if (_history.isEmpty) return;
    final next = older
        ? (_historyIndex <= 0 ? 0 : _historyIndex - 1)
        : (_historyIndex >= _history.length - 1
            ? _history.length - 1
            : _historyIndex + 1);
    _historyIndex = next;
    _input.text = _history[next];
    _input.selection = TextSelection.collapsed(offset: _input.text.length);
    _focus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final session = AdbSessionManager.instance.sessions
        .where((s) => s.id == widget.sessionId)
        .firstOrNull;
    final connected = session?.isConnected == true;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 14, 8, 8),
          child: Row(
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: scheme.primaryContainer,
                  borderRadius: BorderRadius.circular(13),
                ),
                child: Icon(Icons.terminal, color: scheme.primary),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'ADB 终端 · ${widget.title}',
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      connected
                          ? 'adb shell · 命令逐条执行'
                          : '设备未连接，请先回 ADB 设备管理连接',
                      style: TextStyle(
                        fontSize: 11.5,
                        color: connected ? scheme.onSurfaceVariant : scheme.error,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: '清屏',
                onPressed: () => setState(() => _lines.clear()),
                icon: const Icon(Icons.cleaning_services_outlined, size: 20),
              ),
              IconButton(
                tooltip: '关闭',
                onPressed: () => Navigator.pop(context),
                icon: const Icon(Icons.close),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        SizedBox(
          height: 38,
          child: ListView.separated(
            padding: const EdgeInsets.fromLTRB(12, 6, 12, 2),
            scrollDirection: Axis.horizontal,
            itemCount: _quickCommands.length,
            separatorBuilder: (_, __) => const SizedBox(width: 6),
            itemBuilder: (context, i) {
              final cmd = _quickCommands[i];
              return ActionChip(
                label: Text(
                  cmd,
                  style: const TextStyle(fontSize: 11),
                  overflow: TextOverflow.ellipsis,
                ),
                onPressed: _running ? null : () => _run(cmd),
                visualDensity: VisualDensity.compact,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              );
            },
          ),
        ),
        Expanded(
          child: Container(
            margin: const EdgeInsets.fromLTRB(10, 8, 10, 6),
            decoration: BoxDecoration(
              color: const Color(0xFF0E1116),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: const Color(0xFF26303D)),
            ),
            child: ListView.builder(
              controller: _scroll,
              padding: const EdgeInsets.all(12),
              itemCount: _lines.length,
              itemBuilder: (context, i) => _AdbLineView(line: _lines[i]),
            ),
          ),
        ),
        Padding(
          padding: EdgeInsets.fromLTRB(
            10,
            0,
            10,
            8 + MediaQuery.viewInsetsOf(context).bottom * 0.15,
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              IconButton(
                tooltip: '上一条命令',
                onPressed: _running ? null : () => _recallHistory(true),
                icon: const Icon(Icons.keyboard_arrow_up, size: 20),
              ),
              Expanded(
                child: TextField(
                  controller: _input,
                  focusNode: _focus,
                  autofocus: true,
                  enabled: !_running,
                  textInputAction: TextInputAction.send,
                  onSubmitted: _run,
                  minLines: 1,
                  maxLines: 3,
                  style: const TextStyle(
                    fontFamily: kMonoFamily,
                    fontSize: 13,
                  ),
                  decoration: InputDecoration(
                    hintText: '输入命令，如 pm list packages',
                    isDense: true,
                    prefixIcon: const Icon(Icons.chevron_right, size: 20),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    suffixIcon: _running
                        ? const Padding(
                            padding: EdgeInsets.all(12),
                            child: SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                          )
                        : IconButton(
                            tooltip: '执行',
                            onPressed: () => _run(_input.text),
                            icon: const Icon(Icons.send_rounded, size: 18),
                          ),
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

class _AdbTerminalLine {
  const _AdbTerminalLine.command(this.text) : kind = _AdbLineKind.command;
  const _AdbTerminalLine.output(this.text) : kind = _AdbLineKind.output;
  const _AdbTerminalLine.error(this.text) : kind = _AdbLineKind.error;

  final String text;
  final _AdbLineKind kind;
}

enum _AdbLineKind { command, output, error }

class _AdbLineView extends StatelessWidget {
  const _AdbLineView({required this.line});

  final _AdbTerminalLine line;

  @override
  Widget build(BuildContext context) {
    final text = switch (line.kind) {
      _AdbLineKind.command => '\$ ${line.text}',
      _AdbLineKind.output => line.text,
      _AdbLineKind.error => line.text,
    };
    final color = switch (line.kind) {
      _AdbLineKind.command => const Color(0xFF8AB4FF),
      _AdbLineKind.output => const Color(0xFFD7E0EA),
      _AdbLineKind.error => const Color(0xFFFF8A80),
    };
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: SelectableText(
        text,
        style: TextStyle(
          fontFamily: kMonoFamily,
          fontSize: 12.5,
          height: 1.35,
          color: color,
        ),
      ),
    );
  }
}
