import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/glass.dart';
import '../../../core/utils/error_text.dart';
import '../../../shared/ai_live_context.dart';
import '../../../shared/ask_ai.dart';
import '../../../shared/empty_view.dart';
import '../../../shared/glass_scaffold.dart';
import '../../../shared/loading_view.dart';
import '../../../shared/tail_scroll.dart';
import '../../panels/providers/panel_list_provider.dart';
import '../../settings/providers/settings_provider.dart';
import '../api/log_api.dart';
import '../../../shared/mono_text.dart';

class LogViewPage extends ConsumerStatefulWidget {
  const LogViewPage({super.key, required this.file, this.dir = ''});

  final String file;
  final String dir;

  @override
  ConsumerState<LogViewPage> createState() => _LogViewPageState();
}

class _LogViewPageState extends ConsumerState<LogViewPage>
    with AiLiveContextMixin<LogViewPage> {
  /// 报错关键词，用于高亮和“只看报错”。
  static final RegExp _errorPattern =
      RegExp('error|Error|ERROR|失败|Traceback|Exception');

  List<String> _lines = const [];
  bool _loading = true;
  bool _onlyErrors = false;
  Object? _error;

  final _tail = TailScroll();
  Timer? _timer;

  /// 自动刷新默认开：日志页最常见的用法就是盯着它跑。
  bool _autoRefresh = true;

  // ------------------------------------------------- 自动附给 AI 的上下文
  @override
  String get aiContextKey => 'log:${widget.dir}/${widget.file}';

  @override
  String get aiContextLabel => '日志 · ${widget.file}';

  @override
  String get aiContextSource => '日志中心（用户正在看）';

  @override
  String buildAiContext() => _buildAiContent();

  @override
  void initState() {
    super.initState();
    _load();
    _startPolling();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _tail.dispose();
    super.dispose();
  }

  void _startPolling() {
    _timer?.cancel();
    if (!_autoRefresh) return;
    final millis = ref.read(settingsProvider).logPollMillis;
    _timer = Timer.periodic(
      Duration(milliseconds: millis.clamp(200, 60000)),
      (_) => _load(silent: true),
    );
  }

  Future<void> _load({bool silent = false}) async {
    final panel = ref.read(currentPanelProvider);
    if (panel == null) {
      setState(() {
        _loading = false;
        _error = '未选择面板';
      });
      return;
    }
    try {
      final lines = await LogApi.read(
        apiBaseUrl: panel.apiBaseUrl,
        file: widget.file,
        dir: widget.dir,
      );
      if (!mounted) return;
      // 内容没变就不 setState：500ms 一次的轮询里，重建整个列表会让
      // 选中文字丢失，也白烧一帧。
      final changed = lines.length != _lines.length ||
          (lines.isNotEmpty && _lines.isNotEmpty && lines.last != _lines.last);
      if (!changed && _error == null && !_loading) return;
      setState(() {
        _lines = lines;
        _loading = false;
        _error = null;
      });
      // 内容变了就同步一次附件：用户点开悬浮窗时带的是当下的日志。
      syncAiContext();
      _tail.stick();
    } catch (e) {
      if (!mounted) return;
      // 静默刷新失败不要覆盖已经显示出来的内容，否则网络一抖整页变报错。
      if (silent && _lines.isNotEmpty) return;
      setState(() {
        _loading = false;
        _error = e;
      });
    }
  }

  bool _isErrorLine(String line) => _errorPattern.hasMatch(line);

  /// 当前需要展示的行下标；开启“只看报错”时只保留报错行。
  List<int> get _visibleIndexes {
    if (!_onlyErrors) return List.generate(_lines.length, (i) => i);
    return [
      for (var i = 0; i < _lines.length; i++)
        if (_isErrorLine(_lines[i])) i,
    ];
  }

  /// 发给 AI 的内容：优先报错行及上下各 3 行；没有报错时取末尾 200 行。
  String _buildAiContent() {
    if (_lines.isEmpty) return '';
    final errorIndexes = <int>[
      for (var i = 0; i < _lines.length; i++)
        if (_isErrorLine(_lines[i])) i,
    ];
    if (errorIndexes.isNotEmpty) {
      final included = <int>{};
      for (final idx in errorIndexes) {
        for (var offset = -3; offset <= 3; offset++) {
          final target = idx + offset;
          if (target >= 0 && target < _lines.length) {
            included.add(target);
          }
        }
      }
      final sorted = included.toList()..sort();
      return sorted.map((i) => '${i + 1}: ${_lines[i]}').join('\n');
    }
    final start = _lines.length > 200 ? _lines.length - 200 : 0;
    return _lines.skip(start).join('\n');
  }

  @override
  Widget build(BuildContext context) {
    final text = _lines.join('\n');
    final scheme = Theme.of(context).colorScheme;
    return GlassScaffold(
      title: widget.file,
      subtitle: widget.dir.isEmpty ? '根目录' : widget.dir,
      actions: [
        IconButton(
          tooltip: '复制全部',
          onPressed: text.isEmpty
              ? null
              : () => Clipboard.setData(ClipboardData(text: text)),
          icon: const Icon(Icons.copy_all),
        ),
        IconButton(
          tooltip: '立即刷新',
          onPressed: () => _load(),
          icon: const Icon(Icons.refresh),
        ),
        AskAiButton(
          label: aiContextLabel,
          source: aiContextSource,
          contentBuilder: _buildAiContent,
          draft: '这个日志里的报错是什么原因，怎么修',
          contextKey: aiContextKey,
          readOnly: true,
          sticky: true,
        ),
      ],
      headerBottom: Padding(
        padding: const EdgeInsets.fromLTRB(0, 6, 10, 4),
        child: Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            GlassPill(
              icon: _onlyErrors ? Icons.filter_alt_off : Icons.error_outline,
              label: _onlyErrors ? '只看报错：开' : '只看报错',
              color: _onlyErrors ? scheme.error : null,
              onTap: () => setState(() => _onlyErrors = !_onlyErrors),
              tooltip: '只显示包含报错关键词的行',
              dense: true,
            ),
            GlassPill(
              icon: _autoRefresh ? Icons.autorenew : Icons.pause_circle_outline,
              label: _autoRefresh ? '自动 ${_intervalLabel()}' : '自动刷新：关',
              dense: true,
              tooltip: '点一下开关自动刷新，长按到设置里改间隔',
              onTap: () {
                setState(() => _autoRefresh = !_autoRefresh);
                _startPolling();
              },
            ),
            ValueListenableBuilder<bool>(
              valueListenable: _tail.following,
              builder: (context, following, _) => GlassPill(
                icon: following
                    ? Icons.vertical_align_bottom
                    : Icons.pause_circle_outline,
                label: following ? '跟随中' : '已暂停',
                dense: true,
                tooltip: following ? '手动上滑会暂停跟随' : '点一下回到最新',
                onTap: following ? null : _tail.resume,
              ),
            ),
          ],
        ),
      ),
      floatingActionButton: FollowTailButton(tail: _tail),
      body: _buildBody(context),
    );
  }

  String _intervalLabel() {
    final millis = ref.read(settingsProvider).logPollMillis;
    return millis % 1000 == 0
        ? '${millis ~/ 1000}s'
        : '${(millis / 1000).toStringAsFixed(1)}s';
  }

  Widget _buildBody(BuildContext context) {
    if (_loading) return const LoadingView();
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(errorText(_error!)),
            const SizedBox(height: 12),
            FilledButton.tonalIcon(
              onPressed: _load,
              icon: const Icon(Icons.refresh),
              label: const Text('重试'),
            ),
          ],
        ),
      );
    }

    final indexes = _visibleIndexes;
    if (_onlyErrors && indexes.isEmpty) {
      return const EmptyView(
        message: '没有匹配的报错行',
        icon: Icons.check_circle_outline,
      );
    }

    final scheme = Theme.of(context).colorScheme;
    return ListView.builder(
      controller: _tail.controller,
      padding: const EdgeInsets.only(top: 4, bottom: 110),
      itemCount: indexes.length,
      itemBuilder: (context, position) {
        final lineIndex = indexes[position];
        final line = _lines[lineIndex];
        final isError = _isErrorLine(line);
        return Container(
          color: isError ? scheme.errorContainer.withValues(alpha: 0.28) : null,
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 46,
                child: Text(
                  '${lineIndex + 1}',
                  textAlign: TextAlign.right,
                  style: TextStyle(
                    fontFamily: kMonoFamily,
                    fontFamilyFallback: kMonoFallback,
                    fontSize: 12,
                    color: scheme.onSurfaceVariant.withValues(alpha: 0.5),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: SelectableText(
                  line.isEmpty ? ' ' : line,
                  style: TextStyle(
                    fontFamily: kMonoFamily,
                    fontFamilyFallback: kMonoFallback,
                    fontSize: 13,
                    height: 1.4,
                    color: isError ? scheme.error : null,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
