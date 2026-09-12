import 'dart:convert';

import '../ai/agent/external_tool.dart';
import '../../core/local_shell/shell_lock.dart';
import 'browser_engine.dart';

/// 把浏览器内核包成 AI 工具。
///
/// 设计取舍：不做"一个 browser 万能工具"，而是拆成语义清楚的几个。模型选工具
/// 靠名字和描述，一个塞满 action 枚举的巨型工具它经常填错参数。
class BrowserTools {
  BrowserTools._();

  static List<ExternalTool> build() {
    final engine = BrowserEngine.instance;
    const origin = '内置浏览器';

    Map<String, dynamic> obj(
      List<String> required,
      Map<String, dynamic> props,
    ) =>
        {'type': 'object', 'properties': props, 'required': required};

    // 浏览器内核全 APP 只有一个：两个代理同时用就会互相换页面
    // （A 刚导航到登录页，B 一句 open 把页面顶掉，A 读到的是别人的 DOM）。
    // 统一在这里排队，各工具的实现不用各自操心。
    List<ExternalTool> serialize(List<ExternalTool> tools) => [
          for (final t in tools)
            ExternalTool(
              name: t.name,
              description: t.description,
              parameters: t.parameters,
              isWrite: t.isWrite,
              danger: t.danger,
              origin: t.origin,
              invoke: (args) => ShellLock.run(
                ShellLock.browser,
                () => t.invoke(args),
                label: t.name,
                // 浏览器操作可能要等用户过人机验证，排队上限给得宽一些。
                timeout: const Duration(minutes: 6),
              ),
            ),
        ];

    return serialize([
      ExternalTool(
        name: 'browser_open',
        description: '用内置浏览器内核打开一个网址，返回页面标题和可见文本。'
            '比 web_fetch 强的地方：它是真浏览器，会执行 JS、保留登录态和 Cookie，'
            '所以能拿到前端渲染出来的内容。遇到 Cloudflare 人机验证/登录墙时，'
            '配合 browser_wait_user 让用户点一下即可。'
            '也能打开本地文件：url 传 /workspace/x.html（或 file:///…）'
            '就会渲染终端工作目录里的网页——自己写完 html 想让用户看效果时'
            '配 show=true 直接弹出来。',
        parameters: obj([
          'url'
        ], {
          'url': {
            'type': 'string',
            'description': '网址，或本地网页路径（/workspace/x.html、file:///…）',
          },
          'wait_selector': {
            'type': 'string',
            'description': '可选：等这个 CSS 选择器出现再返回（内容靠 JS 渲染时用）',
          },
          'max_chars': {'type': 'integer', 'description': '正文最多返回多少字符，默认 8000'},
          'show': {
            'type': 'boolean',
            'description': '是否同时把浏览器显示给用户看，默认 false（后台打开）',
          },
        }),
        origin: origin,
        invoke: (args) async {
          final url = args['url']?.toString().trim() ?? '';
          if (url.isEmpty) return '网址为空。';
          if (args['show'] == true) engine.show(byAgent: true);
          await engine.open(url);
          final selector = args['wait_selector']?.toString() ?? '';
          if (selector.isNotEmpty) {
            final ok = await engine.waitFor(
              'document.querySelector(${jsonEncode(selector)})',
            );
            if (!ok) {
              return '页面已打开（${engine.currentUrl.value}），但等不到 $selector。'
                  '可能是被人机验证挡住了，或者选择器不对。'
                  '可以用 browser_capture 看抓到的请求，或 browser_wait_user 让用户看一眼。';
            }
          } else {
            await engine.waitFor('document.readyState === "complete"');
          }
          final max = (args['max_chars'] as num?)?.toInt() ?? 8000;
          final text = await engine.text();
          return [
            '标题：${engine.title.value}',
            '地址：${engine.currentUrl.value}',
            '',
            text.length > max ? '${text.substring(0, max)}\n…（正文已截断）' : text,
          ].join('\n');
        },
      ),
      ExternalTool(
        name: 'browser_read',
        description: '读当前页面的文本或 HTML（可指定 CSS 选择器）。页面变化后重新读用它，'
            '不用重新打开。',
        parameters: obj([], {
          'selector': {'type': 'string', 'description': 'CSS 选择器，默认 body'},
          'as_html': {'type': 'boolean', 'description': 'true 返回 HTML，默认返回纯文本'},
          'max_chars': {'type': 'integer', 'description': '默认 8000'},
        }),
        origin: origin,
        invoke: (args) async {
          if (!engine.isReady) return '浏览器还没打开过页面，先用 browser_open。';
          final selector = args['selector']?.toString() ?? '';
          final asHtml = args['as_html'] == true;
          final body = asHtml
              ? await engine.html(
                  selector: selector.isEmpty ? 'html' : selector)
              : await engine.text(
                  selector: selector.isEmpty ? 'body' : selector);
          final max = (args['max_chars'] as num?)?.toInt() ?? 8000;
          return body.length > max
              ? '${body.substring(0, max)}\n…（已截断，共 ${body.length} 字符）'
              : body;
        },
      ),
      ExternalTool(
        name: 'browser_script',
        description: '在当前页面里执行 JS 并拿回结果（函数体，用 return 交结果，支持 await）。'
            '用来点按钮、填表、滚动加载、取结构化数据。'
            '例：`document.querySelector("#login").click(); return "clicked";`',
        parameters: obj([
          'script'
        ], {
          'script': {'type': 'string', 'description': 'JS 函数体，用 return 返回结果'},
          'timeout_s': {'type': 'integer', 'description': '超时秒数，默认 30'},
        }),
        origin: origin,
        // 能改页面状态、能点下单按钮，算危险写操作。
        isWrite: true,
        danger: true,
        invoke: (args) async {
          if (!engine.isReady) return '浏览器还没打开过页面，先用 browser_open。';
          final script = args['script']?.toString() ?? '';
          if (script.trim().isEmpty) return '脚本为空。';
          final seconds = (args['timeout_s'] as num?)?.toInt() ?? 30;
          final value = await engine.eval(
            script,
            timeout: Duration(seconds: seconds),
          );
          return value.isEmpty ? '（脚本执行完毕，没有返回值）' : value;
        },
      ),
      ExternalTool(
        name: 'browser_fetch',
        description: '在当前页面的上下文里发一个 HTTP 请求，带上浏览器的全部 Cookie 与 UA，'
            '返回 **状态行 + 响应头原文 + 响应体**。'
            '过了人机验证/登录之后要调接口拿数据，必须用这个而不是 web_fetch——'
            'cf_clearance 之类的票是 HttpOnly，只有浏览器自己带得上。'
            '想看某个地址完整的响应头（包括 set-cookie 之外的缓存/鉴权头），'
            '也用这个重发一次最直接。'
            '**必须先 browser_open 到目标站点**：请求是在当前页面里发的，'
            '页面停在别的域时带不上目标域的 Cookie（会被当成跨域）。',
        parameters: obj([
          'url'
        ], {
          'url': {'type': 'string', 'description': '请求地址（可用相对路径）'},
          'method': {'type': 'string', 'description': 'GET/POST…，默认 GET'},
          'headers': {'type': 'object', 'description': '额外请求头'},
          'body': {'type': 'string', 'description': '请求体（POST 时）'},
          'max_chars': {'type': 'integer', 'description': '默认 20000'},
        }),
        origin: origin,
        invoke: (args) async {
          if (!engine.isReady) {
            return '浏览器还没打开过页面，先 browser_open 到目标站点（同源才带得上 Cookie）。';
          }
          final headers = args['headers'];
          return engine.fetchInPage(
            url: args['url']?.toString() ?? '',
            method: args['method']?.toString() ?? 'GET',
            headers: headers is Map
                ? headers.map((k, v) => MapEntry(k.toString(), v))
                : const {},
            body: args['body']?.toString(),
            maxChars: (args['max_chars'] as num?)?.toInt() ?? 20000,
          );
        },
      ),
      ExternalTool(
        name: 'browser_capture',
        description: '看浏览器抓到的网络请求（页面自己发的 fetch/XHR，'
            '含地址、请求头、请求体、响应头、响应体）。'
            '想要的数据经常在某个接口的 JSON 里而不在 HTML 上——先抓包找到那个接口，'
            '再用 browser_fetch 直接调它，比解析 HTML 稳得多。',
        parameters: obj([], {
          'filter': {'type': 'string', 'description': '只看 URL 含这个关键字的请求'},
          'limit': {'type': 'integer', 'description': '最多几条，默认 20'},
          'with_body': {
            'type': 'boolean',
            'description': 'true 时附上返回体（会很长），默认只给概要',
          },
          'with_headers': {
            'type': 'boolean',
            'description': 'true 时附上请求头与响应头。'
                '查鉴权（Authorization/Cookie）、签名头、缓存策略时必须开',
          },
          'body_chars': {
            'type': 'integer',
            'description': '每条返回体最多多少字符，默认 2000'
          },
        }),
        origin: origin,
        invoke: (args) async {
          final filter = args['filter']?.toString().toLowerCase() ?? '';
          final limit = (args['limit'] as num?)?.toInt() ?? 20;
          final withBody = args['with_body'] == true;
          final withHeaders = args['with_headers'] == true;
          final bodyChars = (args['body_chars'] as num?)?.toInt() ?? 2000;
          final list = engine.requests.value
              .where(
                  (r) => filter.isEmpty || r.url.toLowerCase().contains(filter))
              .take(limit)
              .toList();
          if (list.isEmpty) {
            return engine.requests.value.isEmpty
                ? '还没抓到任何请求。先 browser_open 打开页面；'
                    '静态页面可能确实一个 XHR 都没有。'
                : '没有匹配 "$filter" 的请求（共抓到 ${engine.requests.value.length} 条）。';
          }
          final lines = <String>[
            '共 ${engine.requests.value.length} 条，显示 ${list.length} 条（新→旧）：',
          ];
          for (final r in list) {
            lines.add(
              '[${r.kind}] ${r.method} ${r.status == 0 ? '进行中' : r.status} '
              '${r.ms}ms ${r.url}',
            );
            if (withHeaders && r.requestHeaders.isNotEmpty) {
              lines.add('  请求头：${_clip(r.requestHeaders, 1200)}');
            }
            if (r.requestBody.isNotEmpty) {
              lines.add('  请求体：${_clip(r.requestBody, 500)}');
            }
            if (withHeaders && r.responseHeaders.isNotEmpty) {
              lines.add('  响应头：${_clip(r.responseHeaders, 1200)}');
            }
            if (withBody && r.responseBody.isNotEmpty) {
              lines.add('  响应体：${_clip(r.responseBody, bodyChars)}');
            } else if (r.responseBody.isNotEmpty) {
              lines.add('  响应体：${r.responseBody.length} 字符'
                  '（要看内容加 with_body:true）');
            }
            if (!withHeaders &&
                (r.requestHeaders.isNotEmpty || r.responseHeaders.isNotEmpty)) {
              lines.add('  （有请求头/响应头，加 with_headers:true 才展开）');
            }
            if (withHeaders &&
                r.kind == 'doc' &&
                r.requestHeaders.isEmpty &&
                r.responseHeaders.isEmpty) {
              lines.add('  （doc = 地址栏导航，浏览器内核不暴露它的头；'
                  '要头就用 browser_fetch 重发一次这个地址）');
            }
            if (r.error.isNotEmpty) lines.add('  出错：${r.error}');
          }
          return lines.join('\n');
        },
      ),
      ExternalTool(
        name: 'browser_cookies',
        description: '读/写浏览器的 Cookie，**包含 HttpOnly**（cf_clearance、'
            '各家的 session 票都是 HttpOnly，document.cookie 读不到，这个能读到）。'
            'action=get 读、set 写、clear 清空。'
            '拿到票之后可以交给别的工具用（比如写进青龙的环境变量、拼 curl）。',
        parameters: obj([], {
          'action': {
            'type': 'string',
            'enum': ['get', 'set', 'clear'],
            'description': '默认 get',
          },
          'url': {'type': 'string', 'description': '哪个地址下的 Cookie，默认当前页'},
          'value': {
            'type': 'string',
            'description': 'action=set 时的完整 Set-Cookie 串，如 '
                'token=abc; path=/; domain=.example.com',
          },
        }),
        origin: origin,
        // set/clear 会改登录态，算写操作；get 只读。
        isWrite: true,
        invoke: (args) async {
          final action = args['action']?.toString() ?? 'get';
          final url = args['url']?.toString() ?? '';
          switch (action) {
            case 'set':
              final value = args['value']?.toString() ?? '';
              if (value.isEmpty) return 'value 为空，写不了。';
              final target = url.isEmpty ? engine.currentUrl.value : url;
              if (target.isEmpty) return '没有地址：先 browser_open，或显式给 url。';
              await engine.putCookie(target, value);
              // 写完必须回读校验：domain 不匹配、对 http 页面写 Secure、
              // 名字带非法字符，内核都是**静默丢弃**，不回读就以为写成了。
              final name = value.split(';').first.split('=').first.trim();
              final back = await engine.cookiesFull(target);
              final ok = name.isNotEmpty && back.contains('$name=');
              return ok
                  ? '已写入并落盘（回读确认 $name 在了）。'
                  : '写了，但回读**没找到** $name。常见原因：domain 和目标域不匹配、'
                      '带了 Secure 但页面是 http、或者 path 不含当前路径。'
                      '现在这个地址下的 cookie：${back.isEmpty ? '（空）' : back}';
            case 'clear':
              await engine.clearSession();
              return '已清空全部 Cookie、站点存储与缓存，当前页已重置为空白页'
                  '（立即生效，不用重启 APP）。要回到原站点用 browser_open。';
            default:
              final target = url.isEmpty ? engine.currentUrl.value : url;
              final full = await engine.cookiesFull(url.isEmpty ? null : url);
              final rows = await engine.cookieRows(url.isEmpty ? null : url);
              if (full.isEmpty && rows.isEmpty) {
                return '这个地址（${target.isEmpty ? '未指定' : target}）下没有 Cookie。'
                    '${target.isEmpty ? '先 browser_open 到目标站点，或显式给 url。' : '确认已经登录过这个域；'
                        '注意 cookie 是按域存的，m.x.com 和 x.com 可能各存一份。'}';
              }
              final visible = await engine.cookies();
              final httpOnly = full
                  .split('; ')
                  .where((c) => !visible.contains(c.split('=').first))
                  .map((c) => c.split('=').first)
                  .where((n) => n.isNotEmpty)
                  .toList();
              // 子路径上的票（/api、/eapi 这类）用 document.cookie 和
              // getCookie(首页) 都读不到，只有内核库里有——单独列出来。
              final scoped = rows
                  .where((r) => (r['path']?.toString() ?? '/') != '/')
                  .map((r) => '${r['name']}（path=${r['path']}）')
                  .toList();
              final encrypted =
                  rows.where((r) => r['encrypted'] == true).length;
              return [
                '地址：${target.isEmpty ? '（当前页为空）' : target}',
                if (full.isNotEmpty) ...['完整 Cookie（含 HttpOnly）：', full],
                if (httpOnly.isNotEmpty) '其中 HttpOnly：${httpOnly.join(', ')}',
                if (rows.isNotEmpty) '内核库里这个域共 ${rows.length} 条。',
                if (scoped.isNotEmpty)
                  '只在子路径上生效的：${scoped.join('、')}'
                      '（拼请求时要带上对应路径，不然发不出去）',
                if (encrypted > 0)
                  '有 $encrypted 条被内核加密存储，读不出明文——'
                      '这些票只能在浏览器里用，导不出去。',
              ].join('\n');
          }
        },
      ),
      ExternalTool(
        name: 'browser_storage',
        description: '读/写页面的 localStorage 与 sessionStorage。'
            '现在的登录态一半在 Cookie、一半在 localStorage（JWT、refresh token 常放这儿），'
            '要完整保存或恢复登录状态就得连它一起处理。action=get 导出全部，set 写入。',
        parameters: obj([], {
          'action': {
            'type': 'string',
            'enum': ['get', 'set'],
            'description': '默认 get'
          },
          'values': {
            'type': 'object',
            'description': 'action=set 时要写的键值对（值必须是字符串）',
          },
          'session': {
            'type': 'boolean',
            'description': 'true 操作 sessionStorage，默认 localStorage',
          },
        }),
        origin: origin,
        isWrite: true,
        invoke: (args) async {
          if (!engine.isReady) return '浏览器还没打开过页面，先用 browser_open。';
          if (args['action']?.toString() == 'set') {
            final raw = args['values'];
            if (raw is! Map || raw.isEmpty) return 'values 为空。';
            return engine.storageSet(
              raw.map((k, v) => MapEntry(k.toString(), v?.toString() ?? '')),
              session: args['session'] == true,
            );
          }
          return engine.storageDump();
        },
      ),
      ExternalTool(
        name: 'browser_resources',
        description: '列出这个页面加载过的**全部资源**（脚本、样式、图片、XHR、字体…）'
            '含地址、类型、体积、耗时。'
            'browser_capture 只记页面自己发的 fetch/XHR，这个连子资源一起给——'
            '要找"接口地址藏在哪个 js 里""这页到底加载了哪些包"用它。',
        parameters: obj([], {
          'filter': {'type': 'string', 'description': '只看地址含这个关键字的'},
          'limit': {'type': 'integer', 'description': '最多几条，默认 120'},
        }),
        origin: origin,
        invoke: (args) async {
          if (!engine.isReady) return '浏览器还没打开过页面，先用 browser_open。';
          return engine.resourceList(
            filter: args['filter']?.toString() ?? '',
            limit: (args['limit'] as num?)?.toInt() ?? 120,
          );
        },
      ),
      ExternalTool(
        name: 'browser_download',
        description: '把页面里的某个资源下载到本机（APP 私有目录），返回本地路径。'
            '走页面上下文发请求，Cookie/Referer/验证票全带上——'
            '那些"直接下就 403"的文件只能这样拿。下完可以用文件工具读它。',
        parameters: obj([
          'url'
        ], {
          'url': {'type': 'string', 'description': '资源地址（可相对路径）'},
          'max_mb': {'type': 'integer', 'description': '体积上限 MB，默认 6'},
        }),
        origin: origin,
        isWrite: true,
        invoke: (args) async {
          if (!engine.isReady) return '浏览器还没打开过页面，先用 browser_open。';
          final url = args['url']?.toString() ?? '';
          if (url.trim().isEmpty) return '地址为空。';
          final mb = (args['max_mb'] as num?)?.toInt() ?? 6;
          return engine.download(url, maxBytes: mb * 1024 * 1024);
        },
      ),
      ExternalTool(
        name: 'browser_control',
        description: '控制浏览器本身：back/forward 前进后退、reload 刷新、'
            'show/hide 显示或收起给用户看（show 出来的是可拖动的悬浮窗，'
            '用户能直接在上面操作）、maximize/restore 切全屏或悬浮、'
            'persist 立刻把登录态写盘、logout 清 Cookie 与站点数据、'
            'info 看内核信息。',
        parameters: obj([
          'action'
        ], {
          'action': {
            'type': 'string',
            'enum': [
              'back',
              'forward',
              'reload',
              'show',
              'hide',
              'maximize',
              'restore',
              'persist',
              'logout',
              'info',
            ],
          },
          'origin': {
            'type': 'string',
            'description': 'action=logout 时只清这个域（如 https://example.com），'
                '留空清全部',
          },
        }),
        origin: origin,
        isWrite: true,
        invoke: (args) async {
          switch (args['action']?.toString()) {
            case 'back':
              return await engine.back()
                  ? '已返回：${engine.currentUrl.value}'
                  : '没有上一页。';
            case 'forward':
              return await engine.forward()
                  ? '已前进：${engine.currentUrl.value}'
                  : '没有下一页。';
            case 'reload':
              await engine.reload();
              return '已刷新。';
            case 'show':
              engine.show(byAgent: true);
              return '浏览器悬浮窗已显示给用户，他可以直接在上面操作。';
            case 'hide':
              engine.hide();
              return '浏览器已收起（页面和登录态都还在）。';
            case 'maximize':
              engine.show(byAgent: true);
              engine.maximize();
              return '浏览器已铺满全屏。';
            case 'restore':
              engine.restore();
              return '浏览器已缩回悬浮窗。';
            case 'persist':
              await engine.persist();
              return 'Cookie 已写盘，APP 重启后登录态还在。';
            case 'logout':
              final scope = args['origin']?.toString() ?? '';
              final note = await engine.clearSession(origin: scope);
              if (scope.isEmpty) return '已清空全部登录态（整库清空，HttpOnly 也没了）。';
              final left = await engine.cookieRows(scope);
              return [
                '已清空 $scope 的数据。',
                if (note.isNotEmpty) note,
                // 说到底只有复查算数：以前"报成功但票还在"就是没这一步。
                left.isEmpty
                    ? '复查：这个域现在 0 条 Cookie。'
                    : '⚠️ 复查：还剩 ${left.length} 条 '
                        '(${left.map((r) => r['name']).take(6).join('、')})，'
                        '不带 origin 再 logout 一次可以彻底清。',
              ].join('\n');
            case 'info':
              final info = await engine.engineInfo();
              return [
                '内核：${info['package']} ${info['version']}',
                '接收 Cookie：${info['acceptCookie']}',
                '当前地址：${engine.currentUrl.value}',
                '抓包 ${engine.requests.value.length} 条',
              ].join('\n');
            default:
              return '未知 action。';
          }
        },
      ),
      ExternalTool(
        name: 'browser_session',
        description: '换账号 / 灌登录态。三个动作：\n'
            'reset —— 把一个站点彻底恢复成"从没来过"：删该域 Cookie（含 HttpOnly，'
            '内部会整库清空再把别的站点写回）+ localStorage + sessionStorage + '
            'IndexedDB，然后重开页面。清完**自动复查**：只要还剩 cookie，'
            '返回文案会明说"没做干净"，别把它当成功。\n'
            'inject —— 只有 Cookie、没有账号密码时，把 Cookie 灌进浏览器直接拿到登录态。'
            '支持 devtools 里复制的一整行 `a=1; b=2`，也支持完整 Set-Cookie（多条换行分隔）。'
            '会回报浏览器实际收下了哪些。\n'
            'export —— 导出当前站点的完整登录态（Cookie 含 HttpOnly + localStorage），'
            '存下来以后可以用 inject 还原。\n'
            '想在两个账号之间来回切：先 export 存下 A，再 reset，登录 B；'
            '要回 A 就 reset + inject 那份导出。',
        parameters: obj([
          'action'
        ], {
          'action': {
            'type': 'string',
            'enum': ['reset', 'inject', 'export'],
          },
          'url': {
            'type': 'string',
            'description': '目标站点（如 https://example.com），默认当前页',
          },
          'cookies': {
            'type': 'string',
            'description': 'action=inject 时要写入的 Cookie。'
                '`a=1; b=2` 或完整 Set-Cookie（多条用换行分隔）',
          },
          'storage': {
            'type': 'object',
            'description': 'action=inject 时顺带写入的 localStorage 键值'
                '（JWT / refresh token 常放这儿）',
          },
          'reopen': {
            'type': 'boolean',
            'description': 'action=reset 时清完是否重新打开该站点，默认 true',
          },
          'all_sites': {
            'type': 'boolean',
            'description': 'action=reset 时清**全部**站点（等于退出所有登录），'
                '默认 false 只清目标站点。用户没明说"全部退出"就别开',
          },
        }),
        origin: origin,
        // 会清掉/替换登录态，误用等于把用户踢下线，算危险写操作。
        isWrite: true,
        danger: true,
        invoke: (args) async {
          final action = args['action']?.toString() ?? '';
          final url = args['url']?.toString() ?? '';
          switch (action) {
            case 'reset':
              return engine.resetSite(
                url: url,
                reopen: args['reopen'] != false,
                wipeAll: args['all_sites'] == true,
              );
            case 'inject':
              final cookies = args['cookies']?.toString() ?? '';
              final storage = args['storage'];
              if (cookies.trim().isEmpty && storage is! Map) {
                return '既没给 cookies 也没给 storage，没什么可注入的。';
              }
              final lines = <String>[];
              if (cookies.trim().isNotEmpty) {
                lines.add(await engine.injectCookies(url, cookies));
              }
              if (storage is Map && storage.isNotEmpty) {
                if (!engine.isReady) {
                  lines.add('localStorage 没写：得先 browser_open 到目标站点'
                      '（localStorage 按域隔离，不在那个页面上写不进去）。');
                } else {
                  lines.add(await engine.storageSet(
                    storage.map((k, v) => MapEntry(k.toString(), v.toString())),
                  ));
                }
              }
              return lines.join('\n');
            case 'export':
              final target = url.isEmpty ? engine.currentUrl.value : url;
              if (target.isEmpty) return '没有地址：先 browser_open，或显式给 url。';
              final full = await engine.cookiesFull(target);
              final store = engine.isReady
                  ? await engine.storageDump()
                  : '（没打开页面，读不到 localStorage）';
              return [
                '站点：$target',
                'Cookie（含 HttpOnly，可直接喂给 browser_session inject）：',
                full.isEmpty ? '（没有 Cookie）' : full,
                '',
                'localStorage / sessionStorage：',
                store,
              ].join('\n');
            default:
              return '未知 action：只支持 reset / inject / export。';
          }
        },
      ),
      ExternalTool(
        name: 'browser_hook',
        description: '抓包改写脚本：往浏览器里装 JS 钩子，改请求 / 改返回 / 假造返回 / 拦掉。'
            '**这是"我要改这个 POST 的某个参数"的正确工具**——'
            'browser_script 只跑一次页面代码，改不到已经发出去的请求。\n'
            '脚本就是一段 JS，里面定义这两个函数（哪个都可以省）：\n'
            'function onRequest(req){}  改 req.url / req.method / req.headers（普通对象）/ '
            'req.body（字符串）；req.block=true 整包拦掉；'
            'req.mock={status,body,headers} 不发出去直接假返回。\n'
            'function onResponse(res){} 改 res.status / res.headers / res.body；'
            'res.request 是对应的请求；res.kind 是 fetch 还是 xhr。\n'
            '脚本里还能用 QL.log(...) 打日志到浏览器日志页，QL.state 存自己的中间值。\n'
            '例（把下单金额改掉，并给返回体加个字段）：\n'
            'function onRequest(req){ if(req.url.includes("/api/order")&&req.method==="POST"){ '
            'req.body=req.body.replace(\'"amount":1\',\'"amount":99\'); QL.log("改了",req.body); } }\n'
            'function onResponse(res){ if(res.url.includes("/api/me")){ '
            'var d=JSON.parse(res.body); d.vip=true; res.body=JSON.stringify(d); } }\n'
            '动作：list 看清单、add 加、update 改（名字/代码/开关）、get 看代码、'
            'remove 删、clear 清空、hits 看各改了几次。\n'
            '只覆盖 fetch / XHR，注入前发出的请求抓不到（刷新一次再看）。\n'
            '脚本会落盘、跨重启一直生效，用完记得 remove，'
            '否则用户后面自己上网也被改。',
        parameters: obj([
          'action'
        ], {
          'action': {
            'type': 'string',
            'enum': [
              'list',
              'add',
              'update',
              'get',
              'remove',
              'clear',
              'hits',
            ],
          },
          'name': {'type': 'string', 'description': '脚本名字（add 必填，update 可改）'},
          'code': {
            'type': 'string',
            'description': 'JS 代码，里面定义 onRequest / onResponse',
          },
          'id': {
            'type': 'integer',
            'description': 'update / get / remove 时的脚本号',
          },
          'enabled': {'type': 'boolean', 'description': '启用还是停用'},
        }),
        origin: origin,
        isWrite: true,
        // 能改用户任何一个请求，甚至伪造返回，必须过审批。
        danger: true,
        invoke: (args) async {
          final action = args['action']?.toString() ?? 'list';
          switch (action) {
            case 'add':
              final code = args['code']?.toString() ?? '';
              if (code.trim().isEmpty) {
                return '没给 code。写一段 JS，里面定义 onRequest(req) 或 onResponse(res)。';
              }
              return engine.addScript(
                name: args['name']?.toString() ?? '未命名脚本',
                code: code,
                enabled: args['enabled'] != false,
              );
            case 'update':
              final id = (args['id'] as num?)?.toInt() ?? -1;
              return engine.updateScript(
                id,
                name: args['name']?.toString(),
                code: args['code']?.toString(),
                enabled: args['enabled'] as bool?,
              );
            case 'get':
              final id = (args['id'] as num?)?.toInt() ?? -1;
              final script = engine.scriptById(id);
              if (script == null) return '没有 #$id 这个脚本（用 list 看现有的）。';
              return [
                script.summary,
                '--- 代码 ---',
                script.code,
              ].join('\n');
            case 'remove':
              final id = (args['id'] as num?)?.toInt() ?? -1;
              return await engine.removeScript(id)
                  ? '已删脚本 #$id。'
                  : '没有 #$id 这个脚本（用 list 看现有的）。';
            case 'clear':
              final count = engine.scripts.length;
              await engine.clearScripts();
              return '已清空 $count 个脚本，请求恢复原样。';
            case 'hits':
              final list = engine.scripts;
              if (list.isEmpty) return '还没有任何脚本。';
              return [
                for (final it in list)
                  '#${it.id} ${it.name}：改了 ${it.hits} 个包'
                      '${it.enabled ? '' : '（已停用）'}'
                      '${it.error.isEmpty ? '' : ' — 出错：${it.error}'}',
                '',
                '一直是 0 的常见原因：条件里的 URL 子串写错、页面用的不是 fetch/XHR、'
                    '注入之前请求就发完了（刷新一次再看），'
                    '或者钩子函数名拼错（必须是 onRequest / onResponse）。',
              ].join('\n');
            default:
              final list = engine.scripts;
              if (list.isEmpty) {
                return '还没有脚本。加一个：action=add，name=…，'
                    'code 里写 function onRequest(req){…} 或 function onResponse(res){…}';
              }
              return [
                '共 ${list.length} 个（按顺序执行，'
                    '前一个改完的包交给后一个；谁先 block/mock，后面的就不跑了）：',
                for (final it in list) it.summary,
                '',
                '看某个脚本的代码：action=get，id=…',
              ].join('\n');
          }
        },
      ),
      ExternalTool(
        name: 'browser_jumps',
        description: '查看当前被拦截、等待用户/AI 决定的外部跳转请求。'
            '网页试图跳到微信/QQ/支付宝/intent:// 等外部应用时会被拦下，'
            '不会直接打开。用户可以弹窗确认；AI 看到有请求且用户要求时，'
            '可用 browser_jump 允许或拒绝。',
        parameters: obj([], {}),
        origin: origin,
        invoke: (args) async {
          final list = engine.pendingExternalJumps.value;
          if (list.isEmpty) {
            return '当前没有待处理的外部跳转请求。';
          }
          return [
            '共 ${list.length} 个待处理外部跳转：',
            for (final r in list)
              '${r.id} | ${r.url}'
                  '${(r.sourceUrl ?? '').isEmpty ? '' : '（来自 ${r.sourceUrl}）'}'
                  ' | ${r.createdAt.toIso8601String()}',
            '',
            '用 browser_jump 传 id 和 action=allow/deny 决定。',
          ].join('\n');
        },
      ),
      ExternalTool(
        name: 'browser_jump',
        description: '允许或拒绝一条被拦截的外部跳转请求。'
            '第三方登录（QQ/微信/支付宝授权）通常应该 allow；'
            '来历不明的下载页/打开其它 App 的流氓跳转应该 deny。',
        parameters: obj([
          'id',
          'action'
        ], {
          'id': {
            'type': 'string',
            'description': '外部跳转请求 id，从 browser_jumps 里拿',
          },
          'action': {
            'type': 'string',
            'enum': ['allow', 'deny'],
            'description': 'allow=允许系统打开该外部链接；deny=取消这次跳转',
          },
        }),
        origin: origin,
        invoke: (args) async {
          final id = args['id']?.toString().trim() ?? '';
          final action = args['action']?.toString().trim() ?? '';
          if (id.isEmpty || (action != 'allow' && action != 'deny')) {
            return '参数不对：需要 id（browser_jumps 里看）和 action=allow/deny。';
          }
          final ok = await engine.resolveExternalJump(
            id,
            allow: action == 'allow',
          );
          if (!ok) return '没有找到 id=$id 的待处理跳转（可能已被处理）。';
          return action == 'allow'
              ? '已允许跳转：$id，尝试交给系统打开。'
              : '已拒绝跳转：$id，网页不会被拉起。';
        },
      ),
      ExternalTool(
        name: 'browser_wait_user',
        description: '把浏览器亮给用户，等他手动处理完再继续——遇到 Cloudflare 人机验证、'
            '滑块、扫码登录、短信验证码时用它。调用后会挂起，直到用户点"我处理好了"。'
            '处理完浏览器里就带着验证票和登录态，接着用 browser_fetch / browser_read 拿数据。',
        parameters: obj([
          'hint'
        ], {
          'hint': {
            'type': 'string',
            'description': '一句话告诉用户要做什么，例如"请完成 Cloudflare 人机验证"',
          },
          'timeout_min': {'type': 'integer', 'description': '最多等几分钟，默认 10'},
        }),
        origin: origin,
        invoke: (args) async {
          final hint = args['hint']?.toString() ?? '请在浏览器里完成操作';
          final minutes = (args['timeout_min'] as num?)?.toInt() ?? 10;
          final ack = await engine.askUser(
            hint,
            timeout: Duration(minutes: minutes),
          );
          final cookies = await engine.cookies();
          return [
            ack,
            '当前地址：${engine.currentUrl.value}',
            '标题：${engine.title.value}',
            if (cookies.isNotEmpty) '可见 Cookie：${_clip(cookies, 500)}',
            'HttpOnly 的票（如 cf_clearance）读不到，但用 browser_fetch 发请求会自动带上。',
          ].join('\n');
        },
      ),
    ]);
  }

  static String _clip(String text, int limit) {
    final flat = text.replaceAll('\n', ' ');
    return flat.length <= limit ? flat : '${flat.substring(0, limit)}…';
  }

  /// 系统提示里的浏览器能力说明。
  static String promptBlock() {
    return [
      '## 浏览器内核（真浏览器，不是 HTTP 客户端）',
      '- web_fetch 只是纯 HTTP：遇到 Cloudflare 验证、登录墙、JS 渲染的页面，它只能拿回一页占位符。',
      '- 内核是常驻的：Cookie 与 localStorage 会落盘，**登录一次以后一直有效**，APP 重启也在。',
      '- 你亮出来的窗口，任务做完会自动收起（登录态和页面都留着）；'
          '用户自己点开的、或者他上手操作过的窗口不会被收走。',
      '- 它同时是给用户用的浏览器：browser_control show 会亮出一个可拖动、可缩放的悬浮窗，'
          '用户能自己输网址、点页面、登录、过人机验证；AI 和用户操作的是同一个内核，'
          '所以他点完验证你立刻就能用上那张票。AI 页右上角的地球图标也能打开它。',
      '- 遇到登录墙 / Cloudflare / 滑块 / 短信码：不要试图自己破。'
          '调 browser_wait_user 亮出窗口请用户点一下就行——那只是个网页，没有专门的验证组件。',
      '- 网页要跳到外部 App（微信/QQ/支付宝/下载 App 等）会被拦下并弹确认框。'
          '这是第三方登录时用 browser_jumps 看请求，再用 browser_jump 传 '
          'id 和 action=allow 放行；不确定或像流氓下载就 action=deny 拒绝。',
      '- 典型流程：browser_open 打开 → 要登录/过验证就 browser_wait_user 请用户操作 '
          '→ 回来 browser_read 读正文、browser_capture 看页面调了哪些接口 '
          '→ browser_fetch 直接调接口拿 JSON（Cookie 自动带，含 HttpOnly 的票）。',
      '- 要点按钮/填表/滚动加载：browser_script（函数体，用 return 交结果，可 await）。',
      '- 登录态相关：browser_cookies 读写 Cookie（含 HttpOnly）、browser_storage 读写 '
          'localStorage、browser_control persist 立刻落盘、logout 退出登录。',
      '- 找资源：browser_resources 列页面加载的全部资源（含子资源），'
          'browser_download 把文件下到本机再读。',
      '- 换账号 / 退登录：browser_session reset（清该域 Cookie 含 HttpOnly + '
          'localStorage + sessionStorage 再重开页面）。**只清 Cookie 常常不够**——'
          '站点会用 localStorage 里的 token 自动登回去。只有 Cookie 没有账号密码时用 '
          'browser_session inject 灌进去；想留着以后还原就先 export。',
      '- **清完登录态一定要用 browser_cookies 复查**，别拿工具返回的"已清掉"当结果。'
          '返回里带 ⚠️ 就是没清干净：这时用 browser_control logout（不带 origin）'
          '整库清空，最彻底。',
      '- 要改请求/返回（改 POST 的某个参数、伪造返回、拦掉某个包）：browser_hook。'
          '装一段 JS：onRequest(req) 里改 req.url/method/headers/body，'
          'req.block=true 拦掉、req.mock={status,body} 假返回；'
          'onResponse(res) 里改 res.status/headers/body。想怎么改就怎么写——'
          '解 JSON 改深层字段、重算签名、按上一个包决定这一个包都行。'
          'browser_script 改不到已经发出去的请求，这件事只有 browser_hook 能做。'
          '脚本会落盘长期生效，用完记得 remove——否则用户自己上网也被改。',
      '- 找数据的顺序：先 browser_capture / browser_resources 找接口，再考虑解析 HTML。'
          '接口返回的 JSON 又稳又省 token。',
    ].join('\n');
  }
}
