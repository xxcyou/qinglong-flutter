import 'dart:async';

/// 互动画布的回传总线。
///
/// 画布不只是"给用户看"：AI 打开一个滑块验证页、一张表单、一个选择器，
/// 需要拿到用户操作的结果才能继续。所以工具调用会挂在这里等一个结果，
/// 由弹窗在用户提交/关闭时把结果送回来。
///
/// 设计上刻意只有一条窄通道（一个字符串结果），网页里的 JS 拿不到 APP
/// 的任何数据，只能"往外说一句话"。
class CanvasResultBus {
  CanvasResultBus._();

  static final Map<String, Completer<String>> _waiting = {};

  /// 等一个画布的结果。超时或被取消时返回 null。
  static Future<String?> wait(
    String canvasId, {
    Duration timeout = const Duration(minutes: 10),
    bool Function()? isCancelled,
  }) async {
    final completer = Completer<String>();
    _waiting[canvasId] = completer;
    try {
      // 一边等结果，一边每秒看一眼有没有被"停止"——否则用户点了停止，
      // 循环还挂在这里等一个永远不来的提交。
      final deadline = DateTime.now().add(timeout);
      while (!completer.isCompleted) {
        if (isCancelled?.call() == true) return null;
        if (DateTime.now().isAfter(deadline)) return null;
        final result = await Future.any([
          completer.future.then<String?>((v) => v),
          Future<String?>.delayed(const Duration(seconds: 1), () => null),
        ]);
        if (result != null) return result;
      }
      return completer.isCompleted ? await completer.future : null;
    } finally {
      _waiting.remove(canvasId);
    }
  }

  /// 弹窗侧回传结果。没人在等就直接丢掉（用户手动打开旧卡片的情况）。
  static void submit(String canvasId, String payload) {
    final completer = _waiting[canvasId];
    if (completer != null && !completer.isCompleted) {
      completer.complete(payload);
    }
  }

  /// 是否有人在等这个画布的结果。弹窗用它决定要不要显示"提交给 AI"按钮。
  static bool isAwaited(String canvasId) => _waiting.containsKey(canvasId);
}

/// 多个画布窗口之间的消息总线。
///
/// "游戏窗 + 操作窗 + 成绩窗"要互相通气：操作窗按了方向键要告诉游戏窗，
/// 游戏窗结算了要把分数推给成绩窗。三个窗口是三个独立 WebView，页面之间
/// 没有任何共享内存，所以必须由 Dart 侧转发。
///
/// 通道刻意保持窄：只能传字符串，只能发给"当前开着的窗口"，
/// 页面依旧读不到 APP 的任何数据。
class CanvasBus {
  CanvasBus._();

  /// 窗口名 → 投递函数（内部就是往那个 WebView 里跑一段 JS）。
  static final Map<String, void Function(String from, String payload)>
      _inboxes = {};

  static void register(
    String window,
    void Function(String from, String payload) deliver,
  ) {
    if (window.isEmpty) return;
    _inboxes[window] = deliver;
  }

  static void unregister(String window, [Object? owner]) {
    if (window.isEmpty) return;
    _inboxes.remove(window);
  }

  /// 当前开着的窗口名。工具回复里会带给模型，让它知道能发给谁。
  static List<String> get windows => _inboxes.keys.toList();

  /// 投递。[to] 为空或 `*` 时广播给除自己以外的所有窗口。
  ///
  /// 返回真正收到的窗口数，0 表示对方还没开——这条消息就地丢掉，
  /// 不排队：画布是即时界面，补发一条过期消息只会让画面错乱。
  static int post(String from, String to, String payload) {
    final target = to.trim();
    if (target.isEmpty || target == '*') {
      var count = 0;
      for (final entry in _inboxes.entries) {
        if (entry.key == from) continue;
        entry.value(from, payload);
        count++;
      }
      return count;
    }
    final deliver = _inboxes[target];
    if (deliver == null) return 0;
    deliver(from, payload);
    return 1;
  }
}
