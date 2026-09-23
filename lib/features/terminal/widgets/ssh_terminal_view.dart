import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:xterm/xterm.dart';

import '../../../shared/mono_text.dart';
import '../../../core/theme/glass.dart';
import '../../settings/providers/settings_provider.dart';
import '../providers/ssh_session_provider.dart';
import '../terminal_palettes.dart';
import 'terminal_key_bar.dart';
import 'terminal_selection_bar.dart';

/// 一个已经连接的 SSH 会话终端页。
class SshTerminalView extends ConsumerStatefulWidget {
  const SshTerminalView({super.key, required this.sessionId});

  final String sessionId;

  @override
  ConsumerState<SshTerminalView> createState() => _SshTerminalViewState();
}

class _SshTerminalViewState extends ConsumerState<SshTerminalView> {
  final Terminal _terminal = Terminal(maxLines: 2000);
  final TerminalController _controller = TerminalController();
  final FocusNode _focusNode = FocusNode();
  SSHSession? _session;
  StreamSubscription<Uint8List>? _stdoutSub;
  StreamSubscription<Uint8List>? _stderrSub;
  String? _error;
  String _highlight = '';

  SSHClient? get _client =>
      SshSessionManager.instance.clientOf(widget.sessionId);

  @override
  void initState() {
    super.initState();
    _terminal.onOutput = (data) {
      final session = _session;
      if (session != null) {
        session.write(Uint8List.fromList(utf8.encode(data)));
      }
    };
    _terminal.onResize = (w, h, pw, ph) {
      _session?.resizeTerminal(w, h, pw, ph);
    };
    _startShell();
  }

  Future<void> _startShell() async {
    final client = _client;
    if (client == null) {
      setState(() => _error = 'SSH 会话不存在或已断开');
      return;
    }
    try {
      final session = await client.shell(
        pty: const SSHPtyConfig(type: 'xterm'),
      );
      _session = session;
      _stdoutSub = session.stdout.listen((data) {
        if (mounted) _terminal.write(utf8.decode(data, allowMalformed: true));
      });
      _stderrSub = session.stderr.listen((data) {
        if (mounted) _terminal.write(utf8.decode(data, allowMalformed: true));
      });
      session.done.then((_) {
        if (mounted && _session == session) {
          _session = null;
        }
      });
      if (mounted) setState(() => _error = null);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  @override
  void dispose() {
    _stdoutSub?.cancel();
    _stderrSub?.cancel();
    _session?.close();
    _focusNode.dispose();
    super.dispose();
  }

  void _send(String data) {
    _session?.write(Uint8List.fromList(utf8.encode(data)));
  }

  void _toggleKeyboard() {
    if (_focusNode.hasFocus) {
      _focusNode.unfocus();
    } else {
      _focusNode.requestFocus();
    }
  }

  void _setHighlight(String v) {
    if (mounted) setState(() => _highlight = v);
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    final palette = TerminalPalette.byId(settings.terminalPalette);
    final session = SshSessionManager.instance.sessions
        .where((s) => s.id == widget.sessionId)
        .firstOrNull;
    final scheme = Theme.of(context).colorScheme;

    return Column(
      children: [
        if (session != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
            child: Row(
              children: [
                Icon(Icons.dns_outlined, size: 14, color: scheme.primary),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '${session.name} · ${session.username}@${session.host}:${session.port}',
                    style: const TextStyle(fontSize: 12),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (_error != null)
                  IconButton(
                    tooltip: _error,
                    onPressed: _startShell,
                    icon: Icon(Icons.refresh, size: 18, color: scheme.error),
                  ),
              ],
            ),
          ),
        const SizedBox(height: 4),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Text(
              _error!,
              style: TextStyle(color: scheme.error),
            ),
          ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
            child: GlassPanel(
              margin: const EdgeInsets.only(bottom: 6),
              radius: 20,
              blur: 12,
              padding: EdgeInsets.zero,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(20),
                child: TerminalView(
                  _terminal,
                  controller: _controller,
                  focusNode: _focusNode,
                  autofocus: true,
                  keyboardType: TextInputType.multiline,
                  backgroundOpacity: 0.86,
                  theme: palette.theme,
                  textStyle: TerminalStyle(
                    fontSize: settings.terminalFontSize,
                    height: settings.terminalLineHeight,
                    fontFamily: kMonoFamily,
                    fontFamilyFallback: kMonoFallback,
                  ),
                  padding: const EdgeInsets.fromLTRB(10, 8, 6, 8),
                  cursorType: TerminalCursorType.block,
                ),
              ),
            ),
          ),
        ),
        // SSH 终端也一样需要选择/复制条和快捷键条，手机软键盘没 Ctrl/方向键。
        if (_session != null) ...[
          TerminalSelectionBar(
            terminal: _terminal,
            controller: _controller,
            highlight: _highlight,
            onHighlightChanged: _setHighlight,
          ),
          TerminalKeyBar(
            onSend: _send,
            onToggleKeyboard: _toggleKeyboard,
            highlightCommands: settings.terminalCommandHighlight,
            fontSize: settings.terminalFontSize,
          ),
          SizedBox(height: MediaQuery.paddingOf(context).bottom * 0.2),
        ] else
          SizedBox(
            height: 12 + MediaQuery.paddingOf(context).bottom * 0.2,
          ),
      ],
    );
  }
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
