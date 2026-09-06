import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/glass.dart';
import '../../../core/utils/error_text.dart';
import '../../../shared/ai_live_context.dart';
import '../../../shared/ask_ai.dart';
import '../../../shared/glass_scaffold.dart';
import '../../../shared/loading_view.dart';
import '../../../shared/tail_scroll.dart';
import '../../panels/providers/panel_list_provider.dart';
import '../../settings/providers/settings_provider.dart';
import '../api/cron_api.dart';
import '../../../shared/mono_text.dart';

class CronLogPage extends ConsumerStatefulWidget {
  const CronLogPage({
    super.key,
    required this.cronId,
    required this.taskName,
    this.logPath,
  });

  final int cronId;
  final String taskName;
  final String? logPath;

  @override
  ConsumerState<CronLogPage> createState() => _CronLogPageState();
}

class _CronLogPageState extends ConsumerState<CronLogPage>
    with AiLiveContextMixin<CronLogPage> {
  /// 报错关键词：给 AI 的那份优先挑报错段落，别把几千行正常输出都塞过去。
  static final RegExp _errorPattern =
      RegExp('error|Error|ERROR|失败|Traceback|Exception');

  final _tail = TailScroll();
  final _searchController = TextEditingController();
  Timer? _timer;
  List<String> _lines = const [];
  bool _loading = true;
  Object? _error;

  // ------------------------------------------------- 自动附给 AI 的上下文
  @override
  String get aiContextKey => 'cronlog:${widget.cronId}';

  @override
  String get aiContextLabel => '任务日志 · ${widget.taskName}';

  @override
  String get aiContextSource => '任务日志（用户正在看）';

  @override
  String buildAiContext() => _buildAiContent();

  /// 发给 AI 的内容：优先报错行及上下各 3 行；没有报错时取末尾 200 行。
  String _buildAiContent() {
    if (_lines.isEmpty) return '';
    final errorIndexes = <int>[
      for (var i = 0; i < _lines.length; i++)
        if (_errorPattern.hasMatch(_lines[i])) i,
    ];
    if (errorIndexes.isNotEmpty) {
      final included = <int>{};
      for (final idx in errorIndexes) {
        for (var offset = -3; offset <= 3; offset++) {
          final target = idx + offset;
          if (target >= 0 && target < _lines.length) included.add(target);
        }
      }
      final sorted = included.toList()..sort();
      return sorted.map((i) => '${i + 1}: ${_lines[i]}').join('\n');
    }
    final start = _lines.length > 200 ? _lines.length - 200 : 0;
    return _lines.skip(start).join('\n');
  }

  @override
  void initState() {
    super.initState();
    _refresh();
    _startPolling();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _tail.dispose();
    _searchController.dispose();
    super.dispose();
  }

  void _startPolling() {
    _timer?.cancel();
    final millis = ref.read(settingsProvider).logPollMillis;
    _timer = Timer.periodic(
      Duration(milliseconds: millis.clamp(200, 60000)),
      (_) => _refresh(),
    );
  }

  Future<void> _refresh() async {
    final panel = ref.read(currentPanelProvider);
    if (panel == null) {
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
        logPath: widget.logPath,
      );
      if (!mounted) return;
      setState(() {
        _lines = log.lines;
        _error = null;
        _loading = false;
      });
      // 内容变了就同步一次附件：用户点开悬浮窗时带的是当下的日志。
      syncAiContext();
      // 跟随由 TailScroll 判断：用户手动往上滑就自动暂停，滑回底部再恢复。
      if (_lines.isNotEmpty) _tail.stick();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final keyword = _searchController.text.trim();
    final filtered = keyword.isEmpty
        ? _lines
        : [
            for (final line in _lines)
              if (line.toLowerCase().contains(keyword.toLowerCase())) line
          ];
    final text = filtered.join('\n');

    return GlassScaffold(
      title: '任务日志',
      subtitle: widget.taskName,
      showBack: true,
      actions: [
        IconButton(
          tooltip: '立即刷新',
          onPressed: _refresh,
          icon: const Icon(Icons.refresh),
        ),
        IconButton(
          tooltip: '复制全部',
          onPressed: text.isEmpty
              ? null
              : () => Clipboard.setData(ClipboardData(text: text)),
          icon: const Icon(Icons.copy_all),
        ),
        AskAiButton(
          label: aiContextLabel,
          source: aiContextSource,
          contentBuilder: _buildAiContent,
          draft: '这个任务日志里的报错是什么原因，怎么修',
          // 和自动附带的是同一个附件：点这里只是「确认带上并展开面板」，
          // 不会多出一份重复内容，也会撤销之前的 X。
          contextKey: aiContextKey,
          readOnly: true,
          sticky: true,
        ),
      ],
      headerBottom: Padding(
        padding: const EdgeInsets.fromLTRB(0, 6, 10, 4),
        child: Row(
          children: [
            Expanded(
              child: GlassPanel(
                radius: 14,
                blur: 14,
                padding: const EdgeInsets.symmetric(horizontal: 10),
                child: TextField(
                  controller: _searchController,
                  onChanged: (_) => setState(() {}),
                  style: const TextStyle(fontSize: 13.5),
                  decoration: const InputDecoration(
                    hintText: '搜索高亮',
                    isDense: true,
                    filled: false,
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    prefixIcon: Icon(Icons.search, size: 18),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 6),
            ValueListenableBuilder<bool>(
              valueListenable: _tail.following,
              builder: (context, following, _) => GlassPill(
                icon: following
                    ? Icons.vertical_align_bottom
                    : Icons.pause_circle_outline,
                label: following ? '跟随中' : '已暂停',
                dense: true,
                tooltip: following ? '正在跟随最新输出（手动上滑会暂停）' : '点一下回到最新并恢复跟随',
                onTap: following ? null : _tail.resume,
              ),
            ),
          ],
        ),
      ),
      floatingActionButton: FollowTailButton(tail: _tail),
      body: _buildBody(filtered, text),
    );
  }

  Widget _buildBody(List<String> filtered, String text) {
    if (_loading && _lines.isEmpty) return const LoadingView();
    if (_error != null && _lines.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(errorText(_error!)),
            const SizedBox(height: 12),
            FilledButton.tonalIcon(
              onPressed: _refresh,
              icon: const Icon(Icons.refresh),
              label: const Text('重试'),
            ),
          ],
        ),
      );
    }
    if (filtered.isEmpty) {
      return const Center(child: Text('暂无日志'));
    }
    final keyword = _searchController.text.trim();
    return SingleChildScrollView(
      controller: _tail.controller,
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 110),
      child: SelectableText.rich(
        TextSpan(
          children: [
            for (final line in filtered)
              TextSpan(
                children: [
                  _highlightLine(line, keyword),
                  const TextSpan(text: '\n'),
                ],
              ),
          ],
        ),
        style: const TextStyle(
          fontFamily: kMonoFamily,
          fontFamilyFallback: kMonoFallback,
          fontSize: 13,
          height: 1.4,
        ),
      ),
    );
  }

  TextSpan _highlightLine(String line, String keyword) {
    if (keyword.isEmpty) return TextSpan(text: line);
    final lower = line.toLowerCase();
    final kw = keyword.toLowerCase();
    final spans = <TextSpan>[];
    var start = 0;
    while (true) {
      final index = lower.indexOf(kw, start);
      if (index < 0) {
        if (start < line.length) {
          spans.add(TextSpan(text: line.substring(start)));
        }
        break;
      }
      if (index > start) {
        spans.add(TextSpan(text: line.substring(start, index)));
      }
      spans.add(
        TextSpan(
          text: line.substring(index, index + kw.length),
          style: const TextStyle(
            backgroundColor: Color(0xFFFFF59D),
            color: Colors.black,
            fontWeight: FontWeight.bold,
          ),
        ),
      );
      start = index + kw.length;
    }
    return TextSpan(children: spans);
  }
}
