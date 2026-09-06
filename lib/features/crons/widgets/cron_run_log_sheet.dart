import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/glass.dart';
import '../../../core/utils/error_text.dart';
import '../../panels/providers/panel_list_provider.dart';
import '../../settings/providers/settings_provider.dart';
import '../api/cron_api.dart';
import '../../../shared/mono_text.dart';

/// 任务运行实时日志面板（半屏浮层）。
///
/// 定时任务的输出不走 WebSocket，而是由面板写进 `log_path` 对应的日志文件，
/// 所以这里用轮询 `/crons/:id/log` 增量拉取——该接口每次都按库里最新的
/// log_path 解析，因此新一轮运行会自动跟上，不需要客户端自己拼路径。
class CronRunLogSheet extends ConsumerStatefulWidget {
  const CronRunLogSheet({
    super.key,
    required this.cronId,
    required this.taskName,
  });

  final int cronId;
  final String taskName;

  /// 运行任务后弹出实时日志。
  static Future<void> show(
    BuildContext context, {
    required int cronId,
    required String taskName,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => CronRunLogSheet(cronId: cronId, taskName: taskName),
    );
  }

  @override
  ConsumerState<CronRunLogSheet> createState() => _CronRunLogSheetState();
}

class _CronRunLogSheetState extends ConsumerState<CronRunLogSheet> {
  final ScrollController _scroll = ScrollController();

  Timer? _timer;
  List<String> _lines = const [];
  bool _loading = true;
  bool _finished = false;

  /// 实时贴底：手动往上滑就暂停，滑回底部或点「回到最新」恢复。
  bool _follow = true;
  bool _expanded = false;

  /// 面板对「从未运行过」的任务返回字符串「任务未运行」。
  bool _neverRun = false;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _refresh();
    // 间隔跟设置里的日志刷新一致（默认 500ms），跑脚本时看着才像实时。
    final millis = ref.read(settingsProvider).logPollMillis;
    _timer = Timer.periodic(
      Duration(milliseconds: millis.clamp(200, 60000)),
      (_) {
        if (_finished) return;
        _refresh();
      },
    );
  }

  @override
  void dispose() {
    _timer?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    final panel = ref.read(currentPanelProvider);
    if (panel == null) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '未选择面板';
      });
      return;
    }
    try {
      final log = await CronApi.fetchLog(
        apiBaseUrl: panel.apiBaseUrl,
        id: widget.cronId,
      );
      if (!mounted) return;
      final lines = log.lines;
      setState(() {
        _lines = lines;
        _loading = false;
        _error = null;
        // 面板在日志尾部写「## 执行结束」，据此收掉轮询与进度指示。
        _finished = lines.any((l) => l.contains('## 执行结束'));
        _neverRun = lines.length == 1 && lines.first.trim() == '任务未运行';
      });
      _stickToBottom();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e;
      });
    }
  }

  void _stickToBottom() {
    if (!_follow) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_follow || !_scroll.hasClients) return;
      _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final screenH = MediaQuery.sizeOf(context).height;
    final height = _expanded ? screenH * 0.88 : screenH * 0.55;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
        child: SizedBox(
          height: height,
          child: GlassPanel(
            radius: 22,
            blur: 18,
            padding: const EdgeInsets.fromLTRB(12, 6, 12, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _buildHeader(scheme),
                const Divider(height: 1),
                Expanded(child: _buildBody(scheme)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(ColorScheme scheme) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => setState(() => _expanded = !_expanded),
      onVerticalDragEnd: (d) {
        final vy = d.velocity.pixelsPerSecond.dy;
        if (vy < -80 && !_expanded) {
          setState(() => _expanded = true);
        } else if (vy > 80 && _expanded) {
          setState(() => _expanded = false);
        }
      },
      child: Row(
        children: [
          Icon(Icons.terminal, size: 17, color: scheme.primary),
          const SizedBox(width: 6),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.taskName,
                  style: const TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w700,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                Row(
                  children: [
                    if (!_finished) ...[
                      const SizedBox(
                        width: 10,
                        height: 10,
                        child: CircularProgressIndicator(strokeWidth: 1.8),
                      ),
                      const SizedBox(width: 5),
                    ],
                    Text(
                      _finished ? '执行结束 · ${_lines.length} 行' : '运行中 · 每 2 秒刷新',
                      style: TextStyle(
                        fontSize: 11,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                    if (!_follow) ...[
                      const SizedBox(width: 6),
                      Text(
                        '已暂停滚动',
                        style: TextStyle(fontSize: 11, color: scheme.primary),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
          if (!_follow)
            IconButton(
              tooltip: '回到最新',
              visualDensity: VisualDensity.compact,
              onPressed: () {
                setState(() => _follow = true);
                _stickToBottom();
              },
              icon: Icon(
                Icons.vertical_align_bottom,
                size: 20,
                color: scheme.primary,
              ),
            ),
          IconButton(
            tooltip: '复制全部',
            visualDensity: VisualDensity.compact,
            onPressed: _lines.isEmpty
                ? null
                : () {
                    Clipboard.setData(ClipboardData(text: _lines.join('\n')));
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('日志已复制'),
                        duration: Duration(seconds: 1),
                      ),
                    );
                  },
            icon: const Icon(Icons.copy_all, size: 19),
          ),
          IconButton(
            tooltip: _expanded ? '缩小' : '放大',
            visualDensity: VisualDensity.compact,
            onPressed: () => setState(() => _expanded = !_expanded),
            icon: Icon(
              _expanded ? Icons.fullscreen_exit : Icons.fullscreen,
              size: 20,
            ),
          ),
          IconButton(
            tooltip: '关闭',
            visualDensity: VisualDensity.compact,
            onPressed: () => Navigator.of(context).pop(),
            icon: const Icon(Icons.close, size: 19),
          ),
        ],
      ),
    );
  }

  Widget _buildBody(ColorScheme scheme) {
    if (_loading && _lines.isEmpty) {
      return const Center(
        child: SizedBox(
          width: 22,
          height: 22,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    if (_error != null && _lines.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(errorText(_error!), textAlign: TextAlign.center),
            const SizedBox(height: 10),
            FilledButton.tonalIcon(
              onPressed: _refresh,
              icon: const Icon(Icons.refresh),
              label: const Text('重试'),
            ),
          ],
        ),
      );
    }
    if (_lines.isEmpty || _neverRun) {
      return Center(
        child: Text(
          _neverRun ? '面板还没写出日志文件，稍等…' : '任务刚启动，还没有输出…',
          style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant),
        ),
      );
    }
    return NotificationListener<ScrollNotification>(
      // 只认「手指拖动」引起的滚动，程序化 jumpTo 不该关掉跟随。
      onNotification: (n) {
        if (n is ScrollUpdateNotification && n.dragDetails != null) {
          final atBottom = n.metrics.pixels >= n.metrics.maxScrollExtent - 12;
          if (atBottom != _follow) setState(() => _follow = atBottom);
        }
        return false;
      },
      child: Scrollbar(
        controller: _scroll,
        thumbVisibility: true,
        child: ListView.builder(
          controller: _scroll,
          primary: false,
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.only(top: 6, bottom: 10, right: 8),
          itemCount: _lines.length,
          itemBuilder: (context, index) {
            final line = _lines[index];
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 1.5),
              child: SelectableText(
                line,
                style: TextStyle(
                  fontFamily: kMonoFamily,
                  fontFamilyFallback: kMonoFallback,
                  fontSize: 12,
                  height: 1.35,
                  color: line.contains('## 执行结束')
                      ? Colors.green.shade400
                      : line.contains('## 开始执行')
                          ? scheme.primary
                          : (line.contains('Error') || line.contains('错误'))
                              ? scheme.error
                              : scheme.onSurface,
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
