import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ssh2/ssh2.dart';
import 'package:xterm/xterm.dart';

import '../../../shared/mono_text.dart';
import '../../../core/theme/glass.dart';
import '../../settings/providers/settings_provider.dart';
import '../providers/ssh_session_provider.dart';
import '../terminal_palettes.dart';

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
  String? _error;

  SSHClient? get _client =>
      SshSessionManager.instance.clientOf(widget.sessionId);

  @override
  void initState() {
    super.initState();
    _terminal.onOutput = (data) {
      final client = _client;
      if (client != null) client.writeToShell(data);
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
      final result = await client.startShell(
        ptyType: 'xterm',
        callback: (res) {
          if (!mounted) return;
          if (res is String) {
            _terminal.write(res);
          }
        },
      );
      if (result != null && result != 'connected' && mounted) {
        setState(() => _error = result);
      }
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  @override
  void dispose() {
    final client = _client;
    if (client != null) {
      try {
        client.closeShell();
      } catch (_) {}
    }
    _focusNode.dispose();
    super.dispose();
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
      ],
    );
  }
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
