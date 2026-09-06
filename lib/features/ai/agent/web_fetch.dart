import 'package:dio/dio.dart';

/// 抓取网页/仓库文本，给 AI 装技能用。
///
/// 为什么需要它：用户说"这个开源项目不错，帮我装成技能"时，AI 手里只有一个链接。
/// 没有取文本的能力，它只能凭项目名瞎编一份手册——那正是"AI 有点蠢"的来源之一。
class WebFetch {
  WebFetch._();

  static final _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 12),
      receiveTimeout: const Duration(seconds: 25),
      followRedirects: true,
      // 4xx 也要把 body 读回来：GitHub 的 404 页面能说明是分支名不对还是仓库不存在。
      validateStatus: (code) => code != null && code < 500,
      headers: {'User-Agent': 'QingLongFlutter/1.0'},
      responseType: ResponseType.plain,
    ),
  );

  /// GitHub / Gitee 的网页地址转成 raw 地址，否则抓回来是一整页 HTML。
  ///
  /// 同时对"只给了仓库首页"的情况生成一串候选文件，依次尝试。
  static List<String> candidates(String rawUrl) {
    var url = rawUrl.trim();
    if (url.isEmpty) return const [];
    if (!url.startsWith('http')) url = 'https://$url';

    // blob 链接 → raw
    final blob = RegExp(
      r'^https?://github\.com/([^/]+)/([^/]+)/blob/([^/]+)/(.+)$',
    ).firstMatch(url);
    if (blob != null) {
      return [
        'https://raw.githubusercontent.com/${blob.group(1)}/${blob.group(2)}'
            '/${blob.group(3)}/${blob.group(4)}',
      ];
    }

    // 仓库首页 → 依次试常见说明文件
    final repo = RegExp(
      r'^https?://github\.com/([^/]+)/([^/?#]+)/?$',
    ).firstMatch(url);
    if (repo != null) {
      final owner = repo.group(1)!;
      final name = repo.group(2)!.replaceAll(RegExp(r'\.git$'), '');
      final files = [
        'SKILL.md',
        'skill.md',
        'README.md',
        'readme.md',
        'README_CN.md',
        'docs/README.md',
      ];
      return [
        for (final branch in ['main', 'master'])
          for (final f in files)
            'https://raw.githubusercontent.com/$owner/$name/$branch/$f',
      ];
    }

    final giteeBlob = RegExp(
      r'^https?://gitee\.com/([^/]+)/([^/]+)/blob/([^/]+)/(.+)$',
    ).firstMatch(url);
    if (giteeBlob != null) {
      return [
        'https://gitee.com/${giteeBlob.group(1)}/${giteeBlob.group(2)}'
            '/raw/${giteeBlob.group(3)}/${giteeBlob.group(4)}',
      ];
    }

    return [url];
  }

  /// 抓第一个能拿到正文的候选地址。返回 (最终地址, 正文)。
  static Future<(String, String)> fetch(String url,
      {int maxChars = 20000}) async {
    final list = candidates(url);
    if (list.isEmpty) throw ArgumentError('链接为空');
    Object? lastError;
    for (final candidate in list) {
      try {
        final response = await _dio.get<String>(candidate);
        final body = response.data ?? '';
        final code = response.statusCode ?? 0;
        if (code >= 400 || body.trim().isEmpty) {
          lastError = '$candidate → HTTP $code';
          continue;
        }
        final text = _stripHtml(body);
        return (
          candidate,
          text.length > maxChars
              ? '${text.substring(0, maxChars)}\n…（内容过长已截断）'
              : text,
        );
      } catch (e) {
        lastError = e;
      }
    }
    throw StateError('抓取失败：${lastError ?? '未知原因'}');
  }

  /// 粗暴去标签：只为让模型读得懂，不追求还原排版。
  static String _stripHtml(String body) {
    if (!body.trimLeft().startsWith('<')) return body;
    var text = body
        .replaceAll(
            RegExp(r'<script[\s\S]*?</script>', caseSensitive: false), '')
        .replaceAll(RegExp(r'<style[\s\S]*?</style>', caseSensitive: false), '')
        .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
        .replaceAll(RegExp(r'</(p|div|li|h\d)>', caseSensitive: false), '\n')
        .replaceAll(RegExp(r'<[^>]+>'), ' ');
    text = text
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"');
    return text
        .replaceAll(RegExp(r'\n{3,}'), '\n\n')
        .replaceAll(RegExp(r'[ \t]{2,}'), ' ');
  }
}
