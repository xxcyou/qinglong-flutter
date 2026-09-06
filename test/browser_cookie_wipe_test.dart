import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qinglong_flutter/features/browser/browser_engine.dart';

/// `browser_session reset` 报成功却没清掉登录态那个 bug。
///
/// 现场：对 opencode.ai / auth.opencode.ai 各跑一次 reset，都回报"已重置为未
/// 登录状态、清掉 N 个 Cookie"，紧接着 browser_cookies 一查，`auth`、
/// `authorization` 原封不动还在，重开页面还是登录后的密钥页；换
/// browser_control logout 就一次干净。两条票都是 **HttpOnly**——按 name 写一条
/// 过期 Set-Cookie 是脚本侧删法，内核不允许覆盖 HttpOnly 条目。
///
/// 这组测试用假内核复现那个行为差异：removeCookiesFor 只删得掉普通 cookie，
/// clearCookiesExcept（整库清空 + 写回别站）才连 HttpOnly 一起干掉。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('coomi/web');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  /// 假 cookie 库。
  late List<Map<String, Object?>> store;
  late List<String> calls;

  Map<String, Object?> row(
    String host,
    String name, {
    bool httpOnly = false,
    bool encrypted = false,
  }) =>
      {
        'host': host,
        'name': name,
        'value': encrypted ? '' : 'v-$name',
        'encrypted': encrypted,
        'path': '/',
        'secure': true,
        'httpOnly': httpOnly,
        'expires': 0,
      };

  bool belongs(String hostKey, String host) {
    final h = hostKey.replaceFirst(RegExp(r'^\.'), '').toLowerCase();
    final b = host.replaceFirst(RegExp(r'^\.'), '').toLowerCase();
    return h == b || h.endsWith('.$b');
  }

  setUp(() {
    calls = [];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      final args = (call.arguments as Map?) ?? const {};
      switch (call.method) {
        case 'dumpCookies':
          final host = (args['host'] ?? '').toString();
          if (host.isEmpty) return store;
          return store
              .where((r) => belongs(r['host']! as String, host))
              .toList();
        case 'removeCookiesFor':
          // 真机行为：只删得掉非 HttpOnly 的条目。
          final host = (args['host'] ?? '').toString();
          final before = store.length;
          store = store
              .where((r) =>
                  !(belongs(r['host']! as String, host) &&
                      r['httpOnly'] != true))
              .toList();
          return before - store.length;
        case 'clearCookiesExcept':
          // 真机行为：整库 removeAllCookies，再写回别的站点。
          final host = (args['host'] ?? '').toString();
          final keep = store
              .where((r) => !belongs(r['host']! as String, host))
              .toList();
          final cleared = store.length - keep.length;
          final restorable =
              keep.where((r) => r['encrypted'] != true).toList();
          store = restorable;
          return {
            'cleared': cleared,
            'restored': restorable.length,
            'lost': keep.length - restorable.length,
          };
        case 'flushCookies':
          return true;
      }
      return null;
    });
  });

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('HttpOnly 登录票：温柔删不掉 → 自动升级整库清空 → 复查为 0', () async {
    store = [
      row('opencode.ai', 'auth', httpOnly: true),
      row('opencode.ai', 'oc_locale'),
      row('.other.com', 'sess'),
    ];

    final r = await BrowserEngine.instance.wipeCookies('opencode.ai');

    expect(r.clean, isTrue);
    expect(r.left, 0);
    expect(calls, contains('removeCookiesFor'));
    expect(calls, contains('clearCookiesExcept'),
        reason: '温柔删留下 HttpOnly 时必须升级到整库清空');
    expect(r.text, contains('已复查'));
    expect(r.text, contains('HttpOnly'));
    // 别人的登录态不能被顺手清掉。
    expect(store.map((e) => e['name']), ['sess']);
  });

  test('全是普通 cookie：温柔删就够了，不动整库', () async {
    store = [row('a.com', 'x'), row('a.com', 'y'), row('.b.com', 'keep')];

    final r = await BrowserEngine.instance.wipeCookies('a.com');

    expect(r.clean, isTrue);
    expect(calls, isNot(contains('clearCookiesExcept')),
        reason: '能温柔删干净就别整库清空，别站的票没必要冒险重写');
    expect(store.map((e) => e['name']), ['keep']);
  });

  test('子域一起清：auth.opencode.ai 的票不会漏', () async {
    store = [
      row('auth.opencode.ai', 'authorization', httpOnly: true),
      row('.opencode.ai', 'auth', httpOnly: true),
    ];

    final r = await BrowserEngine.instance.wipeCookies('opencode.ai');

    expect(r.clean, isTrue);
    expect(store, isEmpty);
  });

  test('清不干净时如实报警，绝不说"已重置"', () async {
    // 假一个顽固内核：两种删法都失效（真机上遇到过内核实现差异）。
    messenger.setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'dumpCookies':
          return [row('x.com', 'auth', httpOnly: true)];
        case 'removeCookiesFor':
          return 0;
        case 'clearCookiesExcept':
          return {'cleared': 0, 'restored': 0, 'lost': 0};
      }
      return true;
    });

    final r = await BrowserEngine.instance.wipeCookies('x.com');

    expect(r.clean, isFalse);
    expect(r.left, 1);
    expect(r.text, contains('⚠️'));
    expect(r.text, contains('没清干净'));
    expect(r.text, contains('logout'), reason: '要告诉调用方下一步该用什么');
  });

  test('本来就没有 cookie → 不误报"清掉了"', () async {
    store = [];
    final r = await BrowserEngine.instance.wipeCookies('empty.com');
    expect(r.clean, isTrue);
    expect(r.text, contains('本来就没有'));
  });

  test('别站 cookie 值被加密还不回去 → 如实上报，不闷着', () async {
    store = [
      row('opencode.ai', 'auth', httpOnly: true),
      row('.enc.com', 'sess', encrypted: true),
    ];

    final r = await BrowserEngine.instance.wipeCookies('opencode.ai');

    expect(r.clean, isTrue);
    expect(r.text, contains('没能写回'));
    expect(r.text, contains('重新登录'));
  });
}
