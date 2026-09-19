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
                        parts.add('没有找到与「$query」强相关的结果，'
                            '建议换更具体的关键词再查。');
                      } else {
                        parts.add('搜索：$query');
                        for (var i = 0; i < results.length; i++) {
                          parts.add('${i + 1}. ${results[i]['title']}\n'
                              '   ${results[i]['url']}\n'
                              '   ${results[i]['snippet']}');
                        }
                        // 光靠摘要还是容易“词不达意”：自动抓第一条最相关
                        // 结果的正文片段喂给模型，让信息收集有真东西可读。
                        final detail =
                            await _fetchFirstResultDetail(results, 6000);
                        if (detail.isNotEmpty) {
                          parts.add('—— 最相关页面正文摘录 ——\n$detail');
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
    // 先拿原始查询词，把四个引擎的结果全部收回来合并，再用相关性打分挑，
    // 而不是“第一个引擎只要非空就直接交差”——那正是“搜 A 给 B”的一个来源。
    final all = <String, Map<String, String>>{};
    try {
      for (final r in await _collectFromEngines(query, 10)) {
        all[r['url'] ?? ''] = r;
      }
    } catch (_) {
      // 单个引擎/握手失败不阻塞，继续评分。
    }

    var scored = _scoreResults(all.values.toList(), query);

    // 原始词相关结果不够时，换几个更明确的问法补一轮。
    // 只补到够用就停，避免为了凑数把不相关结果塞回来。
    if (scored.where((e) => e.score > 0).length < max) {
      for (final suffix in _querySuffixes(query)) {
        // 已经有够多的相关结果就不必多搜了。
        if (scored.where((e) => e.score > 0).length >= max) break;
        try {
          final more = await _collectFromEngines('$query $suffix', 6);
          for (final r in more) {
            all[r['url'] ?? ''] = r;
          }
          scored = _scoreResults(all.values.toList(), query);
        } catch (_) {
          // 补搜失败不影响已收集的结果。
        }
      }
    }

    final relevant = scored.where((e) => e.score > 0).toList();
    if (relevant.isEmpty) {
      // 一个都不相关就空手回去，让调用方明确说“没找到强相关结果”，
      // 不要硬塞一批驴唇不对马嘴的链接。
      return const [];
    }
    return relevant.take(max).map((e) => e.result).toList();
  }

  /// 四个搜索引擎并发收集，按 URL 去重合并；单点失败不影响其他引擎。
  static Future<List<Map<String, String>>> _collectFromEngines(
      String query, int max) async {
    final errors = <String>[];
    final engines = <String, Future<List<Map<String, String>>> Function()>{
      'bing': () =>
          _searchEngineBing('https://www.bing.com/search', query, max),
      'cn_bing': () =>
          _searchEngineBing('https://cn.bing.com/search', query, max),
      'duckduckgo': () => _searchEngineDuckDuckGo(query, max),
      'baidu': () => _searchEngineBaidu(query, max),
    };
    final lists = await Future.wait([
      for (final entry in engines.entries)
        () async {
          try {
            return await entry.value();
          } catch (e) {
            errors.add('${entry.key}: $e');
            return <Map<String, String>>[];
          }
        }(),
    ]);
    final seen = <String>{};
    final out = <Map<String, String>>[];
    for (final list in lists) {
      for (final r in list) {
        final key = r['url'] ?? '';
        if (key.isEmpty || !seen.add(key)) continue;
        out.add(r);
      }
    }
    return out;
  }

  /// 抓取最相关一条结果的页面正文片段，失败就返回空串。
  static Future<String> _fetchFirstResultDetail(
    List<Map<String, String>> results,
    int maxChars,
  ) async {
    for (final r in results) {
      final url = r['url'] ?? '';
      if (url.isEmpty) continue;
      try {
        final (_, body) = await WebFetch.fetch(url, maxChars: maxChars);
        if (body.trim().length >= 60) return body.trim();
      } catch (_) {
        // 单个页面抓不到不影响整体收集结果。
      }
    }
    return '';
  }

  /// 根据查询词生成补搜问法。网上找资料，加“教程/文档/官网/是什么”
  /// 通常能显著提高命中度；但不要一律硬加，按查询意图挑。
  static List<String> _querySuffixes(String query) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return const [];
    final how = RegExp(r'怎么|如何|怎样|教程|安装|配置|使用|下载|部署');
    final what = RegExp(r'是什么|什么意思|定义|介绍|背景|历史|区别|对比');
    final needOfficial = RegExp(r'官网|官方|最新|价格|下载|地址');
    final suffixes = <String>[];
    if (how.hasMatch(q)) {
      suffixes.addAll(['教程', '步骤', '文档']);
    } else if (what.hasMatch(q)) {
      suffixes.addAll(['详细介绍', '是什么']);
    } else if (needOfficial.hasMatch(q)) {
      suffixes.addAll(['官网', '官方文档']);
    } else {
      suffixes.addAll(['资料', '教程']);
    }
    return suffixes.toSet().toList();
  }

  /// 对合并结果做轻量相关性评分：命中查询原句/关键词的才留下。
  static List<({int score, Map<String, String> result})> _scoreResults(
    List<Map<String, String>> results,
    String query,
  ) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return [];
    final tokens = q
        .split(RegExp(r'[\s,，。.;；:：!！?？、/\\|()\[\]{}]+'))
        .where((t) => t.length >= 2)
        .toList();

    int score(Map<String, String> r) {
      final title = (r['title'] ?? '').toLowerCase();
      final snippet = (r['snippet'] ?? '').toLowerCase();
      final url = (r['url'] ?? '').toLowerCase();
      final text = '$title $snippet $url';
      var s = 0;
      if (text.contains(q)) s += 6;
      if (title.contains(q)) s += 4;
      for (final token in tokens) {
        // 中文分词难，这里用整词 + 双字二元组兜底。
        if (text.contains(token)) s += token.length >= 4 ? 3 : 2;
        if (title.contains(token)) s += 2;
        for (var i = 0; i < token.length - 1; i++) {
          final bigram = token.substring(i, i + 2);
          if (text.contains(bigram)) s += 1;
        }
      }
      // 空摘要通常不可信，扣一点分。
      if (snippet.isEmpty) s -= 2;
      return s;
    }

    final scored = [
      for (final r in results) (score: score(r), result: r),
    ];
    scored.sort((a, b) {
      final c = b.score.compareTo(a.score);
      if (c != 0) return c;
      return (a.result['title'] ?? '').compareTo(b.result['title'] ?? '');
    });
    return scored;
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
