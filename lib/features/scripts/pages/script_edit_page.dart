import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'dart:async';

import '../../../core/network/panel_socket.dart';
import '../../../core/storage/secure_storage.dart';
import '../../../core/theme/glass.dart';
import '../../../core/utils/error_text.dart';
import '../../../shared/ask_ai.dart';
import '../../../shared/code_editor.dart';
import '../../../shared/code_language.dart';
import '../../../shared/editor_bus.dart';
import '../../../shared/glass_scaffold.dart';
import '../../../shared/highlighting_code_controller.dart';
import '../../../shared/loading_view.dart';
import '../../panels/models/panel_info.dart';
import '../../panels/providers/panel_list_provider.dart';
import '../api/script_api.dart';
import '../providers/script_list_provider.dart';
import '../../../shared/mono_text.dart';

class ScriptEditPage extends ConsumerStatefulWidget {
  const ScriptEditPage({super.key, required this.path, this.isNew = false});

  final String path;
  final bool isNew;

  @override
  ConsumerState<ScriptEditPage> createState() => _ScriptEditPageState();
}

class _ScriptEditPageState extends ConsumerState<ScriptEditPage> {
  final GlobalKey<CodeEditorFieldState> _editorKey =
      GlobalKey<CodeEditorFieldState>();
  final TextEditingController _searchController = TextEditingController();

  late final HighlightingCodeController _controller;
  bool _loading = true;
  bool _saving = false;
  bool _showSearch = false;
  bool _wrapMode = false;
  int _matchCount = 0;
  Object? _error;
  String? _original;

  /// 执行日志：只记本机发起的运行/停止与面板返回，用于一眼确认脚本有没有执行。
  final List<String> _runLogs = [];
  final ScrollController _logScroll = ScrollController();
  bool _showLog = false;
  bool _logExpanded = false;

  /// 实时贴底：手动往上滑就暂停，滑回底部或点"回到底部"恢复。
  bool _logFollow = true;
  bool _running = false;
  int? _runPid;
  PanelSocket? _socket;
  StreamSubscription<Map<String, dynamic>>? _socketSub;

  /// 编辑器总线上的注册 id。
  int? _busId;

  @override
  void initState() {
    super.initState();
    _controller = HighlightingCodeController(
      language: languageForPath(widget.path),
      languageName: languageNameForPath(widget.path),
    );
    // 挂上编辑器总线：AI 的 editor_* 工具据此认出"用户正在改青龙脚本"，
    // 并且只往这个编辑框里写代码。
    _busId = EditorBus.instance.register(
      kind: EditorKind.qinglongScript,
      title: _fileName,
      path: widget.path,
      controller: _controller,
      editorKey: _editorKey,
      language: languageNameForPath(widget.path),
      save: () async {
        await _save();
        return _dirty ? '保存失败（看编辑器上的提示）。' : '已保存到面板：${widget.path}';
      },
      run: () async {
        await _run();
        return _running
            ? '已让面板运行 ${widget.path}（跑的是编辑器里的当前内容，含未保存改动）。'
                '过几秒用 editor_log 看输出。'
            : '运行指令没发出去，用 editor_log 看报错。';
      },
      readLog: () => _runLogs.join('\n'),
    );
    if (!widget.isNew) {
      _load();
    } else {
      _loading = false;
    }
  }

  @override
  void dispose() {
    final busId = _busId;
    if (busId != null) EditorBus.instance.unregister(busId);
    _socketSub?.cancel();
    _socket?.close();
    _searchController.dispose();
    _logScroll.dispose();
    _controller.dispose();
    super.dispose();
  }

  bool get _dirty => _controller.text != _original;

  String get _fileName {
    final parts = widget.path.split('/');
    return parts.isEmpty ? widget.path : parts.last;
  }

  String? get _aiLanguage {
    final lower = widget.path.toLowerCase();
    if (lower.endsWith('.js') ||
        lower.endsWith('.mjs') ||
        lower.endsWith('.cjs') ||
        lower.endsWith('.jsx')) {
      return 'js';
    }
    if (lower.endsWith('.ts') || lower.endsWith('.tsx')) {
      return 'ts';
    }
    if (lower.endsWith('.py') || lower.endsWith('.python')) {
      return 'py';
    }
    if (lower.endsWith('.sh') ||
        lower.endsWith('.bash') ||
        lower.endsWith('.zsh') ||
        lower.endsWith('.command')) {
      return 'sh';
    }
    return null;
  }

  String get _askAiContent {
    final selected = _editorKey.currentState?.selectedText ?? '';
    if (selected.trim().isNotEmpty) return selected;
    return _controller.text;
  }

  Future<void> _load() async {
    final panel = ref.read(currentPanelProvider);
    if (panel == null) {
      setState(() {
        _loading = false;
        _error = '未选择面板';
      });
      return;
    }
    try {
      final content = await ScriptApi.read(
        apiBaseUrl: panel.apiBaseUrl,
        file: widget.path,
      );
      if (!mounted) return;
      setState(() {
        _controller.text = content;
        _original = content;
        _loading = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e;
      });
    }
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      final notifier = ref.read(scriptListProvider.notifier);
      if (widget.isNew) {
        await notifier.create(widget.path, _controller.text);
      } else {
        await notifier.save(widget.path, _controller.text);
      }
      if (!mounted) return;
      _original = _controller.text;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('脚本已保存')),
      );
      setState(() => _saving = false);
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('保存失败：${errorText(e)}')),
      );
    }
  }

  void _appendLog(String line) {
    final time = TimeOfDay.now().format(context);
    _runLogs.add('[$time] $line');
    setState(() {});
    _stickToBottom();
  }

  /// 只在"跟随"状态下贴底，避免打断用户手动查看历史输出。
  void _stickToBottom() {
    if (!_logFollow) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_logFollow || !_logScroll.hasClients) return;
      _logScroll.jumpTo(_logScroll.position.maxScrollExtent);
    });
  }

  Future<void> _run() async {
    final panel = ref.read(currentPanelProvider);
    if (panel == null) {
      _appendLog('运行失败：未选择面板');
      return;
    }
    if (_dirty) {
      _appendLog('· 运行的是编辑器里的当前内容（含未保存修改）');
    }
    setState(() {
      _showLog = true;
      _running = true;
    });
    _appendLog('▶ 运行 ${widget.path}');
    // 手动运行的输出只走面板 WebSocket 广播（type=manuallyRunScript），
    // 不落日志文件，所以必须先接上通道再发运行指令。
    await _attachSocket(panel);
    try {
      final result = await ScriptApi.run(
        apiBaseUrl: panel.apiBaseUrl,
        path: widget.path,
        // 面板跑的是这里提交的内容，所以直接送编辑器里的当前文本：
        // 想试改动不必先保存。
        content: _controller.text,
      );
      _runPid = result is int ? result : int.tryParse(result?.toString() ?? '');
      _appendLog('✓ 面板已受理：${_describeRunResult(result)}');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('已发送运行指令')),
        );
      }
    } catch (e) {
      setState(() => _running = false);
      _appendLog('✗ 运行失败：${errorText(e)}');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('运行失败：${errorText(e)}')),
        );
      }
    }
  }

  /// 接上面板实时通道；失败就退化成提示，不影响运行本身。
  Future<void> _attachSocket(PanelInfo panel) async {
    if (_socket != null) return;
    final token = await SecureStorage.readToken(panel.id);
    if (token == null || token.isEmpty) {
      _appendLog('— 未取到面板 token，无法接收实时输出');
      return;
    }
    try {
      final socket = await PanelSocket.connect(
        baseUrl: panel.baseUrl,
        token: token,
      );
      _socket = socket;
      _socketSub = socket.messages.listen(
        _onSocketMessage,
        onDone: () {
          if (!mounted) return;
          _socket = null;
          _socketSub = null;
          if (_running) {
            setState(() => _running = false);
            _appendLog('— 实时通道已断开');
          }
        },
      );
      _appendLog('· 已接入面板实时输出通道');
    } catch (e) {
      _appendLog('— 实时通道连接失败：${errorText(e)}（仍会执行，输出请看日志中心）');
    }
  }

  void _onSocketMessage(Map<String, dynamic> msg) {
    if (msg['type'] == 'ping') return;
    if (msg['type'] != 'manuallyRunScript') return;
    final message = (msg['message'] ?? '').toString();
    if (message.isEmpty) return;
    for (final line in message.split('\n')) {
      if (line.trimRight().isEmpty) continue;
      _runLogs.add(line.trimRight());
    }
    if (message.contains('执行结束') || message.contains('## 执行结束')) {
      _running = false;
    }
    if (!mounted) return;
    setState(() {});
    _stickToBottom();
  }

  String _describeRunResult(Object? result) {
    if (result == null) return '面板未返回回执信息';
    if (result is String) return result;
    if (result is Map) {
      final keys = result.keys.map((e) => e.toString()).toList();
      if (result['logPath'] != null || result['log_path'] != null) {
        return '日志路径：${result['logPath'] ?? result['log_path']}';
      }
      if (result['id'] != null || result['cid'] != null) {
        return '任务 ID：${result['id'] ?? result['cid']}';
      }
      return '返回字段：${keys.join(', ')}';
    }
    return result.toString();
  }

  Future<void> _stop() async {
    final panel = ref.read(currentPanelProvider);
    if (panel == null) {
      _appendLog('停止失败：未选择面板');
      return;
    }
    setState(() => _showLog = true);
    _appendLog('■ 停止 ${widget.path}');
    try {
      await ScriptApi.stop(
        apiBaseUrl: panel.apiBaseUrl,
        path: widget.path,
        pid: _runPid,
      );
      setState(() => _running = false);
      _appendLog('✓ 已发送停止指令');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('已发送停止指令')),
        );
      }
    } catch (e) {
      _appendLog('✗ 停止失败：${errorText(e)}');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('停止失败：${errorText(e)}')),
        );
      }
    }
  }

  void _undo() {
    _editorKey.currentState?.undo();
    setState(() {});
  }

  void _redo() {
    _editorKey.currentState?.redo();
    setState(() {});
  }

  void _toggleWrap() {
    setState(() => _wrapMode = !_wrapMode);
  }

  void _toggleSearch() {
    setState(() {
      _showSearch = !_showSearch;
      _matchCount = _showSearch
          ? (_editorKey.currentState?.countMatches(_searchController.text) ?? 0)
          : 0;
    });
  }

  void _closeSearch() {
    setState(() {
      _showSearch = false;
      _matchCount = 0;
    });
    _searchController.clear();
  }

  void _onSearchChanged(String value) {
    final count = _editorKey.currentState?.countMatches(value) ?? 0;
    setState(() => _matchCount = count);
    if (count > 0) {
      _editorKey.currentState?.selectNextMatch(value);
    }
  }

  void _goNext() {
    final query = _searchController.text;
    if (query.isEmpty) return;
    setState(() {
      _editorKey.currentState?.selectNextMatch(query);
    });
  }

  void _goPrev() {
    final query = _searchController.text;
    if (query.isEmpty) return;
    setState(() {
      _editorKey.currentState?.selectNextMatch(query, reverse: true);
    });
  }

  void _sendSelectedToAi() {
    final selected = _editorKey.currentState?.selectedText ?? '';
    if (selected.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('请先在编辑器里选中代码'),
          duration: Duration(seconds: 1),
        ),
      );
      return;
    }
    AskAi.pushWithToast(
      context,
      ref,
      label: '脚本 · $_fileName（选区）',
      content: selected,
      source: '脚本管理',
      language: _aiLanguage,
      draft: '帮我看看这段选中的代码，有问题就修，没问题就说明它在做什么',
    );
  }

  Widget _buildSearchBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
      child: GlassPanel(
        radius: 16,
        blur: 12,
        shadowY: 2,
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        child: Row(
          children: [
            const Icon(Icons.search, size: 18),
            const SizedBox(width: 6),
            Expanded(
              child: TextField(
                controller: _searchController,
                autofocus: true,
                style: const TextStyle(fontSize: 13),
                decoration: const InputDecoration(
                  hintText: '查找关键字',
                  // 同上：外面已经是一条玻璃工具条，别再套一层填充。
                  filled: false,
                  border: InputBorder.none,
                  isDense: true,
                ),
                onChanged: _onSearchChanged,
                onSubmitted: (_) => _goNext(),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: Text(
                '$_matchCount',
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            IconButton(
              tooltip: '上一个',
              visualDensity: VisualDensity.compact,
              onPressed: _matchCount == 0 ? null : _goPrev,
              icon: const Icon(Icons.keyboard_arrow_up, size: 20),
            ),
            IconButton(
              tooltip: '下一个',
              visualDensity: VisualDensity.compact,
              onPressed: _matchCount == 0 ? null : _goNext,
              icon: const Icon(Icons.keyboard_arrow_down, size: 20),
            ),
            IconButton(
              tooltip: '关闭查找',
              visualDensity: VisualDensity.compact,
              onPressed: _closeSearch,
              icon: const Icon(Icons.close, size: 18),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLogPane() {
    final scheme = Theme.of(context).colorScheme;
    final screenH = MediaQuery.sizeOf(context).height;
    // 展开 = 半屏；收起 = 紧凑一栏。底部留出浮动工具条的空间，
    // 否则工具条会盖在日志上，手指划到的其实是工具条，日志"划不动"。
    final height = _logExpanded ? screenH * 0.46 : 210.0;
    return Container(
      height: height,
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 104),
      child: GlassPanel(
        radius: 16,
        blur: 14,
        shadowY: 3,
        padding: const EdgeInsets.fromLTRB(10, 4, 10, 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 标题条本身可拖：上下拖动 = 展开/收起。
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onVerticalDragEnd: (d) {
                final vy = d.velocity.pixelsPerSecond.dy;
                if (vy < -80 && !_logExpanded) {
                  setState(() => _logExpanded = true);
                } else if (vy > 80 && _logExpanded) {
                  setState(() => _logExpanded = false);
                }
              },
              onTap: () => setState(() => _logExpanded = !_logExpanded),
              child: Row(
                children: [
                  Icon(Icons.terminal, size: 16, color: scheme.primary),
                  const SizedBox(width: 6),
                  const Text(
                    '执行日志',
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  if (_running) ...[
                    const SizedBox(width: 8),
                    const SizedBox(
                      width: 12,
                      height: 12,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      '运行中',
                      style: TextStyle(fontSize: 11.5, color: scheme.primary),
                    ),
                  ],
                  const Spacer(),
                  if (!_logFollow)
                    IconButton(
                      tooltip: '回到最新',
                      visualDensity: VisualDensity.compact,
                      onPressed: () {
                        setState(() => _logFollow = true);
                        _stickToBottom();
                      },
                      icon: Icon(
                        Icons.vertical_align_bottom,
                        size: 19,
                        color: scheme.primary,
                      ),
                    ),
                  if (_runLogs.isNotEmpty)
                    IconButton(
                      tooltip: '清空',
                      visualDensity: VisualDensity.compact,
                      onPressed: () => setState(() {
                        _runLogs.clear();
                        _logFollow = true;
                      }),
                      icon: const Icon(Icons.delete_sweep_outlined, size: 19),
                    ),
                  IconButton(
                    tooltip: _logExpanded ? '缩小' : '放大到半屏',
                    visualDensity: VisualDensity.compact,
                    onPressed: () =>
                        setState(() => _logExpanded = !_logExpanded),
                    icon: Icon(
                      _logExpanded ? Icons.fullscreen_exit : Icons.fullscreen,
                      size: 20,
                    ),
                  ),
                  IconButton(
                    tooltip: '收起日志',
                    visualDensity: VisualDensity.compact,
                    onPressed: () => setState(() => _showLog = false),
                    icon: const Icon(Icons.keyboard_arrow_down, size: 20),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: _runLogs.isEmpty
                  ? Center(
                      child: Text(
                        '还没有执行动作。点右上角 ▶ 运行脚本，输出会实时打到这里。',
                        style: TextStyle(
                          fontSize: 12,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    )
                  : NotificationListener<ScrollNotification>(
                      // 手动往上滑 → 暂停实时滚动；滑回底部 → 自动恢复。
                      onNotification: (n) {
                        if (n is ScrollUpdateNotification &&
                            n.dragDetails != null) {
                          final atBottom = n.metrics.pixels >=
                              n.metrics.maxScrollExtent - 12;
                          if (atBottom != _logFollow) {
                            setState(() => _logFollow = atBottom);
                          }
                        }
                        return false;
                      },
                      child: Scrollbar(
                        controller: _logScroll,
                        thumbVisibility: true,
                        child: ListView.builder(
                          controller: _logScroll,
                          primary: false,
                          physics: const AlwaysScrollableScrollPhysics(),
                          padding: const EdgeInsets.only(
                            top: 4,
                            bottom: 8,
                            right: 8,
                          ),
                          itemCount: _runLogs.length,
                          itemBuilder: (context, index) {
                            final line = _runLogs[index];
                            return Padding(
                              padding: const EdgeInsets.symmetric(vertical: 2),
                              child: SelectableText(
                                line,
                                style: TextStyle(
                                  fontFamily: kMonoFamily,
                                  fontFamilyFallback: kMonoFallback,
                                  fontSize: 12,
                                  height: 1.35,
                                  color: line.startsWith('✗')
                                      ? scheme.error
                                      : line.startsWith('✓')
                                          ? Colors.green.shade400
                                          : line.startsWith('▶')
                                              ? scheme.primary
                                              : scheme.onSurface,
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBottomBar() {
    return GlassPanel(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            GlassPill(
              icon: Icons.undo,
              tooltip: '撤销',
              onTap: _undo,
              dense: true,
            ),
            const SizedBox(width: 6),
            GlassPill(
              icon: Icons.redo,
              tooltip: '重做',
              onTap: _redo,
              dense: true,
            ),
            const SizedBox(width: 6),
            GlassPill(
              icon: Icons.search,
              tooltip: '查找',
              onTap: _toggleSearch,
              dense: true,
            ),
            const SizedBox(width: 6),
            GlassPill(
              icon: Icons.text_decrease,
              tooltip: '字号-',
              onTap: () {
                _editorKey.currentState?.decreaseFontSize();
              },
              dense: true,
            ),
            const SizedBox(width: 6),
            GlassPill(
              icon: Icons.text_increase,
              tooltip: '字号+',
              onTap: () {
                _editorKey.currentState?.increaseFontSize();
              },
              dense: true,
            ),
            const SizedBox(width: 6),
            GlassPill(
              icon: Icons.wrap_text,
              label: _wrapMode ? '换行开' : '换行',
              tooltip: '换行开关',
              onTap: _toggleWrap,
              dense: true,
            ),
            const SizedBox(width: 6),
            GlassPill(
              icon: Icons.auto_awesome,
              tooltip: '选中发 AI',
              onTap: _sendSelectedToAi,
              dense: true,
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        final navigator = Navigator.of(context);
        final leave = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('放弃修改？'),
            content: const Text('当前修改尚未保存。'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('继续编辑'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('放弃'),
              ),
            ],
          ),
        );
        if (leave == true) {
          navigator.pop();
        }
      },
      child: GlassScaffold(
        title: _fileName,
        subtitle: widget.path,
        actions: [
          if (!widget.isNew)
            IconButton(
              tooltip: '停止',
              onPressed: _stop,
              icon: const Icon(Icons.stop),
            ),
          if (!widget.isNew)
            IconButton(
              tooltip: '运行',
              onPressed: _run,
              icon: const Icon(Icons.play_arrow),
            ),
          AskAiButton(
            label: '脚本 · $_fileName',
            source: '脚本管理',
            language: _aiLanguage,
            contentBuilder: () => _askAiContent,
            draft: '帮我看看这段代码，有问题就修，没问题就说明它在做什么',
          ),
          IconButton(
            tooltip: '保存',
            onPressed: _saving ? null : _save,
            icon: const Icon(Icons.save_outlined),
          ),
        ],
        headerBottom: _showSearch ? _buildSearchBar() : null,
        bottomBar: _loading || _error != null ? null : _buildBottomBar(),
        body: _loading
            ? const LoadingView()
            : _error != null
                ? Center(
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
                  )
                : Column(
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                        child: Align(
                          alignment: Alignment.centerRight,
                          child: Text(
                            _dirty ? '未保存' : '已保存',
                            style: TextStyle(
                              fontSize: 12,
                              color: _dirty
                                  ? Theme.of(context).colorScheme.error
                                  : Theme.of(context).colorScheme.outline,
                            ),
                          ),
                        ),
                      ),
                      // 上半：编辑器；下半：执行日志分屏。运行后日志自动展开。
                      Expanded(
                        child: Padding(
                          // 日志面板自己已避开底部工具条；日志收起时编辑器才需要留白。
                          padding: EdgeInsets.only(bottom: _showLog ? 4 : 96),
                          child: GestureDetector(
                            // 戳一下就把 AI 的默认改动目标切到这个编辑器。
                            behavior: HitTestBehavior.translucent,
                            onTapDown: (_) {
                              final busId = _busId;
                              if (busId != null) {
                                EditorBus.instance.touch(busId);
                              }
                            },
                            child: CodeEditorField(
                              key: _editorKey,
                              controller: _controller,
                              path: widget.path,
                              onChanged: (_) => setState(() {}),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 8,
                              ),
                              wrap: _wrapMode,
                            ),
                          ),
                        ),
                      ),
                      if (_showLog) _buildLogPane(),
                    ],
                  ),
      ),
    );
  }
}
