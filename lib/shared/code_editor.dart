import 'package:code_text_field/code_text_field.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_highlight/themes/monokai-sublime.dart';
import 'mono_text.dart';

/// 支持双指缩放、撤销/重做、查找跳转和换行开关的代码编辑器。
///
/// 缩放通过调整字体大小实现，保持 CodeField 自身的滚动/编辑能力；
/// 双指张开/捏合时字体大小在 [minFontSize]~[maxFontSize] 之间变化，单击拖动不受影响。
class CodeEditorField extends StatefulWidget {
  const CodeEditorField({
    super.key,
    required this.controller,
    required this.path,
    this.onChanged,
    this.padding = const EdgeInsets.all(12),
    this.initialFontSize = 13,
    this.minFontSize = 8,
    this.maxFontSize = 32,
    this.wrap = false,
    this.readOnly = false,
    this.enabled = true,
    this.focusNode,
  });

  final CodeController controller;
  final String path;
  final ValueChanged<String>? onChanged;
  final EdgeInsets padding;

  /// 初始字号。
  final double initialFontSize;

  /// 双指缩放/按钮调整的字号下限。
  final double minFontSize;

  /// 双指缩放/按钮调整的字号上限。
  final double maxFontSize;

  /// 是否自动换行。
  final bool wrap;

  final bool readOnly;
  final bool enabled;
  final FocusNode? focusNode;

  @override
  State<CodeEditorField> createState() => CodeEditorFieldState();
}

/// [CodeEditorField] 对应的公开 State，供外层通过 GlobalKey 调用
/// 撤销/重做、字号调整、换行开关与查找跳转等能力。
class CodeEditorFieldState extends State<CodeEditorField> {
  late double _fontSize;

  /// 双指缩放中：期间显示字号提示，松手后隐藏。
  bool _pinching = false;
  double _pinchLabel = 0;

  /// 手动跟踪双指距离：不占用手势竞技场，单指滑动/编辑完全留给编辑器。
  final Map<int, Offset> _activePointers = {};
  double _pinchStartDistance = 0;
  double _pinchBaseFontSize = 0;
  late bool _wrap;

  final List<String> _undoStack = [];
  final List<String> _redoStack = [];
  late String _lastKnownText;
  bool _applyingHistory = false;

  /// AI 正在做可视化编辑（整段动画合成一次撤销）。
  bool _batching = false;

  /// 自己持有的焦点节点。
  ///
  /// 必须有一个能拿到的 FocusNode：AI 可视化改代码时要把光标滚进可见区，
  /// 而那个能力（`EditableTextState.bringIntoView`）只能顺着焦点节点的
  /// context 往上找。外部传了就用外部的，没传就自己造一个。
  FocusNode? _ownedFocusNode;

  FocusNode get _focusNode =>
      widget.focusNode ?? (_ownedFocusNode ??= FocusNode());

  @override
  void initState() {
    super.initState();
    _fontSize = widget.initialFontSize;
    _wrap = widget.wrap;
    _lastKnownText = widget.controller.text;
    widget.controller.addListener(_onControllerChanged);
  }

  @override
  void didUpdateWidget(covariant CodeEditorField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onControllerChanged);
      widget.controller.addListener(_onControllerChanged);
      _lastKnownText = widget.controller.text;
      _undoStack.clear();
      _redoStack.clear();
    }
    if (oldWidget.wrap != widget.wrap) {
      _wrap = widget.wrap;
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerChanged);
    _ownedFocusNode?.dispose();
    super.dispose();
  }

  void _onControllerChanged() {
    if (_applyingHistory) {
      _lastKnownText = widget.controller.text;
      return;
    }
    final old = _lastKnownText;
    final current = widget.controller.text;
    if (old == current) return;

    // AI 可视化编辑期间不逐段入栈：那一段动画有几十次落值，
    // 否则用户想撤销一次 AI 改动得点几十下。整段只在开始时记一个快照。
    if (_batching) {
      _lastKnownText = current;
      return;
    }
    _undoStack.add(old);
    if (_undoStack.length > 200) {
      _undoStack.removeAt(0);
    }
    _redoStack.clear();
    _lastKnownText = current;
  }

  /// AI 开始一段可视化编辑：先存一个快照，整段动画只算一次撤销。
  void beginBatch() {
    if (_batching) return;
    _undoStack.add(widget.controller.text);
    if (_undoStack.length > 200) _undoStack.removeAt(0);
    _redoStack.clear();
    _batching = true;
  }

  /// 结束一段可视化编辑。
  void endBatch() {
    _batching = false;
    _lastKnownText = widget.controller.text;
  }

  void _onPointerDown(PointerDownEvent event) {
    _activePointers[event.pointer] = event.localPosition;
    if (_activePointers.length == 2) {
      _pinchBaseFontSize = _fontSize;
      final pts = _activePointers.values.toList();
      _pinchStartDistance = (pts[1] - pts[0]).distance;
      _pinching = true;
    }
    setState(() {});
  }

  void _onPointerMove(PointerMoveEvent event) {
    if (!_activePointers.containsKey(event.pointer)) return;
    _activePointers[event.pointer] = event.localPosition;
    if (_activePointers.length < 2 || _pinchStartDistance <= 0) return;
    final pts = _activePointers.values.toList();
    final distance = (pts[1] - pts[0]).distance;
    if (distance <= 0) return;
    final raw = (_pinchBaseFontSize * (distance / _pinchStartDistance))
        .clamp(widget.minFontSize, widget.maxFontSize)
        .toDouble();
    // 双指缩放每帧都会来事件，而改字号会让整个代码域重新分行、重新着色。
    // 大文件下逐帧重排就是卡的根源，所以按 1px 量化：一次手势最多十来次重排。
    final stepped = raw.roundToDouble();
    _pinchLabel = stepped;
    if (stepped == _fontSize) return;
    setState(() => _fontSize = stepped);
  }

  void _onPointerEnd(PointerEvent event) {
    _activePointers.remove(event.pointer);
    if (_activePointers.length < 2) _pinching = false;
    setState(() {});
  }

  /// 撤销最近一次编辑。
  void undo() {
    if (_undoStack.isEmpty) return;
    _applyingHistory = true;
    try {
      final current = widget.controller.text;
      final previous = _undoStack.removeLast();
      _redoStack.add(current);
      widget.controller.text = previous;
      widget.controller.selection = TextSelection.collapsed(
        offset: previous.length,
      );
    } finally {
      _applyingHistory = false;
      _lastKnownText = widget.controller.text;
    }
  }

  /// 重做最近一次撤销。
  void redo() {
    if (_redoStack.isEmpty) return;
    _applyingHistory = true;
    try {
      final current = widget.controller.text;
      final next = _redoStack.removeLast();
      _undoStack.add(current);
      widget.controller.text = next;
      widget.controller.selection = TextSelection.collapsed(
        offset: next.length,
      );
    } finally {
      _applyingHistory = false;
      _lastKnownText = widget.controller.text;
    }
  }

  bool get canUndo => _undoStack.isNotEmpty;

  bool get canRedo => _redoStack.isNotEmpty;

  /// 放大字号。
  void increaseFontSize() {
    _setFontSize(_fontSize + 1);
  }

  /// 缩小字号。
  void decreaseFontSize() {
    _setFontSize(_fontSize - 1);
  }

  double get fontSize => _fontSize;

  void _setFontSize(double value) {
    final next = value.clamp(widget.minFontSize, widget.maxFontSize).toDouble();
    if (next == _fontSize) return;
    setState(() => _fontSize = next);
  }

  /// 行号列宽度随字号和行数位数自适应，防止放大后数字被切掉一半。
  double get _lineNumberWidth {
    final lineCount = '\n'.allMatches(widget.controller.text).length + 1;
    final digits = lineCount.toString().length;
    final width = 16 + _fontSize * digits * 0.72;
    return width.clamp(44.0, 160.0);
  }

  bool get wrap => _wrap;

  /// 切换自动换行。
  void toggleWrap() => setWrap(!_wrap);

  /// 设置自动换行。
  void setWrap(bool value) {
    if (_wrap == value) return;
    setState(() => _wrap = value);
  }

  /// 当前选中的文本；没有有效选区时返回空字符串。
  String get selectedText {
    final sel = widget.controller.selection;
    if (!sel.isValid ||
        sel.start < 0 ||
        sel.start >= widget.controller.text.length) {
      return '';
    }
    final end = sel.end > widget.controller.text.length
        ? widget.controller.text.length
        : sel.end;
    return widget.controller.text.substring(sel.start, end);
  }

  /// 统计关键字出现次数（不跨重叠，按普通子串匹配）。
  int countMatches(String query, {bool caseSensitive = false}) {
    if (query.isEmpty) return 0;
    final text = widget.controller.text;
    final haystack = caseSensitive ? text : text.toLowerCase();
    final needle = caseSensitive ? query : query.toLowerCase();
    var count = 0;
    var index = haystack.indexOf(needle);
    while (index != -1) {
      count++;
      index = haystack.indexOf(needle, index + needle.length);
    }
    return count;
  }

  /// 跳转到下一个匹配并选中该匹配文本。
  ///
  /// [reverse] 为 true 时向上一个匹配。默认允许循环查找。
  TextSelection? selectNextMatch(
    String query, {
    bool caseSensitive = false,
    bool reverse = false,
  }) {
    if (query.isEmpty) return null;
    final text = widget.controller.text;
    if (text.isEmpty) return null;
    final haystack = caseSensitive ? text : text.toLowerCase();
    final needle = caseSensitive ? query : query.toLowerCase();
    final sel = widget.controller.selection;

    int searchFrom;
    if (reverse) {
      final start = sel.isValid ? sel.start : text.length;
      searchFrom = start > text.length ? text.length : start;
    } else {
      final start = sel.isValid ? sel.end : 0;
      searchFrom = start < 0 ? 0 : (start > text.length ? text.length : start);
    }

    int index;
    if (reverse) {
      index = haystack.lastIndexOf(needle, searchFrom - 1);
      if (index < 0) {
        index = haystack.lastIndexOf(needle);
      }
    } else {
      index = haystack.indexOf(needle, searchFrom);
      if (index < 0) {
        index = haystack.indexOf(needle);
      }
    }
    if (index < 0) return null;

    final match = TextSelection(
      baseOffset: index,
      extentOffset: index + needle.length,
    );
    widget.controller.selection = match;
    return match;
  }

  /// 把当前光标/选区滚进可见区。
  ///
  /// 程序性地改 `controller.text` 时 Flutter **不会**自动滚动（只有用户输入才会），
  /// 于是 AI 在长文件里改第 300 行，用户盯着第 1 行什么都看不见。
  /// 这里顺着焦点节点找到内部的 EditableText，直接调它的 bringIntoView。
  void revealCursor() {
    final context = _focusNode.context;
    if (context == null) return;

    // 方向千万别搞反：
    //   EditableText.build() 里的层级是 EditableText → … → Focus → Scrollable，
    //   而 _focusNode.context 指的就是那个 **Focus** 元素。
    // 所以 EditableText 在它**上面**（只能 findAncestor 往上找），
    // 竖向滚动的 Scrollable 在它**下面**（只能 visitChildren 往下找）。
    // 之前这里往下找 EditableText，永远找不到 → 整个方法空转，
    // AI 改第 500 行时用户的视野还停在第 1 行。
    final editable = context.findAncestorStateOfType<EditableTextState>();
    if (editable == null) return;
    final selection = widget.controller.selection;
    if (!selection.isValid) return;
    final position = TextPosition(
      offset: selection.extentOffset.clamp(0, widget.controller.text.length),
    );

    // 竖向 + 横向都要跟着光标走：AI 在长行中段打字时，
    // 只滚竖向不滚横向，用户看到的就是"光标跟丢了"。
    final vertical = _findScrollable(context, Axis.vertical);
    final horizontal = _findScrollable(context, Axis.horizontal);
    if ((vertical == null || !vertical.position.hasContentDimensions) &&
        (horizontal == null || !horizontal.position.hasContentDimensions)) {
      // 拿不到滚动位置就退回框架自带的做法（至少能进可见区）。
      try {
        editable.bringIntoView(position);
      } catch (_) {
        // 布局还没完成时会抛，下一次落值会再滚一次。
      }
      return;
    }
    if (vertical != null && vertical.position.hasContentDimensions) {
      _scrollCaretToThird(editable, position, vertical);
    }
    if (horizontal != null && horizontal.position.hasContentDimensions) {
      _scrollCaretHorizontal(editable, position, horizontal);
    }
  }

  /// 往下找指定轴向的 Scrollable（EditableText 内部那个）。
  ScrollableState? _findScrollable(BuildContext context, Axis axis) {
    if (context is! Element) return null;
    ScrollableState? found;
    void visit(Element element) {
      if (found != null) return;
      if (element is StatefulElement && element.state is ScrollableState) {
        final state = element.state as ScrollableState;
        if (state.position.axis == axis) {
          found = state;
          return;
        }
      }
      element.visitChildren(visit);
    }

    context.visitChildren(visit);
    return found;
  }

  /// 把光标所在行滚到视口上方 1/3 处。
  ///
  /// 坑点：[RenderEditable.getLocalRectForCaret] 给的是**视口坐标**
  /// （已经把滚动偏移算进去了），不是文档坐标。所以判断"在不在视野里"
  /// 直接和 0..viewportDimension 比，算目标位置才要加上当前 pixels。
  void _scrollCaretToThird(
    EditableTextState editable,
    TextPosition position,
    ScrollableState scrollable,
  ) {
    try {
      final caret = editable.renderEditable.getLocalRectForCaret(position);
      final pos = scrollable.position;
      final viewport = pos.viewportDimension;
      if (viewport <= 0) return;
      // 已经在视野中间那一大块里就别动：来回跳比不跳更难受。
      if (caret.top >= viewport * 0.08 && caret.bottom <= viewport * 0.92) {
        return;
      }
      final wanted = (pos.pixels + caret.top - viewport / 3)
          .clamp(pos.minScrollExtent, pos.maxScrollExtent);
      if ((wanted - pos.pixels).abs() < 1) return;
      pos.animateTo(
        wanted,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOutCubic,
      );
    } catch (_) {
      // 布局/字形还没算完时会抛，下一段打字会再滚一次。
    }
  }

  /// 把光标横向滚进可视区（长行不换行时靠它跟上打字位置）。
  void _scrollCaretHorizontal(
    EditableTextState editable,
    TextPosition position,
    ScrollableState scrollable,
  ) {
    try {
      final caret = editable.renderEditable.getLocalRectForCaret(position);
      final pos = scrollable.position;
      final viewport = pos.viewportDimension;
      if (viewport <= 0) return;
      if (caret.left >= viewport * 0.04 && caret.right <= viewport * 0.96) {
        return;
      }
      final wanted = (pos.pixels + caret.left - viewport * 0.3)
          .clamp(pos.minScrollExtent, pos.maxScrollExtent);
      if ((wanted - pos.pixels).abs() < 1) return;
      pos.animateTo(
        wanted,
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOutCubic,
      );
    } catch (_) {
      // 布局/字形还没算完时会抛，下一次落值会再滚一次。
    }
  }

  /// 让编辑器拿到焦点（AI 改代码前调用，用户能看到光标在动）。
  ///
  /// 专供 AI 可视化编辑：焦点留着（光标/滚动定位需要它），
  /// 但**不弹输入法**——AI 改代码时弹键盘既挡视野又烦。
  void focus({int? offset}) {
    if (offset != null) {
      final clamped = offset.clamp(0, widget.controller.text.length);
      widget.controller.selection = TextSelection.collapsed(offset: clamped);
    }
    _focusNode.requestFocus();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // 先滚到要改的位置，再转身把输入法按回去：用户看到的是
      // “AI 定位到目标，然后开始原地打字”，而不是改完才跳过去。
      revealCursor();
      // requestFocus 会异步唤醒输入法，帧后再按回去。
      SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
    });
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: _onPointerDown,
      onPointerMove: _onPointerMove,
      onPointerUp: _onPointerEnd,
      onPointerCancel: _onPointerEnd,
      child: Stack(
        children: [
          Positioned.fill(
            child: CodeTheme(
              data: const CodeThemeData(styles: monokaiSublimeTheme),
              child: CodeField(
                controller: widget.controller,
                expands: true,
                lineNumbers: true,
                lineNumberStyle: LineNumberStyle(
                  width: _lineNumberWidth,
                  margin: 10,
                  background: Colors.black.withValues(alpha: 0.18),
                  textStyle: TextStyle(
                    fontFamily: kMonoFamily,
                    fontFamilyFallback: kMonoFallback,
                    fontSize: _fontSize,
                    // 行高必须和代码完全一致，否则行号对不上代码行。
                    height: 1.4,
                    // 行号要一眼能看到：亮白 85%，别再跟着主题变淡。
                    color: Colors.white.withValues(alpha: 0.85),
                  ),
                ),
                wrap: _wrap,
                enabled: widget.enabled,
                readOnly: widget.readOnly,
                focusNode: _focusNode,
                textStyle: TextStyle(
                  fontFamily: kMonoFamily,
                  fontFamilyFallback: kMonoFallback,
                  fontSize: _fontSize,
                  height: 1.4,
                ),
                onChanged: widget.onChanged,
                padding: widget.padding,
              ),
            ),
          ),
          if (_pinching)
            Positioned(
              right: 12,
              top: 12,
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.62),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 5,
                    ),
                    child: Text(
                      '${_pinchLabel.toStringAsFixed(0)} px',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
