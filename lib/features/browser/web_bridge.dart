import 'package:flutter/services.dart';

import '../../core/utils/logger.dart';

/// 浏览器内核的原生补丁通道（见 android/.../WebBridge.kt）。
///
/// webview_flutter 的 Dart 接口只给了 setCookie / getCookies(不含 HttpOnly)
/// / clearCookies，缺了"像真浏览器一样保住登录态"必需的几件事：cookie 落盘、
/// HttpOnly cookie 读取、站点数据（localStorage/IndexedDB）清理。
/// 这些都是几行 Android API，所以自己开一条窄通道，而不是换插件。
class WebBridge {
  WebBridge._();

  static const _channel = MethodChannel('coomi/web');

  /// 把内存里的 cookie 立刻写盘。
  ///
  /// Android 的 CookieManager 默认攒在内存里，进程被系统杀掉时不保证落盘——
  /// 用户辛辛苦苦过完人机验证、登录完，切后台被清理，票就没了。所以每次页面
  /// 加载完、浏览器收起时都主动 flush 一次。
  static Future<void> flush() => _invoke<void>('flushCookies');

  /// 允许（或禁止）接收 cookie。默认允许。
  static Future<void> acceptCookies(bool accept) =>
      _invoke<void>('acceptCookies', {'accept': accept});

  /// 某个地址下的完整 cookie 串，**包含 HttpOnly**。
  ///
  /// `document.cookie` 读不到 HttpOnly，而登录票（cf_clearance、各家的
  /// session）几乎都是 HttpOnly。CookieManager 站在浏览器这一侧，能原样给出。
  static Future<String> cookies(String url) async =>
      await _invoke<String>('getCookies', {'url': url}) ?? '';

  /// 写一条 cookie。[value] 是完整的 Set-Cookie 串。
  static Future<void> setCookie(String url, String value) =>
      _invoke<void>('setCookie', {'url': url, 'value': value});

  /// 清全部 cookie。**等内核真的清完**才返回（原生侧等 removeAllCookies 回调）。
  static Future<void> clearCookies() => _invoke<void>('clearCookies');

  /// 清某个域的 cookie（含子路径上的那些），返回清掉几条。
  static Future<int> removeCookiesFor(String host) async =>
      await _invoke<int>('removeCookiesFor', {'host': host}) ?? 0;

  /// 清掉一个域的 cookie，办法是**整库清空 + 把别的站点原样写回**。
  ///
  /// 为什么不用 [removeCookiesFor]：那条按 name 写一条过期 Set-Cookie，属于
  /// "从脚本一侧删"，内核对 **HttpOnly** 条目根本不让覆盖。现场就是这么翻车的
  /// ——reset 报"已清掉 N 个 Cookie"，回头 `browser_cookies` 一查，
  /// `auth` / `authorization`（两条都是 HttpOnly）原封不动还在，页面还是登录态；
  /// 换 logout（整库 removeAllCookies）一次就干净。
  ///
  /// 返回 `{cleared, restored, lost}`：目标站清掉几条、别的站写回几条、
  /// 有几条因为值被内核加密而还不回去（那些站点得重新登录，必须如实上报）。
  static Future<Map<String, int>> clearCookiesExcept(String host) async {
    final raw = await _invoke<Map<Object?, Object?>>(
      'clearCookiesExcept',
      {'host': host},
    );
    if (raw == null) return const {};
    return {
      for (final e in raw.entries)
        e.key.toString(): (e.value as num?)?.toInt() ?? 0,
    };
  }

  /// 把内核的 cookie 库整个读出来（[host] 为空 = 全部站点）。
  ///
  /// [cookies] 只能给出"匹配这个 path 的那些"。站点把票放在 /api 之类的
  /// 子路径时，站在首页问就是一片空白。这条直接读内核自己的库，没有盲区。
  static Future<List<Map<String, dynamic>>> dumpCookies([
    String host = '',
  ]) async {
    final raw = await _invoke<List<Object?>>('dumpCookies', {'host': host});
    if (raw == null) return const [];
    return raw
        .whereType<Map<Object?, Object?>>()
        .map((m) => m.map((k, v) => MapEntry(k.toString(), v)))
        .toList();
  }

  /// 清所有站点的 localStorage / sessionStorage / IndexedDB / 缓存。
  static Future<void> clearStorage() => _invoke<void>('clearWebStorage');

  /// 只清一个域的数据（换账号用，不影响别的站点登录态）。
  static Future<void> clearOrigin(String origin) =>
      _invoke<void>('clearOrigin', {'origin': origin});

  /// 内核信息：包名、版本、是否收 cookie。排查"某站点打不开"时先看它。
  static Future<Map<String, dynamic>> info() async {
    final raw = await _invoke<Map<Object?, Object?>>('engineInfo');
    if (raw == null) return {};
    return raw.map((k, v) => MapEntry(k.toString(), v));
  }

  static Future<T?> _invoke<T>(String method,
      [Map<String, dynamic>? args]) async {
    try {
      return await _channel.invokeMethod<T>(method, args);
    } on MissingPluginException {
      // 不该发生（通道在 MainActivity 里注册），但不能因为它把浏览器搞崩。
      Logger.e('web', 'channel missing: $method');
      return null;
    } catch (e) {
      Logger.e('web', 'invoke $method failed', e);
      return null;
    }
  }
}
