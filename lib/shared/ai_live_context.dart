import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/ai/floating/ai_dock_provider.dart';

/// 「我正在看的东西」自动附给 AI。
///
/// 用户打开一个日志页，然后点开悬浮窗提问——他脑子里的问题几乎一定是关于
/// 这份日志的，却要先自己点一下「问 AI」把内容带过去，忘了就得到一句
/// "你把日志发我看看"。这个 mixin 把那一步去掉：进页面自动挂上附件，
/// 离开页面自动撤下，用户不想带就点附件上的 X。
///
/// 三条规矩：
/// 1. **不抢焦点**：挂附件不弹悬浮窗（用它的 `attach` 而不是 `push`），
///    否则每开一个日志页都会糊一个窗口在屏幕上。
/// 2. **发送后不掉**：sticky = true。用户在同一页问三句，三句都带这份内容。
/// 3. **只读**：日志、面板状态这类东西给 AI 是为了分析，写回去没有意义，
///    提示词里明说，免得它去尝试改日志文件。
mixin AiLiveContextMixin<T extends ConsumerStatefulWidget> on ConsumerState<T> {
  /// 附件的唯一标识。同一 key 再挂就是替换，不会攒出一串同名附件。
  String get aiContextKey;

  /// 附件标签（展示在输入框上方）。
  String get aiContextLabel;

  /// 来源模块名，写进提示词让 AI 知道用户当时在看什么。
  String get aiContextSource;

  /// 取当下内容。发送那一刻会再调一次——日志一直在滚，
  /// 带过去的应该是此刻的内容，而不是打开页面那一瞬的。
  String buildAiContext();

  String? get aiContextLanguage => null;

  /// 内容还没加载出来时不要挂空附件。
  bool get aiContextReady => buildAiContext().trim().isNotEmpty;

  /// 提前抓住的 notifier。
  ///
  /// 不能等到 dispose 再 `ref.read`：riverpod 的 ref 在 element 变 defunct 之后
  /// 会直接抛 StateError，而 dispose 里抛异常会**中断 State.dispose 的后半段**
  /// ——`_element` 不置空、`_debugLifecycleState` 不置 defunct，于是这个页面
  /// 的 `mounted` 永远是 true，之后每个在途回调都会 setState 到一个死元素上，
  /// logcat 里刷一串 `_lifecycleState != defunct` 断言。所以在页面还活着的时候
  /// 就把 notifier 存下来（它是全局单例，页面没了照样能用）。
  AiDockNotifier? _dock;

  bool _attached = false;

  /// 挂上/更新附件。内容准备好后调用，重复调用是安全的。
  void syncAiContext() {
    if (!mounted) return;
    _dock ??= ref.read(aiDockProvider.notifier);
    final dock = _dock!;
    if (!aiContextReady) {
      if (_attached) {
        dock.detach(aiContextKey);
        _attached = false;
      }
      return;
    }
    dock.attach(
      AiContextChip(
        key: aiContextKey,
        label: aiContextLabel,
        content: buildAiContext(),
        source: aiContextSource,
        language: aiContextLanguage,
        readOnly: true,
        sticky: true,
        live: () => mounted ? buildAiContext() : '',
      ),
    );
    _attached = true;
  }

  @override
  void dispose() {
    if (_attached) {
      // 不在 dispose 里读 ref（会抛，见 _dock 的说明），用提前存好的引用。
      // 也不在这一帧直接改 provider（可能正处在 build/dispose 流程里），
      // 挪到下一个微任务。
      final dock = _dock;
      final key = aiContextKey;
      if (dock != null) Future.microtask(() => dock.detach(key));
      _attached = false;
    }
    super.dispose();
  }
}
