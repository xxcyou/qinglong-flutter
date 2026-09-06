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
import '../../../shared/mono_text.dart';
import '../../../shared/tail_scroll.dart';
import '../../panels/providers/panel_list_provider.dart';
import '../../settings/providers/settings_provider.dart';
import '../api/subscription_api.dart';

/// 订阅拉取日志：跟着写、能搜、能复制、能一键甩给 AI 看报错。
///
/// 拉仓库失败的原因九成藏在这里（网络不通、分支名写错、私有仓库凭据不对、
/// 依赖装不上）。所以这一页和任务日志一样要"自动跟随 + 自动挂给 AI"。
class SubscriptionLogPage extends ConsumerStatefulWidget {
  const SubscriptionLogPage({
    super.key,
    required this.subId,
    required this.title,
  });

  final int subId;
  final String title;

  @override
  ConsumerState<SubscriptionLogPage> createState() =>
      _SubscriptionLogPageState();
}

class _SubscriptionLogPageState extends ConsumerState<SubscriptionLogPage>
    with AiLiveContextMixin<SubscriptionLogPage> {
  static final RegExp _errorPattern =
      RegExp('error|Error|ERROR|fatal|失败|Traceback|Exception');

  final _tail = TailScroll();
  final _searchController = TextEditingController();
  Timer? _timer;
  List<String> _lines = const [];
  bool _loading = true;
  Object? _error;

  @override
  String get aiContextKey => 'sublog:${widget.subId}';

  @override
  String get aiContextLabel => '订阅日志 · ${widget.title}';

  @override
  String get aiContextSource => '订阅拉取日志（用户正在看）';

  @override
  String buildAiContext() => _buildAiContent();

  /// 给 AI 的那份：优先报错行及上下 3 行，没有报错就取末尾 200 行。
  String _buildAiContent() {
    if (_lines.isEmpty) return '';
    final hits = <int>[
      for (var i = 0; i < _lines.length; i++)
        if (_errorPattern.hasMatch(_lines[i])) i,
    ];
    if (hits.isNotEmpty) {
      final included = <int>{};
      for (final idx in hits) {
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
    final millis = ref.read(settingsProvider).logPollMillis;
    _timer = Timer.periodic(
      Duration(milliseconds: millis.clamp(200, 60000)),
      (_) => _refresh(),
    );
  }

  @override
  void dispose() {
    _timer?.cancel();
    _tail.dispose();
    _searchController.dispose();
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
      final log = await SubscriptionApi.fetchLog(
        apiBaseUrl: panel.apiBaseUrl,
        id: widget.subId,
      );
      if (!mounted) return;
      setState(() {
        _lines = log.lines;
        _error = null;
        _loading = false;
      });
      syncAiContext();
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
              if (line.toLowerCase().contains(keyword.toLowerCase())) line,
          ];
    final text = filtered.join('\n');

    return GlassScaffold(
      title: '订阅日志',
      subtitle: widget.title,
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
          draft: '这条订阅拉取失败了，日志里的原因是什么，怎么修',
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
      body: _buildBody(filtered),
    );
  }

  Widget _buildBody(List<String> filtered) {
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
      return const Center(child: Text('暂无日志（这条订阅还没跑过）'));
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
