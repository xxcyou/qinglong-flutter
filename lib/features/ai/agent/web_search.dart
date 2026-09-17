import 'package:dio/dio.dart';

import 'external_tool.dart';
import 'web_fetch.dart';

/// 轻量网络搜索工具，给 AI 和子代理查公开信息用。
///
/// 为什么不用浏览器搜索：浏览器内核全 APP 只有一个，多个子代理同时
/// browser_open 会互相踢页面，读到的 DOM 可能是别人刚导航过去的。
/// 公开网页/文档查询走这里的直连搜索，互不干扰；浏览器只留给人机验证、
/// 登录态、前端动态渲染这些必须真浏览器才行的场景。
class WebSearchTools {
  WebSearchTools._();

  static List<ExternalTool> build() => [
        ExternalTool(
          name: 'web_search',
          description: '搜索网络公开信息，直接返回标题/摘要/链接。'
              '适合查文档、找资料、让多个子代理同时搜索。'
              '这是**轻量搜索**，不动共享浏览器，多个并发的搜索不会互相踢页面；'
              '需要登录/过验证/动态渲染时才用 browser_open。',
          parameters: const {
            'type': 'object',
            'properties': {
              'query': {'type': 'string', 'description': '搜索词，尽量具体'},
              'max_results': {
                'type': 'integer',
                'description': '返回几条，默认 6，最多 10',
              },
            },
            'required': ['query'],
          },
          origin: '网络搜索',
          invoke: (args) async {
            final query = args['query']?.toString().trim() ?? '';
            if (query.isEmpty) return '搜索词为空。';
            final max =
                ((args['max_results'] as num?)?.toInt() ?? 6).clamp(1, 10);
            try {
              final results = await _searchBing(query, max);
              if (results.isEmpty) return '没有搜到「$query」相关结果。';
              return [
                '搜索：$query',
                '',
                for (var i = 0; i < results.length; i++)
                  '${i + 1}. ${results[i]['title']}\n'
                      '   ${results[i]['url']}\n'
                      '   ${results[i]['snippet']}',
              ].join('\n');
            } catch (e) {
              return '搜索失败：$e';
            }
          },
        ),
        ExternalTool(
          name: 'collect_info',
          description: '一次收集多条信息：传一组查询或网页地址，自动逐条执行'
              'web_search / web_fetch 并汇总成一份分组资料。'
              '适合“帮我查这几个东西”、“多来源信息汇总”、子代理收集资料'
              '——一条调用拿回所有结果，比反复调同一个搜索工具省上下文，'
              '也不去占用共享浏览器。',
          parameters: const {
            'type': 'object',
            'properties': {
              'items': {
                'type': 'array',
                'description': '要收集的信息清单，每项 {title?, query?, url?}。'
                    'query 会走网络搜索，url 会抓网页正文。',
                'items': {
                  'type': 'object',
                  'properties': {
                    'title': {'type': 'string', 'description': '显示标题（可选）'},
                    'query': {'type': 'string', 'description': '搜索词（二选一）'},
                    'url': {'type': 'string', 'description': '网页链接（二选一）'},
                  },
                },
              },
              'max_per_query': {
                'type': 'integer',
                'description': '每个查询最多返回几条搜索结果，默认 3，最多 6',
              },
            },
            'required': ['items'],
          },
          origin: '信息收集',
          invoke: (args) async {
            final raw = args['items'];
            if (raw is! List || raw.isEmpty) return 'items 是空的。';
            final maxPerQuery =
                ((args['max_per_query'] as num?)?.toInt() ?? 3).clamp(1, 6);
            final items = <Map<String, dynamic>>[];
            var index = 0;
            for (final item in raw) {
              if (item is! Map) continue;
              index++;
              final title =
                  (item['title']?.toString().trim().isNotEmpty ?? false)
                      ? item['title']!.toString().trim()
                      : '条目 $index';
              final query = item['query']?.toString().trim() ?? '';
              final url = item['url']?.toString().trim() ?? '';
              items.add({
                'title': title,
                'query': query,
                'url': url,
              });
            }
            // 并行收集：互不依赖的查询同时发出去，比一条条串快很多。
            final sections = await Future.wait([
              for (final item in items)
                () async {
                  final title = item['title']! as String;
                  final query = item['query']! as String;
                  final url = item['url']! as String;
                  final parts = <String>['## $title'];
                  try {
                    if (query.isNotEmpty) {
                      final results = await _searchBing(query, maxPerQuery);
                      if (results.isEmpty) {
                        parts.add('没有搜到「$query」相关结果。');
                      } else {
                        parts.add('搜索：$query');
                        for (var i = 0; i < results.length; i++) {
                          parts.add('${i + 1}. ${results[i]['title']}\n'
                              '   ${results[i]['url']}\n'
                              '   ${results[i]['snippet']}');
                        }
                      }
                    } else if (url.isNotEmpty) {
                      final (finalUrl, body) =
                          await WebFetch.fetch(url, maxChars: 20000);
                      parts.add('来源：$finalUrl\n$body');
                    } else {
                      parts.add('（这一项没有 query 或 url，跳过）');
                    }
                  } catch (e) {
                    parts.add('收集失败：$e');
                  }
                  return parts.join('\n');
                }(),
            ]);
            return sections.join('\n\n');
          },
        ),
      ];

  static Future<List<Map<String, String>>> _searchBing(
      String query, int max) async {
    // 多引擎兜底：一个站点握手失败/被反爬，自动换下一个，而不是整单报错。
    final errors = <String>[];
    final engines = <String, Future<List<Map<String, String>>> Function()>{
      'bing': () =>
          _searchEngineBing('https://www.bing.com/search', query, max),
      'cn_bing': () =>
          _searchEngineBing('https://cn.bing.com/search', query, max),
      'duckduckgo': () => _searchEngineDuckDuckGo(query, max),
      'baidu': () => _searchEngineBaidu(query, max),
    };
    for (final entry in engines.entries) {
      try {
        final results = await entry.value();
        if (results.isNotEmpty) return results;
      } catch (e) {
        errors.add('${entry.key}: $e');
      }
    }
    throw StateError(errors.isEmpty ? '所有搜索引擎都失败' : errors.join('；'));
  }

  static Dio _searchDio() => Dio(
        BaseOptions(
          connectTimeout: const Duration(seconds: 15),
          receiveTimeout: const Duration(seconds: 30),
          followRedirects: true,
          responseType: ResponseType.plain,
          headers: {
            'User-Agent':
                'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
                    '(KHTML, like Gecko) Chrome/125.0 Safari/537.36',
            'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8',
            'Accept':
                'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
          },
          validateStatus: (code) => code != null && code < 400,
        ),
      );

  static Future<List<Map<String, String>>> _searchEngineBing(
      String base, String query, int max) async {
    final dio = _searchDio();
    final url = '$base?q=${Uri.encodeQueryComponent(query)}'
        '&setlang=zh-CN&cc=CN';
    final response = await dio.get<String>(url);
    final html = response.data ?? '';
    final out = <Map<String, String>>[];
    final blocks = RegExp(
      r'<li class="b_algo"[\s\S]*?</li>',
      caseSensitive: false,
    ).allMatches(html);
    for (final block in blocks) {
      if (out.length >= max) break;
      final body = block.group(0) ?? '';
      final h2 = RegExp(
        r'<h2[^>]*>\s*<a[^>]*href="([^"]+)"[^>]*>(.*?)</a>',
        dotAll: true,
        caseSensitive: false,
      ).firstMatch(body);
      if (h2 == null) continue;
      var url2 = h2.group(1)!.trim();
      if (url2.startsWith('//')) url2 = 'https:$url2';
      if (url2.startsWith('/')) url2 = 'https://www.bing.com$url2';
      final title = _strip(h2.group(2)!);
      final p = RegExp(
        r'<p[^>]*>(.*?)</p>',
        dotAll: true,
        caseSensitive: false,
      ).firstMatch(body);
      final snippet = p == null ? '' : _strip(p.group(1)!);
      if (title.isEmpty && url2.isEmpty) continue;
      out.add({'title': title, 'url': url2, 'snippet': snippet});
    }
    return out;
  }

  static Future<List<Map<String, String>>> _searchEngineDuckDuckGo(
      String query, int max) async {
    final dio = _searchDio();
    final url =
        'https://html.duckduckgo.com/html/?q=${Uri.encodeQueryComponent(query)}';
    final response = await dio.get<String>(url);
    final html = response.data ?? '';
    final out = <Map<String, String>>[];
    final links = RegExp(
      r'<a[^>]+class="result__a"[^>]+href="([^"]+)"[^>]*>(.*?)</a>',
      dotAll: true,
      caseSensitive: false,
    ).allMatches(html);
    final snippets = RegExp(
      r'<a[^>]+class="result__snippet"[^>]*>(.*?)</a>',
      dotAll: true,
      caseSensitive: false,
    ).allMatches(html).toList();
    for (var i = 0; i < links.length && out.length < max; i++) {
      final m = links.elementAt(i);
      var url2 = m.group(1)!.trim();
      // DuckDuckGo 结果链接带跳转前缀，取真实地址参数。
      final uddg = RegExp(r'uddg=([^&]+)').firstMatch(url2);
      if (uddg != null) {
        try {
          url2 = Uri.decodeComponent(uddg.group(1)!);
        } catch (_) {}
      } else if (url2.startsWith('//')) {
        url2 = 'https:$url2';
      }
      final title = _strip(m.group(2)!);
      final snippet = i < snippets.length ? _strip(snippets[i].group(1)!) : '';
      if (title.isEmpty && url2.isEmpty) continue;
      out.add({'title': title, 'url': url2, 'snippet': snippet});
    }
    return out;
  }

  static Future<List<Map<String, String>>> _searchEngineBaidu(
      String query, int max) async {
    final dio = _searchDio();
    final url = 'https://www.baidu.com/s?wd=${Uri.encodeQueryComponent(query)}';
    final response = await dio.get<String>(url);
    final html = response.data ?? '';
    final out = <Map<String, String>>[];
    // 百度结果块：h3 > a，摘要紧跟在后面的 div。
    final titles = RegExp(
      r'<h3[^>]*>\s*<a[^>]*href="([^"]+)"[^>]*>(.*?)</a>',
      dotAll: true,
      caseSensitive: false,
    ).allMatches(html);
    final snippets = RegExp(
      r'<span class="content-right_8Zs40">(.*?)</span>',
      dotAll: true,
      caseSensitive: false,
    ).allMatches(html).toList();
    for (var i = 0; i < titles.length && out.length < max; i++) {
      final m = titles.elementAt(i);
      var url2 = m.group(1)!.trim();
      if (url2.startsWith('//')) url2 = 'https:$url2';
      if (url2.startsWith('/')) url2 = 'https://www.baidu.com$url2';
      final title = _strip(m.group(2)!);
      final snippet = i < snippets.length ? _strip(snippets[i].group(1)!) : '';
      if (title.isEmpty && url2.isEmpty) continue;
      out.add({'title': title, 'url': url2, 'snippet': snippet});
    }
    return out;
  }

  static String _strip(String raw) {
    var s = raw.replaceAll(RegExp(r'<[^>]+>'), ' ').trim();
    s = s
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&ensp;', ' ')
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .replaceAll(RegExp(r'&#0*23;'), '#')
        .replaceAll('&#0183;', '·')
        .replaceAll('&middot;', '·')
        .replaceAll('&ndash;', '–');
    return s.replaceAll(RegExp(r'\s+'), ' ').trim();
  }
}
