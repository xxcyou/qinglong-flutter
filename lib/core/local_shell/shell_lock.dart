import 'dart:async';

/// 串行闸门：同名资源同一时刻只允许一个操作在跑。
///
/// 为什么必须有它：现在 AI 不止一个了（子代理 / 并行代理），而下面这些东西
/// 全都是**单例资源**，两个代理同时动就会出事：
///
/// - **PRoot 终端**：每次 exec 都在同一个 rootfs 里起进程。两条命令同时跑，
///   apt/dpkg 的锁会互相拆台（`dpkg was interrupted`）、同一个工作文件会被
///   写花、cwd 也会互相干扰。表现就是"卡住"或者莫名其妙失败。
/// - **浏览器内核**：全 APP 一个 WebView。A 代理刚导航到登录页，B 代理一句
///   browser_open 就把页面换掉了，A 拿到的 DOM 是别人的页面。
/// - **同一个文件**：两个代理各写一半，最后谁写完算谁的，另一半直接丢。
///
/// 设计要点：
/// - 不是"拒绝"，而是**排队**：后来的等前面的做完，任务照样能完成，只是慢一点；
/// - 排队有上限时间（[timeout]），等不到就报错而不是永远挂着——挂着才是真卡死；
/// - 报错里带上"正被谁占着"，用户和模型都能看懂为什么慢。
class ShellLock {
  ShellLock._();

  /// 资源名 → 队尾。用 Future 链做互斥：新任务挂在上一个的后面。
  static final Map<String, Future<void>> _tails = {};

  /// 资源名 → 当前占用者标签，报错时告诉调用方在等谁。
  static final Map<String, String> _holders = {};

  /// 资源名 → 排队长度（含正在跑的那个）。
  static final Map<String, int> _depths = {};

  /// 本机终端（PRoot exec）。
  static const terminal = 'terminal';

  /// 内置浏览器内核。
  static const browser = 'browser';

  /// 某个文件的写入。
  static String file(String path) => 'file:$path';

  static int depthOf(String resource) => _depths[resource] ?? 0;

  static String holderOf(String resource) => _holders[resource] ?? '';

  /// 拿着 [resource] 的锁跑 [body]。
  ///
  /// [label] 是给人看的占用说明（例如 `shell_exec: pip install`）。
  /// [timeout] 是**排队等待**的上限，不是 body 的执行上限——body 自己的超时
  /// 由调用方控制（PRoot exec 有 timeoutSeconds）。
  static Future<T> run<T>(
    String resource,
    Future<T> Function() body, {
    String label = '',
    Duration timeout = const Duration(seconds: 180),
  }) async {
    final previous = _tails[resource];
    final gate = Completer<void>();
    // 先把自己接到队尾：后面来的人排在我后面，顺序稳定（先到先得）。
    _tails[resource] = gate.future;
    _depths[resource] = (_depths[resource] ?? 0) + 1;

    try {
      if (previous != null) {
        try {
          await previous.timeout(timeout);
        } on TimeoutException {
          final holder = _holders[resource] ?? '未知操作';
          throw StateError(
            '等 $resource 等太久了（超过 ${timeout.inSeconds} 秒）：'
            '现在被「$holder」占着。要么等它结束，要么换个不碰这个资源的做法。',
          );
        }
      }
      _holders[resource] = label.isEmpty ? resource : label;
      return await body();
    } finally {
      _holders.remove(resource);
      final depth = (_depths[resource] ?? 1) - 1;
      if (depth <= 0) {
        _depths.remove(resource);
      } else {
        _depths[resource] = depth;
      }
      // 放闸：下一个排队的人开始跑。
      gate.complete();
      // 队尾就是我时把记录清掉，别让 Map 越长越大。
      if (_tails[resource] == gate.future) _tails.remove(resource);
    }
  }
}
