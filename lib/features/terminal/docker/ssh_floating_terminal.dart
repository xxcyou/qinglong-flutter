import 'package:flutter/material.dart';

import '../widgets/ssh_terminal_view.dart';
import 'ssh_floating_host.dart';

/// 悬浮窗容器终端：复用完整 SSH 终端组件，只是打开后自动 exec 进容器。
class SshFloatingTerminal {
  static int? _id;

  static bool get isOpen => _id != null;

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
      title: title ?? '容器终端',
      icon: Icons.terminal,
      builder: (_) => SshFloatingTerminalWindow(
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

  static void close() {
    final id = _id;
    _id = null;
    if (id != null) SshFloatingHost.close(id);
  }
}

class SshFloatingTerminalWindow extends StatefulWidget {
  const SshFloatingTerminalWindow({
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
  State<SshFloatingTerminalWindow> createState() =>
      _SshFloatingTerminalWindowState();
}

class _SshFloatingTerminalWindowState extends State<SshFloatingTerminalWindow> {
  Offset _pos = const Offset(24, 90);
  Size _size = const Size(380, 280);

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final width = (_size.width).clamp(240.0, media.size.width - 16);
    final height = (_size.height).clamp(180.0, media.size.height - 120);
    final left = _pos.dx.clamp(0.0, media.size.width - width - 8);
    final top = _pos.dy.clamp(MediaQuery.paddingOf(context).top,
        media.size.height - height - 8);
    final shell = "docker exec -it '${widget.containerId.replaceAll("'", "'\\''")}' /bin/sh -l";
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
                  color: const Color(0xF0282C34),
                  child: SafeArea(
                    top: false,
                    bottom: false,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(0, 20, 0, 0),
                      child: SshTerminalView(
                        sessionId: widget.sessionId,
                        initialCommand: shell,
                        title: widget.title ?? '容器 ${widget.containerId.substring(0, widget.containerId.length > 12 ? 12 : widget.containerId.length)}',
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            top: 0,
            height: 20,
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTapDown: (_) => widget.onFocus(),
              onPanUpdate: (d) => setState(() => _pos += d.delta),
              child: Container(
                color: const Color(0x00282C34),
                padding: const EdgeInsets.only(left: 8),
                alignment: Alignment.centerLeft,
                child: Text(
                  '容器终端',
                  style: const TextStyle(
                    fontSize: 11,
                    color: Colors.white70,
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
              tooltip: '最小化容器终端',
              visualDensity: VisualDensity.compact,
              constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
              iconSize: 14,
              padding: EdgeInsets.zero,
              icon: const Icon(Icons.minimize, color: Colors.white70),
              onPressed: widget.onMinimize,
            ),
          ),
          Positioned(
            right: 2,
            top: 0,
            child: IconButton(
              tooltip: '关闭容器终端',
              visualDensity: VisualDensity.compact,
              constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
              iconSize: 14,
              padding: EdgeInsets.zero,
              icon: const Icon(Icons.close_rounded, color: Colors.white70),
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
              onPanUpdate: (d) {
                setState(() {
                  _size = Size(
                    (_size.width + d.delta.dx).clamp(240.0, 800.0),
                    (_size.height + d.delta.dy).clamp(180.0, 700.0),
                  );
                });
              },
              child: const Icon(
                Icons.open_in_full_rounded,
                size: 13,
                color: Colors.white54,
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
