import 'dart:async';

import 'package:flutter/material.dart';

import 'code_editor.dart';
import 'highlighting_code_controller.dart';

/// 四套代码编辑器的身份。
///
/// 为什么要有这个枚举：AI 改代码必须知道自己在改**哪一个**编辑器。
/// 用户在青龙脚本编辑器里提问，结果代码被写进浏览器抓包脚本，
/// 那是纯粹的破坏。所以每个编辑器挂上总线时都要自报身份，
/// AI 侧的工具要么用"当前活跃的那个"，要么显式点名，点名不匹配就直接报错。
enum EditorKind {
  /// 青龙面板脚本编辑器（可运行、有执行日志）。
  qinglongScript('青龙脚本编辑器', 'qinglong'),

  /// 浏览器抓包 hook 脚本编辑器。
  browserHook('浏览器抓包脚本编辑器', 'browser'),

  /// 文件管理器里打开的文件编辑器。
  shellFile('文件编辑器', 'file'),

  /// 面板配置文件编辑器（config.sh、auth.json 这些）。
  panelConfig('面板配置编辑器', 'config');

  const EditorKind(this.label, this.code);

  /// 人话名字，展示给用户。
  final String label;

  /// AI 工具参数里用的短名。
  final String code;

  static EditorKind? fromCode(String value) {
    final lower = value.trim().toLowerCase();
    for (final k in EditorKind.values) {
      if (k.code == lower || k.name.toLowerCase() == lower) return k;
    }
    return null;
  }
}

/// 一个挂在总线上的编辑器实例。
class EditorHandle {
  EditorHandle({
    required this.id,
    required this.kind,
    required this.title,
    required this.path,
    required this.controller,
    required this.editorKey,
    this.language,
    this.save,
    this.run,
    this.readLog,
    this.remove,
    this.readOnly = false,
  });

  final int id;
  final EditorKind kind;

  /// 展示用标题（文件名 / 脚本名）。
  final String title;

  /// 完整路径或等价标识（浏览器脚本用 `hook:<id>`）。
  final String path;
  final HighlightingCodeController controller;
  final GlobalKey<CodeEditorFieldState> editorKey;
  final String? language;

  /// 保存。返回给 AI 看的结果文字；为 null 表示这个编辑器不支持保存。
  final Future<String> Function()? save;

  /// 运行（只有青龙脚本编辑器有）。
  final Future<String> Function()? run;

  /// 取最近的执行日志（只有青龙脚本编辑器有）。
  final String Function()? readLog;

  /// 删除这个脚本/文件本身。
  final Future<String> Function()? remove;

  final bool readOnly;

  CodeEditorFieldState? get fieldState => editorKey.currentState;

  String get text => controller.text;

  int get lineCount => controller.text.split('\n').length;

  /// 一行摘要，给 AI 的提示词和悬浮窗标签用。
  String describe({bool active = false}) {
    final marks = <String>[
      '#$id',
      kind.label,
      title,
      '$lineCount 行',
      if (language != null) language!,
      if (readOnly) '只读',
      if (run != null) '可运行',
    ];
    return '${active ? '▶ ' : '  '}${marks.join(' · ')}';
  }
}

/// 一次可视化编辑的节奏参数。
class TypingPace {
  const TypingPace({
    this.tickMs = 26,
    this.targetMs = 1500,
    this.minChunk = 2,
    this.maxChunk = 160,
  });

  /// 每帧间隔。
  final int tickMs;

  /// 整段动画期望的总时长——文本越长每帧就打越多字，
  /// 不然改一个 8000 字符的文件要打两分钟。
  final int targetMs;
  final int minChunk;
  final int maxChunk;

  int chunkFor(int length) {
    final ticks = (targetMs / tickMs).ceil();
    final raw = (length / ticks).ceil();
    return raw.clamp(minChunk, maxChunk);
  }
}

/// 代码编辑器总线：谁开着、谁活跃、AI 怎么动它。
///
/// 这是"可视化反馈编辑"的核心：AI 不再把整段代码丢回聊天让用户复制粘贴，
/// 而是直接操作用户眼前那个编辑器的 controller——一段一段地打字、一段一段地删，
/// 光标跟着走，用户全程看得见。
class EditorBus extends ChangeNotifier {
  EditorBus._();

  static final EditorBus instance = EditorBus._();

  final Map<int, EditorHandle> _handles = {};
  int _seq = 0;
  int? _activeId;

  /// 正在进行的可视化编辑（同一时间只允许一个，防止两个工具调用互相打字）。
  bool _busy = false;

  bool get busy => _busy;

  List<EditorHandle> get handles =>
      _handles.values.toList()..sort((a, b) => a.id.compareTo(b.id));

  EditorHandle? get active {
    final id = _activeId;
    if (id != null) {
      final hit = _handles[id];
      if (hit != null) return hit;
    }
    // 活跃的那个被关掉了：退回最后打开的一个。
    final list = handles;
    return list.isEmpty ? null : list.last;
  }

  bool get hasEditor => _handles.isNotEmpty;

  /// 注册一个编辑器。返回分配到的 id，调用方要在 dispose 里 [unregister]。
  int register({
    required EditorKind kind,
    required String title,
    required String path,
    required HighlightingCodeController controller,
    required GlobalKey<CodeEditorFieldState> editorKey,
    String? language,
    Future<String> Function()? save,
    Future<String> Function()? run,
    String Function()? readLog,
    Future<String> Function()? remove,
    bool readOnly = false,
  }) {
    final id = ++_seq;
    _handles[id] = EditorHandle(
      id: id,
      kind: kind,
      title: title,
      path: path,
      controller: controller,
      editorKey: editorKey,
      language: language,
      save: save,
      run: run,
      readLog: readLog,
      remove: remove,
      readOnly: readOnly,
    );
    _activeId = id;
    // 注册往往发生在 build/initState 期间，直接 notify 会撞上
    // "setState() or markNeedsBuild() called during build"。
    scheduleMicrotask(notifyListeners);
    return id;
  }

  void unregister(int id) {
    if (_handles.remove(id) == null) return;
    if (_activeId == id) _activeId = null;
    scheduleMicrotask(notifyListeners);
  }

  /// 用户点了某个编辑器（或它刚被打开）：把它标成活跃目标。
  void touch(int id) {
    if (!_handles.containsKey(id) || _activeId == id) return;
    _activeId = id;
    scheduleMicrotask(notifyListeners);
  }

  /// 换标题（脚本改名、另存为）时同步一下展示。
  void retitle(int id, String title) {
    final old = _handles[id];
    if (old == null || old.title == title) return;
    _handles[id] = EditorHandle(
      id: id,
      kind: old.kind,
      title: title,
      path: old.path,
      controller: old.controller,
      editorKey: old.editorKey,
      language: old.language,
      save: old.save,
      run: old.run,
      readLog: old.readLog,
      remove: old.remove,
      readOnly: old.readOnly,
    );
    scheduleMicrotask(notifyListeners);
  }

  /// 解析 AI 给的目标。
  ///
  /// [target] 可以是：空（用活跃的）、`qinglong`/`browser`/`file`、或 `#3` 这样的 id。
  /// 解析不到就抛带清单的错误——宁可让 AI 看到"你要的编辑器没开"，
  /// 也不能默默改到另一个编辑器上。
  EditorHandle resolve(String? target) {
    final list = handles;
    if (list.isEmpty) {
      throw const EditorBusException(
        '现在没有打开任何代码编辑器。让用户先打开要改的那个编辑器（青龙脚本 / 浏览器抓包脚本 / 文件管理器里的文件 / 面板配置），再让我动手。',
      );
    }
    final raw = (target ?? '').trim();
    if (raw.isEmpty || raw == 'active' || raw == '当前') {
      final hit = active;
      if (hit == null) {
        throw const EditorBusException('没有活跃编辑器。');
      }
      return hit;
    }
    if (raw.startsWith('#')) {
      final id = int.tryParse(raw.substring(1));
      final hit = id == null ? null : _handles[id];
      if (hit == null) {
        throw EditorBusException('没有 id=$raw 的编辑器。当前打开的是：\n${listText()}');
      }
      return hit;
    }
    final id = int.tryParse(raw);
    if (id != null) {
      final hit = _handles[id];
      if (hit == null) {
        throw EditorBusException('没有 id=$id 的编辑器。当前打开的是：\n${listText()}');
      }
      return hit;
    }
    final kind = EditorKind.fromCode(raw);
    if (kind == null) {
      throw EditorBusException(
        'target 只能填 active / qinglong / browser / file / config / #id，收到的是「$raw」。当前打开的是：\n${listText()}',
      );
    }
    final matches = list.where((h) => h.kind == kind).toList();
    if (matches.isEmpty) {
      throw EditorBusException(
        '没有打开${kind.label}，不能往它里面写代码。当前打开的是：\n${listText()}',
      );
    }
    // 同类开了多个（比如连开两个文件）：用其中最后活跃的那个。
    if (matches.length > 1 && _activeId != null) {
      final activeHit = matches.where((h) => h.id == _activeId).toList();
      if (activeHit.isNotEmpty) return activeHit.first;
    }
    return matches.last;
  }

  /// 当前编辑器清单（给 AI 的提示词/工具返回）。
  String listText() {
    final list = handles;
    if (list.isEmpty) return '（没有打开任何编辑器）';
    final activeId = active?.id;
    return list.map((h) => h.describe(active: h.id == activeId)).join('\n');
  }

  // ------------------------------------------------------------- 可视化编辑

  /// 整篇替换：先把旧内容逐段删掉，再把新内容逐段打出来。
  Future<String> replaceAll(
    EditorHandle handle,
    String next, {
    TypingPace pace = const TypingPace(),
  }) async {
    _assertWritable(handle);
    return _stroke(handle, () async {
      await _deleteRange(handle, 0, handle.text.length, pace);
      await _typeAt(handle, 0, next, pace);
      return '已重写${handle.kind.label}「${handle.title}」，'
          '现在 ${next.split('\n').length} 行、${next.length} 字符。';
    });
  }

  /// 精确替换一段文本（就是 AI 最常用的"改这几行"）。
  Future<String> patch(
    EditorHandle handle, {
    required String oldText,
    required String newText,
    bool all = false,
    TypingPace pace = const TypingPace(),
  }) async {
    _assertWritable(handle);
    if (oldText.isEmpty) {
      throw const EditorBusException('old_text 不能为空；要整篇重写请用 editor_write。');
    }
    final text = handle.text;
    final first = text.indexOf(oldText);
    if (first < 0) {
      throw EditorBusException(
        '在${handle.kind.label}「${handle.title}」里找不到 old_text。'
        '先用 editor_read 读一遍当前内容（注意缩进和空格要一模一样），再改。',
      );
    }
    if (!all) {
      final second = text.indexOf(oldText, first + oldText.length);
      if (second >= 0) {
        throw const EditorBusException(
          'old_text 匹配到多处。要么把上下文写长一点让它唯一，要么传 all=true 全部替换。',
        );
      }
    }
    return _stroke(handle, () async {
      var count = 0;
      var searchFrom = 0;
      while (true) {
        final index = handle.text.indexOf(oldText, searchFrom);
        if (index < 0) break;
        await _deleteRange(handle, index, index + oldText.length, pace);
        await _typeAt(handle, index, newText, pace);
        count++;
        searchFrom = index + newText.length;
        if (!all) break;
      }
      final line = _lineOf(handle.text, first);
      return '已在${handle.kind.label}「${handle.title}」第 $line 行附近替换 $count 处。';
    });
  }

  /// 按**行号**替换：把 [from]..[to] 这几行整体换成 [text]。
  ///
  /// 为什么需要它：按原文匹配（[patch]）在"行内容彼此是前缀"的时候必然翻车——
  /// `// line 20` 同时也是 `// line 200` 的前缀，于是报"匹配到多处"，
  /// 模型换几个写法都过不去。行号是唯一的，改远处的某一行用这个最省事。
  Future<String> replaceLines(
    EditorHandle handle, {
    required int from,
    required int to,
    required String text,
    TypingPace pace = const TypingPace(),
  }) async {
    _assertWritable(handle);
    return _stroke(handle, () async {
      final lines = handle.text.split('\n');
      final start = from.clamp(1, lines.length);
      final end = to.clamp(start, lines.length);
      var offset = 0;
      for (var i = 0; i < start - 1; i++) {
        offset += lines[i].length + 1;
      }
      var tail = offset;
      for (var i = start - 1; i < end; i++) {
        tail += lines[i].length + (i == lines.length - 1 ? 0 : 1);
      }
      // 末行不带换行符，替换时也别把新内容后面多补一个。
      final keepNewline = end < lines.length;
      final payload = keepNewline && !text.endsWith('\n') ? '$text\n' : text;
      await _deleteRange(handle, offset, tail, pace);
      await _typeAt(handle, offset, payload, pace);
      return '已在${handle.kind.label}「${handle.title}」把第 $start'
          '${end == start ? '' : '-$end'} 行换成 '
          '${payload.split('\n').where((l) => l.isNotEmpty).length} 行新内容。';
    });
  }

  /// 在某一行前/后插入整段代码。[line] 从 1 开始；0 或负数表示插到最前面。
  Future<String> insertAtLine(
    EditorHandle handle, {
    required int line,
    required String text,
    bool after = true,
    TypingPace pace = const TypingPace(),
  }) async {
    _assertWritable(handle);
    return _stroke(handle, () async {
      final lines = handle.text.split('\n');
      final clamped = line.clamp(0, lines.length);
      var offset = 0;
      final target = after ? clamped : clamped - 1;
      for (var i = 0; i < target && i < lines.length; i++) {
        offset += lines[i].length + 1;
      }
      if (offset > handle.text.length) offset = handle.text.length;
      final payload = text.endsWith('\n') ? text : '$text\n';
      await _typeAt(handle, offset, payload, pace);
      return '已在${handle.kind.label}「${handle.title}」第 ${target + 1} 行处插入 '
          '${payload.split('\n').length - 1} 行。';
    });
  }

  /// 删掉一段行（含首尾）。
  Future<String> deleteLines(
    EditorHandle handle, {
    required int from,
    required int to,
    TypingPace pace = const TypingPace(),
  }) async {
    _assertWritable(handle);
    return _stroke(handle, () async {
      final lines = handle.text.split('\n');
      final start = from.clamp(1, lines.length);
      final end = to.clamp(start, lines.length);
      var offset = 0;
      for (var i = 0; i < start - 1; i++) {
        offset += lines[i].length + 1;
      }
      var length = 0;
      for (var i = start - 1; i <= end - 1; i++) {
        length += lines[i].length + 1;
      }
      final endOffset = (offset + length).clamp(0, handle.text.length);
      await _deleteRange(handle, offset, endOffset, pace);
      return '已删除${handle.kind.label}「${handle.title}」第 $start~$end 行。';
    });
  }

  /// 删掉一段指定文本。
  Future<String> deleteText(
    EditorHandle handle, {
    required String snippet,
    TypingPace pace = const TypingPace(),
  }) async {
    _assertWritable(handle);
    final index = handle.text.indexOf(snippet);
    if (index < 0) {
      throw EditorBusException(
          '找不到要删的这段文本（${handle.kind.label}「${handle.title}」）。');
    }
    return _stroke(handle, () async {
      await _deleteRange(handle, index, index + snippet.length, pace);
      return '已删除 ${snippet.length} 个字符。';
    });
  }

  void _assertWritable(EditorHandle handle) {
    if (handle.readOnly) {
      throw EditorBusException(
          '${handle.kind.label}「${handle.title}」是只读的，改不了。');
    }
  }

  Future<String> _guard(Future<String> Function() action) async {
    if (_busy) {
      throw const EditorBusException('上一处改动还在敲，等它打完再来（一次只改一处，用户才看得清）。');
    }
    _busy = true;
    notifyListeners();
    try {
      return await action();
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  /// 一段可视化编辑：抢焦点 + 整段只占一次撤销。
  ///
  /// 撤销必须是"一次撤掉 AI 的整段改动"。若按每次落值入栈，
  /// 一段动画有几十帧，用户得点几十次撤销才能回到原样。
  Future<String> _stroke(
    EditorHandle handle,
    Future<String> Function() body,
  ) {
    return _guard(() async {
      final field = handle.fieldState;
      field?.focus();
      field?.beginBatch();
      try {
        return await body();
      } finally {
        handle.fieldState?.endBatch();
      }
    });
  }

  /// 逐段删除 [start, end)。
  Future<void> _deleteRange(
    EditorHandle handle,
    int start,
    int end,
    TypingPace pace,
  ) async {
    final controller = handle.controller;
    var tail = end.clamp(0, controller.text.length);
    final head = start.clamp(0, tail);
    if (tail <= head) return;
    final chunk = pace.chunkFor(tail - head);
    while (tail > head) {
      final next = (tail - chunk) < head ? head : tail - chunk;
      final text = controller.text;
      final updated = text.substring(0, next) + text.substring(tail);
      _apply(handle, updated, next);
      tail = next;
      await Future<void>.delayed(Duration(milliseconds: pace.tickMs));
    }
  }

  /// 从 [offset] 起逐段打字。
  Future<void> _typeAt(
    EditorHandle handle,
    int offset,
    String payload,
    TypingPace pace,
  ) async {
    if (payload.isEmpty) return;
    final controller = handle.controller;
    final chunk = pace.chunkFor(payload.length);
    var typed = 0;
    final base = offset.clamp(0, controller.text.length);
    while (typed < payload.length) {
      var next = typed + chunk;
      if (next > payload.length) next = payload.length;
      // 最后一段只剩 1 个字符会触发 CodeController 的自动补全修饰器
      // （补右括号、自动缩进），把 AI 写好的代码改坏，所以并进上一段。
      if (payload.length - next == 1) next = payload.length;
      final piece = payload.substring(typed, next);
      final text = controller.text;
      final head = base + typed;
      final updated = text.substring(0, head) + piece + text.substring(head);
      _apply(handle, updated, head + piece.length);
      typed = next;
      await Future<void>.delayed(Duration(milliseconds: pace.tickMs));
    }
  }

  /// 落一次值并把光标滚进可见区。
  ///
  /// 关键细节：`CodeController` 在"长度正好 +1 且选区折叠"时会跑修饰器
  /// （自动缩进、补右括号）。AI 写的代码已经带好缩进和括号，再被补一遍就是语法错。
  /// 所以这里保证每次落值都不落在那个条件上。
  void _apply(EditorHandle handle, String text, int caret) {
    final controller = handle.controller;
    final delta = text.length - controller.text.length;
    if (delta == 1 && controller.selection.isCollapsed) {
      final len = controller.text.length;
      if (len > 0) {
        final start = (caret - 2).clamp(0, len - 1);
        controller.selection = TextSelection(
          baseOffset: start,
          extentOffset: start + 1,
        );
      } else {
        // 空文档里插一个字符：先多插一个空格（+2），再删掉（-1），
        // 两步都不满足修饰器条件。
        controller.value = TextEditingValue(
          text: '$text ',
          selection: TextSelection.collapsed(offset: caret),
        );
      }
    }
    controller.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(
        offset: caret.clamp(0, text.length),
      ),
    );
    handle.fieldState?.revealCursor();
  }

  static int _lineOf(String text, int offset) {
    var line = 1;
    for (var i = 0; i < offset && i < text.length; i++) {
      if (text.codeUnitAt(i) == 10) line++;
    }
    return line;
  }
}

class EditorBusException implements Exception {
  const EditorBusException(this.message);

  final String message;

  @override
  String toString() => message;
}
