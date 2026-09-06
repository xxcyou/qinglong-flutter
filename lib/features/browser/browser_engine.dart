import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

import '../../core/local_shell/proot_bridge.dart';
import '../../core/storage/secure_storage.dart';
import '../../core/utils/logger.dart';
import 'browser_window.dart';
import 'intercept_js.dart';
import 'models/intercept_script.dart';
import 'models/browser_models.dart';
import 'web_bridge.dart';
import '../../shared/float_stack.dart';

/// 内置浏览器内核：一个常驻的 WebView，AI 通过它访问真实网页。
///
/// 为什么需要它：`web_fetch` 走的是 Dio，拿到的是"纯 HTTP 那一层"。
/// 遇到 Cloudflare 人机验证、需要登录、内容靠 JS 渲染的站点，它只能拿回一页
/// "请稍候…"。真浏览器内核有三个 Dio 给不了的东西：
/// 1. **能过 CF**：把页面显示给用户点一下验证，之后这个 WebView 里就带着
///    cf_clearance（HttpOnly，代码读不到，但浏览器自己会带）；
/// 2. **能抓包**：注入钩子接管 fetch / XHR，页面真实请求的地址、载荷、返回
///    全部记下来——想要的数据往往在某个 XHR 的 JSON 里，而不在 HTML 上；
/// 3. **能注入脚本操作页面**：点按钮、填表、滚动加载、取 DOM 文本。
///
/// 关键用法是 [fetchInPage]：**在页面上下文里**发请求。这样 Cookie（含
/// HttpOnly 的 CF 票）、Referer、UA 全部与真实浏览器一致，等于"验证过一次，
/// 后面接口随便调"。
///
/// 生命周期：整个 APP 一个实例（单例）。WebView 部件常驻挂在全局浏览器宿主
/// 里，隐藏时挪到屏幕外而不是卸载——卸载会丢掉登录态和 CF 票，那就白验证了。
class BrowserEngine {
  BrowserEngine._();

  static final BrowserEngine instance = BrowserEngine._();

  WebViewController? _controller;
  WebViewController? get controller => _controller;

  /// 面板是否显示给用户看。宿主部件监听它。
  final ValueNotifier<bool> visible = ValueNotifier(false);

  /// 当前地址 / 标题 / 加载状态，给界面显示。
  final ValueNotifier<String> currentUrl = ValueNotifier('');
  final ValueNotifier<String> title = ValueNotifier('');
  final ValueNotifier<bool> loading = ValueNotifier(false);

  /// 抓到的请求。倒序显示，超过上限丢最老的。
  final ValueNotifier<List<CapturedRequest>> requests = ValueNotifier([]);
  final ValueNotifier<List<ConsoleLine>> console = ValueNotifier([]);

  /// AI 请用户接手时的提示语（例如"请完成人机验证"）。空 = 没在等。
  final ValueNotifier<String> waitingHint = ValueNotifier('');

  /// 有没有上一页：界面上的返回键靠它决定灰不灰。
  final ValueNotifier<bool> canGoBack = ValueNotifier(false);

  static const _maxRequests = 300;
  static const _maxConsole = 200;

  int _evalSeq = 0;
  final Map<int, Completer<String>> _evalWaiters = {};

  /// 用户点"我弄好了"时完成。AI 的 browser_wait_user 等的就是它。
  Completer<String>? _userAck;

  bool get isReady => _controller != null;

  /// 建内核。重复调用无副作用。
  bool _scriptsLoaded = false;

  Future<WebViewController> ensure() async {
    final existing = _controller;
    if (existing != null) return existing;
    // 脚本表要在第一次导航之前就位，否则第一个页面白跑一遍。
    if (!_scriptsLoaded) {
      _scriptsLoaded = true;
      await loadScripts();
    }
    final c = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..addJavaScriptChannel('QLBridge', onMessageReceived: _onBridge)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (url) {
            loading.value = true;
            currentUrl.value = url;
          },
          onPageFinished: (url) async {
            loading.value = false;
            currentUrl.value = url;
            title.value = await _controller?.getTitle() ?? '';
            canGoBack.value = await _controller?.canGoBack() ?? false;
            // 每次导航后 JS 环境重建，钩子要重新装。
            await _injectHooks();
            // 登录 / 过验证之后 cookie 只在内存里，进程被杀就没了。
            // 每次加载完落一次盘，等于"关掉 APP 明天回来还是登录状态"。
            await WebBridge.flush();
            _record(
              CapturedRequest(
                id: ++_docSeq,
                method: 'GET',
                url: url,
                kind: 'doc',
                status: 200,
                ok: true,
              ),
            );
          },
          onWebResourceError: (error) {
            loading.value = false;
            _log('error', '${error.errorCode} ${error.description}');
          },
        ),
      );
    // 用真实手机 UA：默认 UA 里带 wv 字样，很多站点会因此直接给验证页。
    await c.setUserAgent(
      'Mozilla/5.0 (Linux; Android 14; Redmi K50) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/131.0.0.0 Mobile Safari/537.36',
    );
    _controller = c;
    await _applyBrowserLikeSettings(c);
    return c;
  }

  /// 让这个 WebView 的行为尽量贴近真实浏览器（登录态、跨站 cookie、媒体）。
  ///
  /// 默认的 WebView 是"嵌在 APP 里的显示控件"，几个默认值和浏览器正相反：
  /// - 不收第三方 cookie：接了 SSO / CF 的站点直接登不上；
  /// - cookie 只在内存：进程被回收，登录态清零；
  /// - 媒体必须用户手势才播：有些站点靠一段静默视频探测环境。
  Future<void> _applyBrowserLikeSettings(WebViewController c) async {
    await WebBridge.acceptCookies(true);
    final platform = c.platform;
    if (platform is AndroidWebViewController) {
      // 跨站 cookie 必须按 WebView 实例放开，全局开关管不到它。
      final cookieManager = AndroidWebViewCookieManager(
        const PlatformWebViewCookieManagerCreationParams(),
      );
      await cookieManager.setAcceptThirdPartyCookies(platform, true);
      await platform.setMediaPlaybackRequiresUserGesture(false);
      // 允许读本地文件：AI 经常把网页写到 /workspace 再让用户"用浏览器看看效果"。
      // Android 10 以上 WebView 默认关掉 file:// 访问，不开这两个开关，
      // 打开本地 html 只会得到一片空白（ERR_ACCESS_DENIED）。
      // 安全边界没变：能读到的只有 APP 自己沙箱里的文件，
      // 而且下面 openLocal 会先做越界校验。
      await platform.setAllowFileAccess(true);
      await platform.setAllowContentAccess(true);
      // 页面里的 console 也收一份：注入脚本调试时不用另开工具。
      await platform.setOnConsoleMessage(
        (message) => _log(message.level.name, message.message),
      );
    }
  }

  int _docSeq = 0;

  // ------------------------------------------------------------------ 桥

  void _onBridge(JavaScriptMessage message) {
    Map<String, dynamic> json;
    try {
      final decoded = jsonDecode(message.message);
      if (decoded is! Map<String, dynamic>) return;
      json = decoded;
    } catch (_) {
      return;
    }
    switch (json['t']) {
      case 'req':
        _record(
          CapturedRequest(
            id: (json['id'] as num?)?.toInt() ?? ++_docSeq,
            method: json['method']?.toString() ?? 'GET',
            url: json['url']?.toString() ?? '',
            kind: json['kind']?.toString() ?? 'fetch',
            requestBody: _cap(json['body']?.toString() ?? ''),
            requestHeaders: json['rh']?.toString() ?? '',
            mutation: json['mut']?.toString() ?? '',
          ),
        );
      case 'res':
        final id = (json['id'] as num?)?.toInt() ?? -1;
        final list = requests.value;
        final hit = list.where((r) => r.id == id);
        if (hit.isEmpty) return;
        final mut = json['mut']?.toString() ?? '';
        final r = hit.first
          ..status = (json['status'] as num?)?.toInt() ?? 0
          ..ok = json['ok'] == true
          ..ms = (json['ms'] as num?)?.toInt() ?? 0
          ..contentType = json['ct']?.toString() ?? ''
          ..responseBody = _cap(json['body']?.toString() ?? '')
          ..error = json['err']?.toString() ?? '';
        // 请求头在 req 阶段已经记下了，res 阶段只在真带了才覆盖
        // （被脚本改过的那份才是真正发出去的）。
        final reqHeaders = json['rh']?.toString() ?? '';
        if (reqHeaders.isNotEmpty) r.requestHeaders = reqHeaders;
        r.responseHeaders = json['sh']?.toString() ?? '';
        // 改写说明由响应侧覆盖（它带着请求侧 + 响应侧的完整清单）；
        // 空串就保留请求阶段记下的那份。
        if (mut.isNotEmpty) r.mutation = mut;
        // 同一个对象改字段，ValueNotifier 认不出来，换个 List 触发刷新。
        requests.value = List.of(list);
        if (r.status >= 400) _log('warn', '${r.status} ${r.shortUrl}');
      case 'hit':
        // 脚本改动了某个包：累计次数。这是判断"脚本到底生效了没"的唯一硬证据。
        final id = (json['id'] as num?)?.toInt() ?? -1;
        for (final script in _scripts) {
          if (script.id == id) script.hits++;
        }
        scriptsRevision.value++;
      case 'serr':
        // 脚本编译/运行出错：挂在那个脚本上，列表页直接看得见。
        final id = (json['id'] as num?)?.toInt() ?? -1;
        final message = json['msg']?.toString() ?? '';
        for (final script in _scripts) {
          if (script.id == id) script.error = message;
        }
        scriptsRevision.value++;
        _log('error', '脚本 #$id：$message');
      case 'log':
        _log(
            json['level']?.toString() ?? 'log', json['text']?.toString() ?? '');
      case 'eval':
        final id = (json['id'] as num?)?.toInt() ?? -1;
        final waiter = _evalWaiters.remove(id);
        if (waiter == null || waiter.isCompleted) return;
        if (json['ok'] == true) {
          waiter.complete(json['v']?.toString() ?? '');
        } else {
          waiter.completeError(StateError(json['e']?.toString() ?? '脚本出错'));
        }
    }
  }

  /// 单条抓包内容上限：整页 HTML 动辄几百 KB，全留会把内存吃光。
  static String _cap(String text, [int limit = 200000]) =>
      text.length <= limit ? text : '${text.substring(0, limit)}…（已截断）';

  void _record(CapturedRequest request) {
    final list = List.of(requests.value)..insert(0, request);
    if (list.length > _maxRequests) list.removeRange(_maxRequests, list.length);
    requests.value = list;
  }

  void _log(String level, String text) {
    final list = List.of(console.value)
      ..insert(0, ConsoleLine(level: level, text: text));
    if (list.length > _maxConsole) list.removeRange(_maxConsole, list.length);
    console.value = list;
  }

  /// 抓包 + 改包 + console 钩子。
  ///
  /// 每次导航后 JS 环境重建，所以这里会被反复调用；钩子自己用
  /// `__qlHooked` 保证只装一次。装完立刻把脚本表推进去——脚本表在 Dart 侧，
  /// 页面侧只是执行者（每次导航都重新编译一遍）。
  Future<void> _injectHooks() async {
    try {
      await _controller?.runJavaScript(interceptJs);
      await _pushScripts();
    } catch (e) {
      Logger.e('browser', 'inject hooks failed', e);
    }
  }

  // -------------------------------------------------------------- 基本操作

  Future<void> open(String url) async {
    final c = await ensure();
    var target = url.trim();
    // 本地文件优先判断：AI 写了个 html 到工作目录，然后想让用户看效果。
    // 以前这里一律补 https://，于是 /workspace/a.html 变成
    // https://workspace/a.html —— 用户看到的就是"悬浮窗浏览器打不开本地文件"。
    if (isLocalTarget(target)) {
      await openLocal(target);
      return;
    }
    if (!target.startsWith('http')) target = 'https://$target';
    loading.value = true;
    await c.loadRequest(Uri.parse(target));
  }

  /// 看起来是本地文件/路径吗。
  ///
  /// 三种写法都算：`file:///…`、以 `/` 开头的绝对路径（guest 或宿主）、
  /// 以及 `workspace/x.html`、`./x.html` 这种明显是相对路径的写法。
  static bool isLocalTarget(String raw) {
    final t = raw.trim();
    if (t.isEmpty) return false;
    if (t.startsWith('file:')) return true;
    if (t.startsWith('/')) return true;
    if (t.startsWith('./') || t.startsWith('../') || t.startsWith('~/')) {
      return true;
    }
    // 带 scheme 的一律不算本地。
    if (RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*://').hasMatch(t)) return false;
    // workspace/a.html、tmp/report.htm：有目录分隔且是网页后缀。
    final path = t.split('?').first.split('#').first.toLowerCase();
    final isPage = path.endsWith('.html') ||
        path.endsWith('.htm') ||
        path.endsWith('.svg') ||
        path.endsWith('.pdf');
    return isPage && !t.contains(' ');
  }

  /// 打开本地文件。返回真正加载的 file:// 地址。
  ///
  /// 路径解析顺序（先 guest 再宿主）：
  /// 1. `file:///…` 直接用；
  /// 2. guest 路径（/workspace、/tmp、/home/coomi…）→ 问原生要宿主真实路径；
  /// 3. 上一步失败时按宿主绝对路径再试一次（沙箱内越界校验仍然生效）；
  /// 4. 相对路径按 /workspace 补全。
  ///
  /// 走 [WebViewController.loadFile]：它在 Android 侧会顺手把 allowFileAccess
  /// 打开，比自己拼 loadRequest 少踩一个坑。
  Future<String> openLocal(String rawPath) async {
    final c = await ensure();
    var path = rawPath.trim();
    // 查询串 / 锚点对本地文件没意义，去掉再解析，免得当成文件名的一部分。
    final query = RegExp(r'[?#].*$').stringMatch(path) ?? '';
    if (query.isNotEmpty) path = path.substring(0, path.length - query.length);

    String hostPath;
    if (path.startsWith('file://')) {
      hostPath = Uri.parse(path).toFilePath();
    } else {
      if (path.startsWith('~/')) path = '/home/coomi/${path.substring(2)}';
      if (path.startsWith('./')) path = path.substring(2);
      if (!path.startsWith('/')) path = '/workspace/$path';
      final bridge = ProotBridge();
      try {
        hostPath = await bridge.hostPath(path: path);
      } catch (_) {
        // 不是 guest 挂载点下的路径，再按宿主绝对路径试一次。
        try {
          hostPath = await bridge.hostPath(path: path, scope: 'app');
        } catch (e) {
          loading.value = false;
          _log('error', '本地路径解析失败：$path');
          throw StateError('打不开本地文件：$path（$e）');
        }
      }
    }
    if (hostPath.isEmpty) throw StateError('打不开本地文件：$rawPath');
    if (!File(hostPath).existsSync()) {
      loading.value = false;
      throw StateError('文件不存在：$rawPath');
    }
    loading.value = true;
    final url = '${Uri.file(hostPath)}$query';
    // loadFile 不接受 query，带参数时退回 loadRequest（file scheme 同样生效）。
    if (query.isEmpty) {
      await c.loadFile(hostPath);
    } else {
      await c.loadRequest(Uri.parse(url));
    }
    currentUrl.value = url;
    return url;
  }

  Future<void> reload() async => _controller?.reload();

  /// 同步求值：只能拿"能转成字符串的立即值"。
  Future<String> evalSync(String js) async {
    final c = await ensure();
    final raw = await c.runJavaScriptReturningResult(js);
    return _unquote(raw.toString());
  }

  /// 异步求值：支持 await。结果通过桥回来，所以能等 Promise。
  ///
  /// [js] 是函数体，用 `return` 交结果。
  Future<String> eval(String js,
      {Duration timeout = const Duration(seconds: 30)}) async {
    final c = await ensure();
    final id = ++_evalSeq;
    final completer = Completer<String>();
    _evalWaiters[id] = completer;
    final wrapped = '''
(async function(){
  try {
    var v = await (async function(){ $js })();
    QLBridge.postMessage(JSON.stringify({t:'eval', id:$id, ok:true,
      v: (typeof v === 'string') ? v : JSON.stringify(v)}));
  } catch(e) {
    QLBridge.postMessage(JSON.stringify({t:'eval', id:$id, ok:false, e:String(e)}));
  }
})();
''';
    await c.runJavaScript(wrapped);
    try {
      return await completer.future.timeout(timeout);
    } on TimeoutException {
      _evalWaiters.remove(id);
      throw StateError('脚本执行超时（${timeout.inSeconds}s）');
    }
  }

  /// 等某个条件成立（JS 表达式为真）。轮询实现，最长 [timeout]。
  Future<bool> waitFor(
    String jsExpression, {
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      try {
        final value = await evalSync('!!($jsExpression)');
        if (value == 'true') return true;
      } catch (_) {
        // 页面正在跳转时求值会抛，继续等。
      }
      await Future<void>.delayed(const Duration(milliseconds: 400));
    }
    return false;
  }

  /// 页面可见文本。给 AI 读内容用，比 HTML 省 token 得多。
  Future<String> text({String selector = 'body'}) async {
    return eval('''
var el = document.querySelector(${jsonEncode(selector)});
if (!el) return '（找不到元素：${_esc(selector)}）';
return (el.innerText || el.textContent || '').replace(/\\n{3,}/g, '\\n\\n').trim();
''');
  }

  Future<String> html({String selector = 'html'}) async {
    return eval('''
var el = document.querySelector(${jsonEncode(selector)});
return el ? el.outerHTML : '（找不到元素）';
''');
  }

  /// 在页面上下文里发请求：Cookie / UA / Referer 全部与真实浏览器一致。
  ///
  /// 这就是"过了 CF 之后拿数据"的正确姿势：cf_clearance 是 HttpOnly，
  /// 代码读不到，但浏览器发请求时自己会带上。
  Future<String> fetchInPage({
    required String url,
    String method = 'GET',
    Map<String, dynamic> headers = const {},
    String? body,
    int maxChars = 20000,
  }) async {
    // 跨域的坑：fetch 是**在当前页面里**跑的，浏览器只会带当前站点的 Cookie。
    // 页面停在 A 站却去 fetch B 站，Cookie 一条都带不上（CORS 还可能直接拦），
    // 而返回里只是"空 cookies"，模型会以为是 set-cookie 没生效。先说清楚。
    final warn = _crossOriginWarning(url);
    final out = await eval(
      '''
var res = await fetch(${jsonEncode(url)}, {
  method: ${jsonEncode(method)},
  headers: ${jsonEncode(headers)},
  ${body == null ? '' : 'body: ${jsonEncode(body)},'}
  credentials: 'include'
});
var txt = await res.text();
var sh = [];
try { res.headers.forEach(function(v,k){ sh.push(k + ': ' + v); }); } catch(e){}
return 'HTTP ' + res.status + '\\n' +
  '--- 响应头 ---\\n' + sh.join('\\n') + '\\n' +
  '--- 响应体 ---\\n' + txt.slice(0, $maxChars);
''',
      timeout: const Duration(seconds: 60),
    );
    return warn.isEmpty ? out : '$warn\n\n$out';
  }

  /// 目标地址和当前页面不同源时给一句人话警告，同源返回空串。
  String _crossOriginWarning(String url) {
    final current = currentUrl.value;
    if (current.isEmpty) return '';
    try {
      final base = Uri.parse(current);
      if (!base.hasScheme) return '';
      final target = base.resolve(url);
      if (!target.hasAuthority) return '';
      final same = target.scheme == base.scheme &&
          target.host == base.host &&
          target.port == base.port;
      if (same) return '';
      return '⚠️ 当前页面是 ${base.origin}，你请求的是 ${target.origin}——'
          '这是跨域请求，浏览器**不会**带上 ${target.host} 的 Cookie'
          '（还可能被 CORS 直接拦掉）。'
          '要带登录态就先 browser_open 到 ${target.origin} 再调这个工具。';
    } catch (_) {
      return '';
    }
  }

  /// 页面能看到的 cookie（不含 HttpOnly）。
  Future<String> cookies() => evalSync('document.cookie');

  /// **完整** cookie，含 HttpOnly。走原生 CookieManager，不是 document.cookie。
  ///
  /// 登录票（cf_clearance、各家 session）基本都是 HttpOnly：JS 读不到，
  /// 但浏览器自己存着。这条路把它取出来，AI 就能把登录态交给别的工具用
  /// （比如青龙的环境变量、curl 命令）。
  Future<String> cookiesFull([String? url]) async {
    final target =
        (url == null || url.trim().isEmpty) ? currentUrl.value : url.trim();
    if (target.isEmpty) return '';
    final direct = await WebBridge.cookies(target);
    if (direct.isNotEmpty) return direct;
    // CookieManager 只给"匹配这个 path"的 cookie，站点把票放在 /api 之类的
    // 子路径上时，站在首页问它就是空。退一步直接读内核的库。
    final host = _hostOf(target);
    if (host.isEmpty) return '';
    final rows = await WebBridge.dumpCookies(host);
    return rows
        .where((r) => (r['name']?.toString() ?? '').isNotEmpty)
        .map((r) => '${r['name']}=${r['value'] ?? ''}')
        .join('; ');
  }

  /// 内核库里这个域下的**全部** cookie，带 path / 属性。
  ///
  /// 和 [cookiesFull] 的区别：这条不合并成一行 `a=1; b=2`，而是原样给出
  /// 每条的 host/path/secure/httpOnly——排查"票明明有却读不到"时要看这些。
  Future<List<Map<String, dynamic>>> cookieRows([String? url]) async {
    final target =
        (url == null || url.trim().isEmpty) ? currentUrl.value : url.trim();
    return WebBridge.dumpCookies(_hostOf(target));
  }

  static String _hostOf(String raw) {
    final text = raw.trim();
    if (text.isEmpty) return '';
    final uri = Uri.tryParse(
      text.startsWith('http') ? text : 'https://$text',
    );
    return uri?.host ?? '';
  }

  /// 真的把一个域的 cookie 清干净，返回一句人话 + 是否真清干净。
  ///
  /// ## 为什么要"硬清"
  ///
  /// 现场故障：对 `opencode.ai` / `auth.opencode.ai` 跑 `browser_session reset`，
  /// 两次都回报"已重置为未登录状态、清掉 N 个 Cookie"，可紧接着
  /// `browser_cookies` 一查，`auth`、`authorization` 原封不动还在，重开页面
  /// 还是登录后的密钥页；换 `browser_control logout` 就一次干净。
  ///
  /// 原因：这两条票都是 **HttpOnly**。原来的清法是"按 name 写一条 expires 在
  /// 1970 的 Set-Cookie"——那是脚本侧的删法，内核不允许这种写入覆盖 HttpOnly
  /// 条目，于是普通 cookie（`oc_locale` 之类）被清掉、真正的登录票一条没动，
  /// 计数却照着"库里有几条"报了出去。**报成功但没生效，比失败更坏。**
  ///
  /// 现在分三步，而且以"复查结果"为准：
  /// 1. 先按 name 置过期（温柔、够快，能清的先清掉）；
  /// 2. 再走 [WebBridge.clearCookiesExcept]：整库 `removeAllCookies` + 把**别的
  ///    站点**连 path/domain/Secure/HttpOnly/过期时间原样写回。整库清空是内核
  ///    唯一确定能干掉 HttpOnly 的操作，这也正是 logout 生效的原因；
  /// 3. 复查一遍这个域还剩几条。文案只说复查后的事实。
  Future<({String text, bool clean, int left})> wipeCookies(String host) async {
    if (host.isEmpty) return (text: '没有域名，cookie 没动。', clean: true, left: 0);
    final before = await WebBridge.dumpCookies(host);
    if (before.isEmpty) {
      return (text: '这个域本来就没有 Cookie', clean: true, left: 0);
    }
    final httpOnly = before.where((r) => r['httpOnly'] == true).length;
    // 第 1 步：温柔删。
    await WebBridge.removeCookiesFor(host);
    var left = (await WebBridge.dumpCookies(host)).length;
    final notes = <String>[];
    if (left > 0) {
      // 第 2 步：硬清。HttpOnly 只有这条路能走通。
      final r = await WebBridge.clearCookiesExcept(host);
      left = (await WebBridge.dumpCookies(host)).length;
      final restored = r['restored'] ?? 0;
      final lost = r['lost'] ?? 0;
      notes.add('其中 $httpOnly 条 HttpOnly 只能靠整库清空才删得掉，'
          '已清空并把别的站点 $restored 条 Cookie 原样写回');
      if (lost > 0) {
        notes.add('有 $lost 条别站的 Cookie 因为值被内核加密没能写回，'
            '那些站点可能需要重新登录');
      }
    }
    await WebBridge.flush();
    // 第 3 步：复查。说到底只有这一步的结果算数。
    final text = left == 0
        ? '清掉 ${before.length} 条 Cookie（已复查：这个域现在 0 条）'
            '${notes.isEmpty ? '' : '；${notes.join('；')}'}'
        : '⚠️ Cookie 没清干净：清前 ${before.length} 条，现在还剩 $left 条'
            '${notes.isEmpty ? '' : '；${notes.join('；')}'}'
            '。别把这一步当成功——用 browser_cookies 复查，'
            '必要时改用 browser_control logout（不带 origin，清全部站点）。';
    return (text: text, clean: left == 0, left: left);
  }

  /// 灌一条 cookie 进浏览器（完整 Set-Cookie 串），随即落盘。
  Future<void> putCookie(String url, String value) async {
    await WebBridge.setCookie(url, value);
  }

  /// 立刻把 cookie 写盘。收起浏览器、AI 拿完票时调一次。
  Future<void> persist() => WebBridge.flush();

  /// 退出登录/换账号：清 cookie + 站点数据。[origin] 为空则清全部站点。
  ///
  /// 顺序很讲究，否则"清了跟没清一样，重启 APP 才生效"：
  ///
  /// 1. **先把页面挪到 about:blank**。活着的页面持有 localStorage / JS 内存里
  ///    的 token，卸载时还会往回写；不先赶走它，清完立刻又被它写回来。
  /// 2. 清 cookie（原生侧等 removeAllCookies 回调，不再"说清完了其实没清"）。
  /// 3. 清 WebStorage + 这个 WebView 自己的缓存和 localStorage
  ///    （缓存里躺着带 Set-Cookie 的响应，不清的话刷新就复活）。
  /// 4. 落盘。要恢复现场的话由调用方重开页面。
  Future<String> clearSession({
    String origin = '',
    bool keepPage = false,
  }) async {
    final controller = _controller;
    if (!keepPage && controller != null) {
      try {
        await controller.loadRequest(Uri.parse('about:blank'));
      } catch (_) {
        // 页面正在跳转时会抛，不影响后面的清理。
      }
    }
    var note = '';
    if (origin.isEmpty) {
      await WebBridge.clearCookies();
      await WebBridge.clearStorage();
    } else {
      // 单域 logout 以前也是按 name 置过期，同样清不掉 HttpOnly——
      // 走 wipeCookies（整库清 + 写回别站）才真的干净。
      note = (await wipeCookies(_hostOf(origin))).text;
      await WebBridge.clearOrigin(origin);
    }
    if (controller != null) {
      try {
        await controller.clearCache();
        await controller.clearLocalStorage();
      } catch (_) {}
    }
    await WebBridge.flush();
    return note;
  }

  // ------------------------------------------------------------ 换账号

  /// 把一个站点彻底恢复成"从没来过"的状态，然后（可选）重新打开它。
  ///
  /// 为什么需要专门一个动作：换账号时光清 cookie 往往不够。现在的站点把登录态
  /// 摊在四个地方——cookie、localStorage、sessionStorage、内存里的 JS 变量。
  /// 只 removeAllCookies 的话，页面一刷新就用 localStorage 里的 refresh token
  /// 把自己重新登回去，用户会觉得"清了也没用"。所以这条按顺序做四件事：
  ///
  /// 1. 精确删这个域的 cookie（一条条置过期，比 removeAllCookies 温柔：
  ///    别的站点的登录态不受影响）；
  /// 2. 删 WebStorage 里这个 origin 的数据（localStorage / IndexedDB）；
  /// 3. 页面上下文再清一遍 localStorage / sessionStorage（第 2 步对
  ///    sessionStorage 不保证，而登录票很常放那儿）；
  /// 4. 落盘，再按需要重开页面——重开之后拿到的就是干净的登录页。
  ///
  /// [wipeAll] 为真时退化成"清全部站点"（用户明确说"全部退出"时才用）。
  Future<String> resetSite({
    String url = '',
    bool reopen = true,
    bool wipeAll = false,
  }) async {
    final target = url.trim().isEmpty ? currentUrl.value : url.trim();
    if (wipeAll) {
      await clearSession();
      if (reopen && target.isNotEmpty) await open(target);
      return '已清空全部站点的 Cookie、本地存储与缓存（当前页已重置）'
          '${reopen && target.isNotEmpty ? '，并重新打开 $target' : ''}。';
    }
    if (target.isEmpty) {
      return '没有目标站点：先 browser_open，或者显式给 url。';
    }
    Uri uri;
    try {
      uri = Uri.parse(target.startsWith('http') ? target : 'https://$target');
    } catch (_) {
      return '地址解析不了：$target';
    }
    final origin = '${uri.scheme}://${uri.host}'
        '${uri.hasPort ? ':${uri.port}' : ''}';
    final steps = <String>[];

    // 1. cookie。温柔删 → 硬清 → **复查**，一条龙都在 wipeCookies 里。
    //
    // 这里以前是自己按 name 写过期串，对 HttpOnly 的登录票完全无效，
    // 却照样报"清掉 N 个 Cookie"（见 wipeCookies 的注释）。
    final cookieWipe = await wipeCookies(uri.host);
    steps.add(cookieWipe.text);

    // 2 + 3. 站点数据。页面侧那一遍必须在还停留在该站点时做，
    // 否则清的是新页面的存储。
    await WebBridge.clearOrigin(origin);
    if (currentUrl.value.contains(uri.host) && isReady) {
      try {
        await eval('''
try { localStorage.clear(); } catch(e) {}
try { sessionStorage.clear(); } catch(e) {}
return 'ok';
''', timeout: const Duration(seconds: 8));
        steps.add('清掉 localStorage / sessionStorage');
      } catch (_) {
        steps.add('localStorage 清理失败（页面可能正在跳转）');
      }
    } else {
      steps.add('清掉站点存储');
    }

    // 4. 把还活着的页面赶走再落盘：不这么做，它卸载时会把内存里的 token
    // 重新写进 localStorage，用户就会觉得"清了也没用，要重启 APP"。
    final controller = _controller;
    if (controller != null && currentUrl.value.contains(uri.host)) {
      try {
        await controller.loadRequest(Uri.parse('about:blank'));
        await controller.clearCache();
      } catch (_) {}
    }
    await WebBridge.flush();
    if (reopen) {
      await open(origin == target ? origin : target);
      steps.add('已重新打开 $target');
    }
    if (!cookieWipe.clean) {
      // 复查发现还有票在，就绝不能说"已重置为未登录状态"。
      return '$origin 重置**没做干净**：${steps.join('、')}。'
          '登录态可能还在，请用 browser_cookies 复查；'
          '要彻底清就用 browser_control logout。';
    }
    return '$origin 已重置为未登录状态（Cookie 已复查为 0 条）：${steps.join('、')}。'
        '${reopen ? '现在可以登录另一个账号了。' : '下次打开就是登录页。'}';
  }

  /// 一次灌入多条 cookie，用来"没有账号密码但有 cookie"的场景。
  ///
  /// [raw] 接受两种写法：
  /// - 浏览器 devtools 里复制的一整行 `a=1; b=2`（最常见）；
  /// - 一条完整 Set-Cookie（带 path/domain/expires）；多条用换行分隔。
  ///
  /// 灌完立刻落盘，并回报浏览器实际收下了哪些——写进去和收下来经常不一样
  /// （domain 不匹配、Secure 属性对 http 页面无效），不回报的话查不出来。
  Future<String> injectCookies(String url, String raw) async {
    final target = url.trim().isEmpty ? currentUrl.value : url.trim();
    if (target.isEmpty) return '没有地址：先 browser_open，或者显式给 url。';
    final text = raw.trim();
    if (text.isEmpty) return 'cookie 内容为空。';
    final entries = <String>[];
    for (final line in text.split(RegExp(r'[\r\n]+'))) {
      final piece = line.trim();
      if (piece.isEmpty) continue;
      // 带属性的当成一条完整 Set-Cookie；否则按 `a=1; b=2` 拆开。
      final hasAttrs = RegExp(
        r';\s*(path|domain|expires|max-age|secure|httponly|samesite)\s*=?',
        caseSensitive: false,
      ).hasMatch(piece);
      if (hasAttrs) {
        entries.add(piece);
      } else {
        entries.addAll(
          piece.split(';').map((c) => c.trim()).where((c) => c.contains('=')),
        );
      }
    }
    if (entries.isEmpty) return '没解析出任何 cookie（要形如 name=value）。';
    final uri = Uri.tryParse(
      target.startsWith('http') ? target : 'https://$target',
    );
    for (final entry in entries) {
      // 不带 path 的补一个：不写 path 时 WebView 会按当前路径存，
      // 换个页面就读不到了。
      final withPath = RegExp(r'path\s*=', caseSensitive: false).hasMatch(entry)
          ? entry
          : '$entry; path=/';
      await WebBridge.setCookie(target, withPath);
    }
    await WebBridge.flush();
    final after = await WebBridge.cookies(target);
    final accepted = after
        .split(';')
        .map((c) => c.split('=').first.trim())
        .where((n) => n.isNotEmpty)
        .toSet();
    final wanted = entries
        .map((e) => e.split('=').first.trim())
        .where((n) => n.isNotEmpty)
        .toSet();
    final missing = wanted.difference(accepted);
    return [
      '已向 $target 写入 ${entries.length} 条 cookie 并落盘。',
      '浏览器现在持有：${accepted.join('、')}',
      if (missing.isNotEmpty)
        '没被收下：${missing.join('、')}'
            '（常见原因：domain 和 ${uri?.host ?? target} 不匹配，'
            '或带了 Secure 但页面是 http）',
      '接着 browser_open 打开目标页看是不是已登录；'
          '登录态在 localStorage 里的站点还要用 browser_storage 补写。',
    ].join('\n');
  }

  // -------------------------------------------------------- 抓包改写脚本

  /// 脚本表。顺序即执行顺序：前一个脚本改过的请求交给后一个，
  /// 谁先把包拦掉或假返回，后面的就不跑了。
  final List<InterceptScript> _scripts = [];
  final ValueNotifier<int> scriptsRevision = ValueNotifier(0);

  List<InterceptScript> get scripts => List.unmodifiable(_scripts);

  int _scriptSeq = 0;

  /// 把脚本表推进页面。页面侧只认这一份，Dart 侧是唯一真相。
  Future<void> _pushScripts() async {
    final c = _controller;
    if (c == null) return;
    final payload = jsonEncode([for (final it in _scripts) it.toPageJson()]);
    try {
      await c.runJavaScript(
        'if (window.__qlSetScripts) window.__qlSetScripts($payload);',
      );
    } catch (e) {
      Logger.e('browser', 'push scripts failed', e);
    }
  }

  Future<void> loadScripts() async {
    try {
      final raw = await SecureStorage.readBrowserScripts();
      if (raw == null || raw.trim().isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is! List) return;
      _scripts
        ..clear()
        ..addAll([
          for (final item in decoded)
            if (item is Map)
              InterceptScript.fromJson(
                item.map((k, v) => MapEntry(k.toString(), v)),
                fallbackId: ++_scriptSeq,
              ),
        ]);
      for (final it in _scripts) {
        if (it.id > _scriptSeq) _scriptSeq = it.id;
      }
      scriptsRevision.value++;
      await _pushScripts();
    } catch (e) {
      Logger.e('browser', 'load scripts failed', e);
    }
  }

  Future<void> _saveScripts() async {
    try {
      await SecureStorage.saveBrowserScripts(
        jsonEncode([for (final it in _scripts) it.toJson()]),
      );
    } catch (e) {
      Logger.e('browser', 'save scripts failed', e);
    }
  }

  InterceptScript? scriptById(int id) {
    for (final it in _scripts) {
      if (it.id == id) return it;
    }
    return null;
  }

  /// 加一个脚本。返回说明，或者以 '脚本无效：' 开头的错误。
  Future<String> addScript({
    required String name,
    required String code,
    bool enabled = true,
  }) async {
    final script = InterceptScript(
      id: ++_scriptSeq,
      name: name.trim(),
      code: code,
      enabled: enabled,
    );
    final problem = script.validate();
    if (problem.isNotEmpty) {
      _scriptSeq--;
      return '脚本无效：$problem';
    }
    _scripts.add(script);
    scriptsRevision.value++;
    await _saveScripts();
    await _pushScripts();
    return '已加脚本 #${script.id}：${script.summary}';
  }

  /// 改脚本。只传要改的字段。
  Future<String> updateScript(
    int id, {
    String? name,
    String? code,
    bool? enabled,
  }) async {
    final index = _scripts.indexWhere((it) => it.id == id);
    if (index < 0) return '没有 #$id 这个脚本';
    final next = _scripts[index].copyWith(
      name: name?.trim(),
      code: code,
      enabled: enabled,
    );
    final problem = next.validate();
    if (problem.isNotEmpty) return '脚本无效：$problem';
    // 代码变了就把上一轮的报错和命中数清掉，否则旧错误会一直挂着误导人。
    if (code != null && code != _scripts[index].code) {
      next
        ..error = ''
        ..hits = 0;
    }
    _scripts[index] = next;
    scriptsRevision.value++;
    await _saveScripts();
    await _pushScripts();
    return '已更新脚本 #$id：${next.summary}';
  }

  Future<bool> removeScript(int id) async {
    final before = _scripts.length;
    _scripts.removeWhere((it) => it.id == id);
    if (_scripts.length == before) return false;
    scriptsRevision.value++;
    await _saveScripts();
    await _pushScripts();
    return true;
  }

  Future<void> clearScripts() async {
    _scripts.clear();
    scriptsRevision.value++;
    await _saveScripts();
    await _pushScripts();
  }

  Future<bool> back() async {
    final c = _controller;
    if (c == null) return false;
    if (!await c.canGoBack()) return false;
    await c.goBack();
    return true;
  }

  Future<bool> forward() async {
    final c = _controller;
    if (c == null) return false;
    if (!await c.canGoForward()) return false;
    await c.goForward();
    return true;
  }

  /// 内核信息（WebView 包名/版本/是否收 cookie）。
  Future<Map<String, dynamic>> engineInfo() => WebBridge.info();

  /// localStorage / sessionStorage 全量导出。
  ///
  /// 现在的站点登录态一半在 cookie、一半在 localStorage（JWT、refresh token
  /// 常放这儿）。要"保存登录状态"就必须连它一起看。
  Future<String> storageDump() => eval('''
function dump(store){
  var out = {};
  for (var i = 0; i < store.length; i++) {
    var k = store.key(i);
    var v = store.getItem(k) || '';
    out[k] = v.length > 2000 ? v.slice(0, 2000) + '…' : v;
  }
  return out;
}
return JSON.stringify({
  origin: location.origin,
  localStorage: dump(localStorage),
  sessionStorage: dump(sessionStorage)
}, null, 2);
''');

  /// 往 localStorage / sessionStorage 里写值（恢复登录态用）。
  Future<String> storageSet(
    Map<String, String> values, {
    bool session = false,
  }) =>
      eval('''
var store = ${session ? 'sessionStorage' : 'localStorage'};
var data = ${jsonEncode(values)};
var n = 0;
for (var k in data) { store.setItem(k, data[k]); n++; }
return '已写入 ' + n + ' 项到 ${session ? 'sessionStorage' : 'localStorage'}';
''');

  /// 页面加载过的全部资源（脚本、样式、图片、XHR、字体…）。
  ///
  /// 和 [requests] 不同：那份只记页面自己发的 fetch/XHR，这份来自浏览器的
  /// Resource Timing，**连子资源一起**——要找"某个 js 里藏的接口地址"、
  /// "这页到底加载了哪些包"就靠它。
  Future<String> resourceList({String filter = '', int limit = 120}) => eval('''
var list = performance.getEntriesByType('resource').map(function(e){
  return {url: e.name, type: e.initiatorType, ms: Math.round(e.duration),
          size: e.transferSize || e.encodedBodySize || 0};
});
var f = ${jsonEncode(filter.toLowerCase())};
if (f) list = list.filter(function(e){ return e.url.toLowerCase().indexOf(f) >= 0; });
list = list.slice(-$limit);
return list.map(function(e){
  return '[' + e.type + '] ' + e.size + 'B ' + e.ms + 'ms ' + e.url;
}).join(String.fromCharCode(10)) || '（没有匹配的资源）';
''');

  /// 把页面里的一个资源下载到 APP 私有目录，返回本地路径。
  ///
  /// 走的是**页面上下文**的 fetch，所以 Cookie / Referer / CF 票全带上——
  /// 那些"直接用 curl 下就 403"的文件这样才拿得到。二进制经 base64 过桥，
  /// 所以给了体积上限：桥是 JSON 通道，几十兆会把内存顶爆。
  Future<String> download(String url, {int maxBytes = 6 * 1024 * 1024}) async {
    final meta = await eval(
      '''
var res = await fetch(${jsonEncode(url)}, {credentials: 'include'});
if (!res.ok) return JSON.stringify({err: 'HTTP ' + res.status});
var buf = await res.arrayBuffer();
if (buf.byteLength > $maxBytes) {
  return JSON.stringify({err: '文件 ' + buf.byteLength + ' 字节，超过上限 $maxBytes'});
}
var bytes = new Uint8Array(buf), chunk = 0x8000, parts = [];
for (var i = 0; i < bytes.length; i += chunk) {
  parts.push(String.fromCharCode.apply(null, bytes.subarray(i, i + chunk)));
}
return JSON.stringify({
  b64: btoa(parts.join('')),
  ct: res.headers.get('content-type') || '',
  size: bytes.length
});
''',
      timeout: const Duration(seconds: 120),
    );
    Map<String, dynamic> json;
    try {
      final decoded = jsonDecode(meta);
      json = decoded is Map<String, dynamic> ? decoded : {};
    } catch (_) {
      return '下载失败：返回内容不是预期格式。';
    }
    final err = json['err']?.toString() ?? '';
    if (err.isNotEmpty) return '下载失败：$err';
    final b64 = json['b64']?.toString() ?? '';
    if (b64.isEmpty) return '下载失败：内容为空。';
    final dir = await getApplicationDocumentsDirectory();
    final folder = Directory('${dir.path}/browser_downloads');
    if (!folder.existsSync()) folder.createSync(recursive: true);
    var name = Uri.parse(url).pathSegments.isEmpty
        ? 'download'
        : Uri.parse(url).pathSegments.last;
    if (name.isEmpty) name = 'download';
    // 文件名里带 query/非法字符会写不进去。
    name = name.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    final file = File('${folder.path}/$name');
    await file.writeAsBytes(base64Decode(b64));
    return '已保存：${file.path}\n类型：${json['ct']}\n大小：${json['size']} 字节';
  }

  // ------------------------------------------------------- 让用户接手

  /// 把浏览器亮给用户，等他处理完（点验证码、登录、填表）再继续。
  ///
  /// 返回用户点"完成"时的说明，或超时提示。
  Future<String> askUser(String hint,
      {Duration timeout = const Duration(minutes: 10)}) async {
    await ensure();
    waitingHint.value = hint;
    // 请用户接手 = 窗口从此归用户：他点完验证多半还想自己看两眼，
    // 任务一结束就把窗口收走会很讨人嫌。
    show();
    final completer = Completer<String>();
    _userAck = completer;
    final deadline = DateTime.now().add(timeout);
    try {
      while (!completer.isCompleted) {
        if (DateTime.now().isAfter(deadline)) {
          return '用户在 ${timeout.inMinutes} 分钟内没有确认。';
        }
        await Future<void>.delayed(const Duration(milliseconds: 500));
        if (completer.isCompleted) break;
      }
      return await completer.future;
    } finally {
      waitingHint.value = '';
      if (_userAck == completer) _userAck = null;
    }
  }

  /// 用户点"我处理好了"。
  void ackUser([String note = '']) {
    final completer = _userAck;
    waitingHint.value = '';
    if (completer != null && !completer.isCompleted) {
      completer.complete(note.isEmpty ? '用户已确认处理完毕。' : note);
    }
  }

  bool get isWaitingUser => waitingHint.value.isNotEmpty;

  /// 这个窗口现在是"AI 借用的"还是"用户自己的"。
  ///
  /// 区分的意义只有一个：任务干完了要不要自动收起。AI 为了办事亮出来的窗口，
  /// 事办完就该自己收走，不该赖在屏幕上让用户手动关；但用户自己点开的浏览器，
  /// 或者他已经上手操作过的窗口，谁也不许替他关。
  bool _agentOwned = false;

  void show({bool byAgent = false}) {
    ensure();
    // 已经开着的窗口，所有权只会从 AI 转给用户，不会反过来：
    // 用户开着的窗口不能因为 AI 顺手调了一次 show 就变成"可自动收起"。
    if (!visible.value) {
      _agentOwned = byAgent;
    } else if (!byAgent) {
      _agentOwned = false;
    }
    visible.value = true;
    // 新亮出来的窗口置前：不然它可能生在聊天窗底下，
    // 用户被要求"去点一下人机验证"却点不到。
    FloatStack.instance.raise(FloatStack.browser);
  }

  /// 用户上手动了这个窗口（输网址、切标签、拖动、最大化）。
  /// 从这一刻起它归用户，任务结束也不收。
  void claimByUser() => _agentOwned = false;

  /// 一轮任务收尾：AI 自己借的窗口收起来。
  ///
  /// 收之前一定先落盘。用户很可能刚在里面登录完，内存里的 Cookie 还没写到
  /// 磁盘，进程被系统回收就白登了。
  Future<void> settleAfterRun() async {
    if (!visible.value || !_agentOwned) return;
    // 还在等用户操作就不能收：那正是需要他看见窗口的时候。
    if (isWaitingUser) return;
    _agentOwned = false;
    await persist();
    visible.value = false;
  }

  void hide() {
    _agentOwned = false;
    visible.value = false;
  }

  /// 窗口形态：AI 也能切（比如"页面太挤了，先全屏"）。
  void maximize() => BrowserWindow.instance.value =
      BrowserWindow.instance.value.copyWith(mode: BrowserWindowMode.maximized);

  void restore() => BrowserWindow.instance.value =
      BrowserWindow.instance.value.copyWith(mode: BrowserWindowMode.floating);

  void clearCaptures() {
    requests.value = [];
    console.value = [];
  }

  static String _esc(String value) => value.replaceAll("'", r"\'");

  /// runJavaScriptReturningResult 在 Android 上会把字符串连引号一起返回。
  static String _unquote(String raw) {
    var text = raw;
    if (text.length >= 2 && text.startsWith('"') && text.endsWith('"')) {
      try {
        final decoded = jsonDecode(text);
        if (decoded is String) return decoded;
      } catch (_) {
        text = text.substring(1, text.length - 1);
      }
    }
    return text;
  }
}
