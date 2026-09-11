import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../shared/float_stack.dart';
import '../models/agent_task_plan.dart';
import '../models/canvas_window.dart';
import '../models/quick_ask.dart';

/// 从任意页面投递给 AI 的上下文片段。
class AiContextChip {
  const AiContextChip({
    required this.label,
    required this.content,
    this.path,
    this.source = '',
    this.language,
    this.key,
    this.readOnly = false,
    this.sticky = false,
    this.live,
  });

  /// 展示在输入框上方的短标签，例如「日志 · 任务3」。
  final String label;

  /// 真正拼进提问里的正文。仅在附件没有本地路径时才会把内容塞进上下文。
  final String content;

  /// 附件在本地 Debian 里的路径。非空时上下文只给路径，AI 自己调
  /// shell_read_file / shell_read_range 读完整文件，不再把内容塞进 prompt。
  final String? path;

  /// 来源模块，写进提示词让 AI 知道用户当时在看什么。
  final String source;

  /// 代码语言（脚本片段用），便于 AI 正确理解。
  final String? language;

  /// 身份标识。页面自动附带的上下文用它去重和撤下；
  /// 手动「问 AI」推来的片段不需要（留空）。
  final String? key;

  /// 只读上下文：日志这类东西给 AI 看是为了分析，写回去没有意义。
  /// 提示词里会明说，免得它去尝试改日志文件。
  final bool readOnly;

  /// 发送后是否保留。
  ///
  /// 页面自动附带的上下文应该跟着页面走，而不是发一次就掉：用户在同一个
  /// 日志页问三句话，三句都该带着这份日志。用户点 X 撤掉、或离开页面才移除。
  final bool sticky;

  /// 取最新内容。日志一直在滚，发送时该带当下的内容而不是打开那一瞬的。
  final String Function()? live;

  /// 当前有效内容。
  String get effectiveContent {
    final builder = live;
    if (builder == null) return content;
    try {
      final text = builder();
      return text.isEmpty ? content : text;
    } catch (_) {
      return content;
    }
  }

  /// 拼成提示词里的一段。
  String toPromptBlock() {
    final head = source.isEmpty ? label : '$label（来自$source）';
    if (path != null && path!.trim().isNotEmpty) {
      return '--- $head ---\n'
          '附件路径：$path\n'
          '（内容未嵌入上下文，请先用 shell_read_file 或 shell_read_range 读取完整附件，再基于内容回答）';
    }
    final fence = language == null || language!.isEmpty ? '' : language!;
    final note = readOnly ? '\n（只读：用户此刻正在看的内容，只用来分析，不要尝试改写它）' : '';
    return '--- $head ---$note\n```$fence\n${_clip(effectiveContent)}\n```';
  }

  static String _clip(String text, {int max = 6000}) {
    final trimmed = text.trim();
    if (trimmed.length <= max) return trimmed;
    return '${trimmed.substring(0, max)}\n…（已截断，共 ${trimmed.length} 字符）';
  }
}

class AiDockState {
  const AiDockState({
    this.visible = true,
    this.expanded = false,
    this.dx = 1,
    this.dy = 0.62,
    this.wx = 0.03,
    this.wy = 0.56,
    this.ww = 1,
    this.wh = 0.36,
    this.chips = const [],
    this.draft = '',
    this.unread = 0,
    this.canvasWindows = const [],
    this.quickOpen = false,
    this.quickDraft = '',
    this.quickBusy = false,
    this.quickExpand = false,
    this.quickFiles = const [],
    this.quickResults = const [],
  });

  /// 窗口尺寸下限（占屏比例）：再小就装不下输入框了。
  static const minW = 0.52;
  static const minH = 0.22;
  static const maxH = 0.86;

  /// 悬浮球是否显示（设置里可关）。
  final bool visible;

  /// 面板是否展开。
  final bool expanded;

  /// 悬浮球位置比例（0~1），便于旋转/分屏后仍然合理。
  final double dx;
  final double dy;

  /// 悬浮窗几何：左上角位置与宽高，全部按屏幕比例存，
  /// 这样横竖屏切换、分屏、换设备都不会跑到屏幕外。
  final double wx;
  final double wy;
  final double ww;
  final double wh;

  /// 待发送的上下文片段。
  final List<AiContextChip> chips;

  /// 输入草稿（收起面板不丢）。
  final String draft;

  /// 面板收起期间新到的回复数。
  final int unread;

  /// 悬浮模式下正在显示的互动画布窗口，**不限个数**。
  ///
  /// 悬浮窗是画在路由 Navigator **之上**的，所以底部弹窗式的画布会被它盖住
  /// ——用户看到的就是"AI 说弹了个东西，但屏幕上什么都没有"。
  /// 悬浮模式下改成同层的浮动窗口，才盖得住、点得到。
  ///
  /// 多窗口是为了"一个当游戏画面、一个当操作面板、一个当成绩板"这类布局：
  /// 每个窗口独立拖拽缩放，同名窗口再发一次就是原地更新内容。
  final List<CanvasWindow> canvasWindows;

  /// 快问输入条是否伸出来了（长按悬浮球切换）。
  ///
  /// 展开时悬浮球本身变成发送按钮，再长按一次收回去。
  final bool quickOpen;

  /// 快问输入框里的草稿。放在 state 里而不是只放在 controller 里：
  /// 转屏、悬浮层重建都不该把用户打了一半的问题吃掉。
  final String quickDraft;

  /// 这一轮是快问发起的、正在跑。
  ///
  /// 单独一个标记而不是复用 chat.isLoading：AI 页里正常聊天时也 isLoading，
  /// 那时候输入条不该被锁住变成"状态显示器"。
  final bool quickBusy;

  /// 快问上面的附件行是否展开。
  ///
  /// 箭头不再负责"收回输入条"——收回只能靠长按发送键。箭头垂直方向：
  /// 收着朝上（点一下展开附件行），展开朝下（点一下收回去）。
  final bool quickExpand;

  /// 快问附件。只存路径/文件名，不读正文（AI 自己调工具读）。
  final List<QuickFileRef> quickFiles;

  /// 快问的结果窗，可以同时开好几个（问三件事就摊三张）。
  final List<QuickResultWindow> quickResults;

  AiDockState copyWith({
    bool? visible,
    bool? expanded,
    double? dx,
    double? dy,
    double? wx,
    double? wy,
    double? ww,
    double? wh,
    List<AiContextChip>? chips,
    String? draft,
    int? unread,
    List<CanvasWindow>? canvasWindows,
    bool? quickOpen,
    String? quickDraft,
    bool? quickBusy,
    bool? quickExpand,
    List<QuickFileRef>? quickFiles,
    List<QuickResultWindow>? quickResults,
  }) {
    return AiDockState(
      visible: visible ?? this.visible,
      expanded: expanded ?? this.expanded,
      dx: dx ?? this.dx,
      dy: dy ?? this.dy,
      wx: wx ?? this.wx,
      wy: wy ?? this.wy,
      ww: ww ?? this.ww,
      wh: wh ?? this.wh,
      chips: chips ?? this.chips,
      draft: draft ?? this.draft,
      unread: unread ?? this.unread,
      canvasWindows: canvasWindows ?? this.canvasWindows,
      quickOpen: quickOpen ?? this.quickOpen,
      quickDraft: quickDraft ?? this.quickDraft,
      quickBusy: quickBusy ?? this.quickBusy,
      quickExpand: quickExpand ?? this.quickExpand,
      quickFiles: quickFiles ?? this.quickFiles,
      quickResults: quickResults ?? this.quickResults,
    );
  }

  Map<String, dynamic> toLayoutJson() => {
        'dx': dx,
        'dy': dy,
        'wx': wx,
        'wy': wy,
        'ww': ww,
        'wh': wh,
        'visible': visible,
      };
}

class AiDockNotifier extends Notifier<AiDockState> {
  static const _layoutKey = 'ai_dock_layout_v1';

  /// 被用户 X 掉的自动附件 key。
  ///
  /// 日志页在轮询刷新，每次刷新都会重新 attach 一次；没有这份记忆的话，
  /// 用户点掉的附件下一秒就自己回来了。只在这次「停留在该页面」期间有效，
  /// 离开页面（detach）或手动重新「发给 AI」（push）都会解除。
  final Set<String> _dismissed = <String>{};

  @override
  AiDockState build() {
    Future.microtask(_restoreLayout);
    return const AiDockState();
  }

  Future<void> _restoreLayout() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_layoutKey);
      if (raw == null || raw.isEmpty) return;
      final j = jsonDecode(raw);
      if (j is! Map<String, dynamic>) return;
      double d(String k, double fallback) =>
          (j[k] as num?)?.toDouble() ?? fallback;
      state = state.copyWith(
        dx: d('dx', state.dx),
        dy: d('dy', state.dy),
        wx: d('wx', state.wx),
        wy: d('wy', state.wy),
        ww: d('ww', state.ww),
        wh: d('wh', state.wh),
        visible: j['visible'] as bool? ?? state.visible,
      );
    } catch (_) {
      // 布局坏了就用默认值，不值得打扰用户。
    }
  }

  void _saveLayout() {
    final snapshot = jsonEncode(state.toLayoutJson());
    // 拖动过程中会频繁调用，这里不 await，交给 prefs 自己排队。
    SharedPreferences.getInstance()
        .then((p) => p.setString(_layoutKey, snapshot))
        .catchError((_) => false);
  }

  /// 按增量移动悬浮窗（比例增量），宽高不变。
  ///
  /// 必须是"增量"而不是"目标位置"：一次拖动里 onPanUpdate 会连发多帧，
  /// 而 widget 只在下一帧才拿到新 state。用目标位置的话，同一帧内的后续
  /// 事件都基于同一个旧起点计算，位移会被吞掉——表现就是窗口几乎不动。
  void moveWindowBy(double dxFrac, double dyFrac) {
    state = state.copyWith(
      wx: (state.wx + dxFrac).clamp(0.0, 1.0 - state.ww),
      wy: (state.wy + dyFrac).clamp(0.0, 1.0 - state.wh),
    );
  }

  /// 按边拖动缩放：四个 delta 都是"占屏比例"的增量，只有被拖的边非零。
  ///
  /// 用边界（left/top/right/bottom）而不是"位置 + 尺寸"来算，
  /// 拖左边时右边才不会跟着跑；碰到最小尺寸就停住，不会翻面。
  void resizeEdge({
    double dLeft = 0,
    double dTop = 0,
    double dRight = 0,
    double dBottom = 0,
  }) {
    var l = state.wx;
    var t = state.wy;
    var r = state.wx + state.ww;
    var b = state.wy + state.wh;

    if (dLeft != 0) l = (l + dLeft).clamp(0.0, r - AiDockState.minW);
    if (dRight != 0) r = (r + dRight).clamp(l + AiDockState.minW, 1.0);
    if (dTop != 0) t = (t + dTop).clamp(0.0, b - AiDockState.minH);
    if (dBottom != 0) {
      b = (b + dBottom).clamp(t + AiDockState.minH, 1.0);
      if (b - t > AiDockState.maxH) b = t + AiDockState.maxH;
    }
    if (dTop != 0 && b - t > AiDockState.maxH) t = b - AiDockState.maxH;

    state = state.copyWith(wx: l, wy: t, ww: r - l, wh: b - t);
  }

  /// 拖动/缩放结束时落盘。
  void commitLayout() => _saveLayout();

  void show() {
    state = state.copyWith(visible: true);
    _saveLayout();
  }

  void hide() {
    // 球都藏了，伸出去的输入条更不该留着（它是挂在球身上的）。
    state = state.copyWith(
      visible: false,
      expanded: false,
      quickOpen: false,
      quickExpand: false,
    );
    _saveLayout();
  }

  void toggleVisible() {
    state = state.copyWith(
      visible: !state.visible,
      expanded: false,
      quickOpen: false,
      quickExpand: false,
    );
    _saveLayout();
  }

  // ---------------------------------------------------------------- 快问

  /// 长按悬浮球：伸出输入条 / 收回去。
  void toggleQuickAsk() {
    if (state.quickOpen) {
      closeQuickAsk();
      return;
    }
    FloatStack.instance.raise(FloatStack.ai);
    state = state.copyWith(quickOpen: true, visible: true);
  }

  /// 收回输入条。正在跑的那一轮不受影响——它跑完照样弹结果窗。
  void closeQuickAsk() => state = state.copyWith(quickOpen: false);

  void setQuickDraft(String text) {
    if (text == state.quickDraft) return;
    state = state.copyWith(quickDraft: text);
  }

  void setQuickBusy(bool busy) {
    if (busy == state.quickBusy) return;
    state = state.copyWith(quickBusy: busy);
  }

  /// 展开/收起附件行。注意：这只影响"输入框上面那一行"，不收起输入条。
  void toggleQuickExpand() {
    state = state.copyWith(quickExpand: !state.quickExpand);
  }

  /// 往快问里挂一个附件。只记路径，不读正文。
  void addQuickFile({required String path, required String name}) {
    if (state.quickFiles.any((f) => f.path == path)) return;
    state = state.copyWith(
      quickFiles: [...state.quickFiles, QuickFileRef(path: path, name: name)],
    );
  }

  /// 撤下某个快问附件。
  void removeQuickFile(String path) {
    if (!state.quickFiles.any((f) => f.path == path)) return;
    state = state.copyWith(
      quickFiles: [
        for (final f in state.quickFiles)
          if (f.path != path) f,
      ],
    );
  }

  void clearQuickFiles() {
    if (state.quickFiles.isEmpty) return;
    state = state.copyWith(quickFiles: const []);
  }

  /// 弹一个结果窗。
  String pushQuickResult({
    required String question,
    required String answer,
    bool failed = false,
  }) {
    // 同一微秒里连着弹两个（排队的两句话几乎同时收尾）会撞 id，
    // 撞了就变成"关一个关掉两个"。所以撞了就往后挪一位。
    final stamp = DateTime.now().microsecondsSinceEpoch;
    var id = 'q$stamp';
    var seq = 1;
    while (state.quickResults.any((w) => w.id == id)) {
      id = 'q$stamp-$seq';
      seq++;
    }
    final geo = QuickResultWindow.layoutFor(state.quickResults.length);
    FloatStack.instance.raise(FloatStack.ai);
    state = state.copyWith(
      quickResults: [
        ...state.quickResults,
        QuickResultWindow(
          id: id,
          question: question,
          answer: answer,
          failed: failed,
          x: geo.x,
          y: geo.y,
          w: geo.w,
          h: geo.h,
        ),
      ],
      // 结果窗是这次提问的产物，不该被"悬浮球已隐藏"连带藏掉。
      visible: true,
    );
    return id;
  }

  bool hasQuickResult(String id) => state.quickResults.any((w) => w.id == id);

  /// 更新一个已经弹出来的（正文）悬浮窗。
  void updateQuickResult(
    String id, {
    String? question,
    String? answer,
    bool? failed,
  }) {
    final index = state.quickResults.indexWhere((w) => w.id == id);
    if (index < 0) return;
    final windows = [...state.quickResults];
    windows[index] = windows[index].copyWith(
      question: question,
      answer: answer,
      failed: failed,
    );
    state = state.copyWith(quickResults: windows);
  }

  /// 有就更新，没有就新建。返回最终生效的窗口 id。
  String upsertQuickResult({
    String? id,
    required String question,
    required String answer,
    bool failed = false,
  }) {
    if (id != null && hasQuickResult(id)) {
      updateQuickResult(
        id,
        question: question,
        answer: answer,
        failed: failed,
      );
      return id;
    }
    return pushQuickResult(
      question: question,
      answer: answer,
      failed: failed,
    );
  }

  void closeQuickResult(String id) {
    if (!state.quickResults.any((w) => w.id == id)) return;
    state = state.copyWith(
      quickResults: [
        for (final w in state.quickResults)
          if (w.id != id) w,
      ],
    );
  }

  void closeAllQuickResults() {
    if (state.quickResults.isEmpty) return;
    state = state.copyWith(quickResults: const []);
  }

  /// 把某个结果窗抬到最上面：叠着时点哪个哪个在上。
  void raiseQuickResult(String id) {
    final index = state.quickResults.indexWhere((w) => w.id == id);
    if (index < 0 || index == state.quickResults.length - 1) return;
    final windows = [...state.quickResults];
    windows.add(windows.removeAt(index));
    state = state.copyWith(quickResults: windows);
  }

  /// 按增量拖动结果窗（理由同 [moveWindowBy]：一帧多事件时目标位置会丢位移）。
  void moveQuickResultBy(String id, double dxFrac, double dyFrac) {
    _updateQuickResult(
      id,
      (w) => w.copyWith(
        x: (w.x + dxFrac).clamp(0.0, 1.0 - w.w),
        y: (w.y + dyFrac).clamp(0.0, 1.0 - w.h),
      ),
    );
  }

  void resizeQuickResult(
    String id, {
    double dLeft = 0,
    double dTop = 0,
    double dRight = 0,
    double dBottom = 0,
  }) {
    _updateQuickResult(id, (w) {
      var l = w.x;
      var t = w.y;
      var r = w.x + w.w;
      var b = w.y + w.h;
      if (dLeft != 0) l = (l + dLeft).clamp(0.0, r - QuickResultWindow.minW);
      if (dRight != 0) r = (r + dRight).clamp(l + QuickResultWindow.minW, 1.0);
      if (dTop != 0) t = (t + dTop).clamp(0.0, b - QuickResultWindow.minH);
      if (dBottom != 0) {
        b = (b + dBottom).clamp(t + QuickResultWindow.minH, 1.0);
      }
      return w.copyWith(x: l, y: t, w: r - l, h: b - t);
    });
  }

  void _updateQuickResult(
    String id,
    QuickResultWindow Function(QuickResultWindow) update,
  ) {
    final index = state.quickResults.indexWhere((w) => w.id == id);
    if (index < 0) return;
    final windows = [...state.quickResults];
    windows[index] = update(windows[index]);
    state = state.copyWith(quickResults: windows);
  }

  void open() {
    // 刚弹出来的窗口默认在最前：否则它可能生在浏览器底下，
    // 用户点了悬浮球却像什么都没发生。
    FloatStack.instance.raise(FloatStack.ai);
    // 完整聊天窗一开，快问条就没必要了（它本来就是"不开窗也能问一句"）。
    state = state.copyWith(
      expanded: true,
      unread: 0,
      quickOpen: false,
      quickExpand: false,
    );
  }

  void close() => state = state.copyWith(expanded: false);

  void toggle() => state.expanded ? close() : open();

  /// 悬浮模式下把画布显示成浮动窗口。
  ///
  /// 同名窗口原地换内容并保留用户拖出来的几何——AI 每帧更新成绩板时，
  /// 窗口不该跳回默认位置。不同名（或没给名字）就新开一个，个数不限。
  void showCanvas(AiCanvas canvas) {
    FloatStack.instance.raise(FloatStack.ai);
    final name = canvas.window.isNotEmpty ? canvas.window : canvas.id;
    final existing = state.canvasWindows.indexWhere((w) => w.name == name);
    final windows = [...state.canvasWindows];
    if (existing >= 0) {
      final old = windows[existing];
      // AI 明确给了位置就照它说的挪，否则保留用户拖过的几何。
      final explicit = canvas.rect != null || canvas.position.isNotEmpty;
      final geo = CanvasWindow.layoutFor(canvas, existing);
      windows[existing] = old.copyWith(
        canvas: canvas,
        chromeless: canvas.chromeless,
        x: explicit ? geo.x : old.x,
        y: explicit ? geo.y : old.y,
        w: explicit ? geo.w : old.w,
        h: explicit ? geo.h : old.h,
      );
    } else {
      final geo = CanvasWindow.layoutFor(canvas, windows.length);
      windows.add(
        CanvasWindow(
          canvas: canvas,
          name: name,
          x: geo.x,
          y: geo.y,
          w: geo.w,
          h: geo.h,
          chromeless: canvas.chromeless,
        ),
      );
    }
    state = state.copyWith(
      canvasWindows: windows,
      visible: true,
      // 快问模式下画布走快问自己的浮动窗，不展开完整悬浮窗；
      // 非快问模式保持原来的行为（完整悬浮窗里弹画布）。
      expanded: state.quickOpen || state.quickBusy ? state.expanded : true,
    );
  }

  void closeCanvas(String name) {
    state = state.copyWith(
      canvasWindows: [
        for (final w in state.canvasWindows)
          if (w.name != name) w,
      ],
    );
  }

  void closeAllCanvases() => state = state.copyWith(canvasWindows: const []);

  /// 把某个窗口抬到同层最上面：多窗口叠着时点哪个哪个在上。
  void raiseCanvas(String name) {
    final index = state.canvasWindows.indexWhere((w) => w.name == name);
    if (index < 0 || index == state.canvasWindows.length - 1) return;
    final windows = [...state.canvasWindows];
    windows.add(windows.removeAt(index));
    state = state.copyWith(canvasWindows: windows);
  }

  void moveCanvasBy(String name, double dxFrac, double dyFrac) {
    _updateCanvas(name, (w) {
      return w.copyWith(
        x: (w.x + dxFrac).clamp(0.0, 1.0 - w.w),
        y: (w.y + dyFrac).clamp(0.0, 1.0 - w.h),
      );
    });
  }

  /// 画布窗口按边缩放。逻辑与聊天窗一致：用边界算，拖左边右边不跟着跑。
  void resizeCanvas(
    String name, {
    double dLeft = 0,
    double dTop = 0,
    double dRight = 0,
    double dBottom = 0,
  }) {
    _updateCanvas(name, (w) {
      var l = w.x;
      var t = w.y;
      var r = w.x + w.w;
      var b = w.y + w.h;
      if (dLeft != 0) l = (l + dLeft).clamp(0.0, r - CanvasWindow.minW);
      if (dRight != 0) r = (r + dRight).clamp(l + CanvasWindow.minW, 1.0);
      if (dTop != 0) t = (t + dTop).clamp(0.0, b - CanvasWindow.minH);
      if (dBottom != 0) b = (b + dBottom).clamp(t + CanvasWindow.minH, 1.0);
      return w.copyWith(x: l, y: t, w: r - l, h: b - t);
    });
  }

  void _updateCanvas(String name, CanvasWindow Function(CanvasWindow) update) {
    final index = state.canvasWindows.indexWhere((w) => w.name == name);
    if (index < 0) return;
    final windows = [...state.canvasWindows];
    windows[index] = update(windows[index]);
    state = state.copyWith(canvasWindows: windows);
  }

  void moveTo(double dx, double dy) => state = state.copyWith(
        dx: dx.clamp(0.0, 1.0),
        dy: dy.clamp(0.0, 1.0),
      );

  void setDraft(String text) => state = state.copyWith(draft: text);

  void markUnread() {
    if (state.expanded) return;
    state = state.copyWith(unread: state.unread + 1);
  }

  /// 投递上下文并打开面板——各页面「问 AI」按钮走这里。
  void push(AiContextChip chip, {String? draft, bool open = true}) {
    final key = chip.key;
    // 同 key 的旧片段原地替换：切换日志文件时不该攒出一串同名附件。
    final chips = key == null || key.isEmpty
        ? [...state.chips, chip]
        : [
            for (final c in state.chips)
              if (c.key != key) c,
            chip,
          ];
    // 手动点「发给 AI」= 明确要带上，撤销之前那次 X。
    if (key != null && key.isNotEmpty) _dismissed.remove(key);
    if (open) FloatStack.instance.raise(FloatStack.ai);
    state = state.copyWith(
      chips: chips,
      draft: draft ?? state.draft,
      visible: true,
      expanded: open ? true : state.expanded,
      unread: 0,
    );
  }

  /// 页面自动附带的上下文：只挂上去，不弹面板、不抢焦点。
  ///
  /// 用户打开一个日志页并不代表他要提问，所以这里绝不能把悬浮窗展开——
  /// 那会挡住他正在看的内容。等他自己点开悬浮窗，附件已经在输入框上方了。
  void attach(AiContextChip chip) {
    final key = chip.key;
    if (key == null || key.isEmpty) return;
    // 用户 X 掉过就别再贴上来。日志页每几百毫秒轮询一次，
    // 少了这一句，「取消附带」会在下一次刷新时原地复活。
    if (_dismissed.contains(key)) return;
    final existing = state.chips.where((c) => c.key == key).toList();
    // 同一个页面重复 attach（轮询刷新、rebuild）不该反复改 state。
    // 带 live 的附件内容在发送那一刻才取，所以内容变了也不用重挂——
    // 否则日志一直在滚，dock 就跟着一秒重建好几次。
    if (existing.length == 1 &&
        existing.first.label == chip.label &&
        (chip.live != null || existing.first.content == chip.content)) {
      return;
    }
    state = state.copyWith(
      chips: [
        for (final c in state.chips)
          if (c.key != key) c,
        chip,
      ],
    );
  }

  /// 撤下某个自动附带的上下文（离开页面时调用）。
  void detach(String key) {
    if (key.isEmpty) return;
    // 离开页面就把「取消」的记忆一起清掉：下次再打开这份日志，
    // 是一次新的选择，不该背着上次的决定。
    _dismissed.remove(key);
    if (!state.chips.any((c) => c.key == key)) return;
    state = state.copyWith(
      chips: [
        for (final c in state.chips)
          if (c.key != key) c,
      ],
    );
  }

  void removeChip(int index) {
    if (index < 0 || index >= state.chips.length) return;
    final gone = state.chips[index];
    // 页面自动挂的附件被 X 掉 = 「这次别带它」，记下来（见 attach）。
    final key = gone.key;
    if (key != null && key.isNotEmpty && gone.sticky) _dismissed.add(key);
    final next = [...state.chips]..removeAt(index);
    state = state.copyWith(chips: next);
  }

  /// 发送后清理：手动推来的片段发一次就掉，
  /// 页面自动附带的（sticky）留着——用户还在那一页上，下一句话照样要带。
  void consumeChips() {
    final kept = [
      for (final c in state.chips)
        if (c.sticky) c
    ];
    if (kept.length == state.chips.length) return;
    state = state.copyWith(chips: kept);
  }

  void clearChips() => state = state.copyWith(chips: const []);

  /// 把本地文件挂成附件。返回附件标签（供 toast 用），失败返回 null。
  ///
  /// 走 push 而不是 attach：这是用户主动的动作，附件该立刻出现在输入框上方，
  /// 也不该被"取消过一次"的记忆挡住。发一次就掉（非 sticky）——附件属于
  /// 这一次提问，下一句话再需要就再挑一次，否则会悄悄跟着后面所有对话。
  String pushFile({
    required String path,
    required String name,
    required String content,
    String? language,
    bool truncated = false,
    bool open = true,
  }) {
    // 附件只给路径，不再把正文塞进上下文（也永远不会“截断”）。
    // AI 需要内容时会自己 shell_read_file 读完整文件。
    push(
      AiContextChip(
        label: name,
        content: '',
        path: path,
        source: '本地文件',
        key: 'file:$path',
      ),
      // 在 AI 页加附件时 open=false：那里本来就在聊天界面，
      // 把悬浮窗也弹出来只会挡住它自己。
      open: open,
    );
    return name;
  }

  /// 读剪贴板作为上下文。返回是否成功。
  Future<bool> pushClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim() ?? '';
    if (text.isEmpty) return false;
    push(
      AiContextChip(
        label: '剪贴板 ${text.length} 字符',
        content: text,
        source: '系统剪贴板',
      ),
      open: true,
    );
    return true;
  }

  /// 把片段与用户输入拼成最终提问。
  String composePrompt(String question) {
    if (state.chips.isEmpty) return question;
    final blocks = state.chips.map((c) => c.toPromptBlock()).join('\n\n');
    final q = question.trim();
    return [
      if (q.isNotEmpty) q else '看看下面这些内容，帮我分析并给出可执行的下一步。',
      '',
      blocks,
    ].join('\n');
  }
}

final aiDockProvider =
    NotifierProvider<AiDockNotifier, AiDockState>(AiDockNotifier.new);
