import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/material.dart';

import '../../floating/float_bounds_registry.dart';

import '../providers/ssh_session_provider.dart';
import 'ssh_floating_host.dart';
import '../../../shared/mono_text.dart';

/// 悬浮窗容器日志：通过 SSH 执行 docker logs -f，实时滚动显示。
class SshFloatingLogs {
  static final Set<int> _ids = {};

  static void show(
    BuildContext context, {
    required String sessionId,
    required String containerId,
    String? title,
  }) {
    late final int id;
    final initialOffset = SshFloatingHost.nextCascadeOffset();
    id = SshFloatingHost.add(
      context,
      group: containerId,
      title: title ?? '容器日志',
      icon: Icons.receipt_long,
      builder: (_) => SshFloatingLogsWindow(
        sessionId: sessionId,
        containerId: containerId,
        title: title,
        onFocus: () => SshFloatingHost.focus(id),
        onMinimize: () => SshFloatingHost.minimize(id),
        onClose: () {
          SshFloatingHost.close(id);
          _ids.remove(id);
        },
        boundsId: 'ssh-float-$id',
        initialOffset: initialOffset,
      ),
    );
    _ids.add(id);
  }
}

class SshFloatingLogsWindow extends StatefulWidget {
  const SshFloatingLogsWindow({
    super.key,
    required this.sessionId,
    required this.containerId,
    required this.title,
    required this.onFocus,
    required this.onMinimize,
    required this.onClose,
    required this.boundsId,
    this.initialOffset,
  });

  final Object boundsId;
  final String sessionId;
  final String containerId;
  final String? title;
  final VoidCallback onFocus;
  final VoidCallback onMinimize;
  final VoidCallback onClose;
  final Offset? initialOffset;

  @override
  State<SshFloatingLogsWindow> createState() => _SshFloatingLogsWindowState();
}

class _SshFloatingLogsWindowState extends State<SshFloatingLogsWindow> {
  @override
  void dispose() {
    FloatBoundsRegistry.remove(widget.boundsId);
    super.dispose();
  }

  late Offset _pos;
  Size _size = const Size(380, 260);

  @override
  void initState() {
    super.initState();
    _pos = widget.initialOffset ?? const Offset(40, 120);
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final width = (_size.width).clamp(240.0, media.size.width - 16);
    final height = (_size.height).clamp(180.0, media.size.height - 120);
    final left = _pos.dx.clamp(0.0, media.size.width - width - 8);
    final top = _pos.dy.clamp(
        MediaQuery.paddingOf(context).top, media.size.height - height - 8);
    FloatBoundsRegistry.report(
        widget.boundsId, Rect.fromLTWH(left, top, width, height));
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
                      color: const Color(0xF0182028),
                      child: SshContainerLogView(
                        sessionId: widget.sessionId,
                        containerId: widget.containerId,
                        title: widget.title,
                      ),
                    ),
                  ),
                ),
              ),
              Positioned(
                left: 0,
                right: 36,
                top: 0,
                height: 20,
                child: GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onTapDown: (_) => widget.onFocus(),
                  onPanUpdate: (d) => setState(() => _pos += d.delta),
                  child: Container(
                    color: const Color(0x00182028),
                    padding: const EdgeInsets.only(left: 8),
                    alignment: Alignment.centerLeft,
                    child: Text(
                      '${widget.title ?? '容器日志'} · 实时',
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
                  tooltip: '最小化容器日志',
                  visualDensity: VisualDensity.compact,
                  constraints:
                      const BoxConstraints(minWidth: 30, minHeight: 30),
                  iconSize: 14,
                  padding: EdgeInsets.zero,
                  icon: const Icon(Icons.picture_in_picture_alt,
                      color: Colors.white70),
                  onPressed: widget.onMinimize,
                ),
              ),
              Positioned(
                right: 2,
                top: 0,
                child: IconButton(
                  tooltip: '关闭容器日志',
                  visualDensity: VisualDensity.compact,
                  constraints:
                      const BoxConstraints(minWidth: 30, minHeight: 30),
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

class SshContainerLogView extends StatefulWidget {
  const SshContainerLogView({
    super.key,
    required this.sessionId,
    required this.containerId,
    this.title,
  });

  final String sessionId;
  final String containerId;
  final String? title;

  @override
  State<SshContainerLogView> createState() => _SshContainerLogViewState();
}

class _SshContainerLogViewState extends State<SshContainerLogView> {
  final List<String> _lines = [];
  final ScrollController _scroll = ScrollController();
  SSHSession? _session;
  StreamSubscription<Uint8List>? _stdoutSub;
  StreamSubscription<Uint8List>? _stderrSub;
  bool _started = false;
  String? _error;
  bool _autoScroll = true;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void dispose() {
    _stdoutSub?.cancel();
    _stderrSub?.cancel();
    _session?.close();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    final client = SshSessionManager.instance.clientOf(widget.sessionId);
    if (client == null) {
      setState(() => _error = 'SSH 未连接');
      return;
    }
    try {
      final cid = widget.containerId;
      final session = await client.execute(
        'docker logs --tail 500 -f $cid 2>&1',
      );
      _session = session;
      _stdoutSub = session.stdout.listen((data) {
        _append(utf8.decode(data, allowMalformed: true));
      });
      _stderrSub = session.stderr.listen((data) {
        _append(utf8.decode(data, allowMalformed: true));
      });
      session.done.then((_) {
        if (mounted && _session == session) {
          _session = null;
        }
      });
      if (mounted) {
        setState(() {
          _started = true;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _started = true;
          _error = '$e';
        });
      }
    }
  }

  void _append(String text) {
    if (text.isEmpty) return;
    final parts = text.split('\n');
    _lines.addAll(parts);
    if (_lines.length > 3000) {
      _lines.removeRange(0, _lines.length - 3000);
    }
    if (!mounted) return;
    setState(() {});
    if (_autoScroll && _scroll.hasClients) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) {
          _scroll.jumpTo(_scroll.position.maxScrollExtent);
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_started) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            SizedBox(height: 8),
            Text(
              '连接容器日志…',
              style: TextStyle(fontSize: 11, color: Colors.white70),
            ),
          ],
        ),
      );
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Text(
            _error!,
            style: const TextStyle(fontSize: 11, color: Colors.redAccent),
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    return Column(
      children: [
        Expanded(
          child: NotificationListener<ScrollNotification>(
            onNotification: (n) {
              if (n.metrics.extentAfter < 80) _autoScroll = true;
              if (n.metrics.extentAfter > 200) _autoScroll = false;
              return false;
            },
            child: _lines.isEmpty
                ? const Center(
                    child: Text(
                      '暂无日志输出',
                      style: TextStyle(fontSize: 12, color: Colors.white54),
                    ),
                  )
                : ListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.fromLTRB(10, 24, 10, 8),
                    itemCount: _lines.length,
                    itemBuilder: (context, i) => Text(
                      _lines[i],
                      style: const TextStyle(
                        fontSize: 11,
                        height: 1.3,
                        color: Colors.white70,
                        fontFamily: kMonoFamily,
                        fontFamilyFallback: kMonoFallback,
                      ),
                    ),
                  ),
          ),
        ),
        Align(
          alignment: Alignment.centerRight,
          child: IconButton(
            tooltip: '重新连接日志',
            visualDensity: VisualDensity.compact,
            constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
            iconSize: 14,
            icon: const Icon(Icons.refresh, color: Colors.white54),
            onPressed: _start,
          ),
        ),
      ],
    );
  }
}
