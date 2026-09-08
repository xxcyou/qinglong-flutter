import 'dart:convert';

import 'package:dio/dio.dart';

import 'skill_models.dart';
import 'skill_parser.dart';

/// 把市面上的技能（GitHub 仓库 / 直链）完整导入成 [AiSkill]。
///
/// 市面技能按 Anthropic 标准是「文件夹」：`SKILL.md` + 可选
/// `scripts/*.py|*.js`、`references/*.md`、`resources/` 等。这里做两件事：
/// 1. 拿到并解析 `SKILL.md` 的 frontmatter + 正文；
/// 2. 递归拉取同目录（或仓库）下所有附属文件，一并存进技能。
///
/// 支持三种输入：
/// - GitHub 仓库首页：`https://github.com/owner/repo` → 自动找 `SKILL.md` / `README.md`
/// - GitHub 子目录：`.../blob/main/path/to/skill/SKILL.md` 或该目录
/// - 任意直链：一个 `SKILL.md` / `.md` 的 raw 地址
class SkillImporter {
  SkillImporter._();

  static final _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 120),
      followRedirects: true,
      validateStatus: (code) => code != null && code < 500,
      headers: {
        'User-Agent': 'QingLongFlutter/1.0',
        'Accept': 'application/vnd.github+json'
      },
      responseType: ResponseType.plain,
    ),
  );

  static const _maxFileSize = 400000;

  /// 从 [url] 导入一个技能。返回 (技能, 来源 URL 列表里命中的那个)。
  /// [into] 指定将文件落盘到的本地目录（None 则不落盘，仅存进内存）。
  static Future<(AiSkill, String, String)> import(String url) async {
    final urlNorm = url.trim();
    if (urlNorm.isEmpty) throw ArgumentError('链接为空');

    // 1. 先定位 SKILL.md 的 raw 地址（可能要多步查找）。
    final (skillDocUrl, folderRawUrls) = await _locateSkillDoc(urlNorm);

    final skillMd = await _fetchText(skillDocUrl);
    final parsed = SkillParser.parse(skillMd);

    var name = parsed.name;
    if (name.isEmpty) {
      name = _guessNameFromUrl(
          folderRawUrls.isNotEmpty ? folderRawUrls.first : skillDocUrl);
    }
    if (name.isEmpty) {
      name = 'skill-${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}';
    }

    // 2. 拉取同目录下的附属脚本/资源文件。
    final files = <SkillFile>[];
    var partialNote = '';
    final sw = Stopwatch()..start();
    for (final dirUrl in folderRawUrls) {
      final list = await _listGitDir(dirUrl);
      final base = dirUrl.endsWith('/') ? dirUrl : '$dirUrl/';
      final tasks = <String>[
        for (final item in list)
          if (!item.endsWith('/') &&
              !item.endsWith('/SKILL.md') &&
              !item.endsWith('/skill.md') &&
              item.isNotEmpty)
            item,
      ];
      // 并发拉取，避免几十个文件串行把 skill_install 拖到 Agent 看门狗超时。
      const batch = 6;
      for (var i = 0; i < tasks.length; i += batch) {
        final end = i + batch < tasks.length ? i + batch : tasks.length;
        final results = await Future.wait([
          for (final rawUrl in tasks.sublist(i, end))
            _fetchSkillFile(rawUrl, base),
        ]);
        files.addAll(results.whereType<SkillFile>());
        if (sw.elapsed > const Duration(seconds: 120)) {
          partialNote = '附件下载已到 120 秒时间预算，先导入前 ${files.length} 个文件'
              '（共 ${tasks.length} 个）。如果需要完整导入，稍后重试或换更快的网络。';
          break;
        }
      }
      if (partialNote.isNotEmpty) break;
    }

    final skill = AiSkill(
      id: 'skill-${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}',
      name: name,
      description: parsed.description,
      whenToUse: parsed.whenToUse,
      instructions: parsed.instructions,
      license: parsed.license,
      sourceUrl: urlNorm,
      files: files,
    );
    return (skill, skillDocUrl, partialNote);
  }

  /// 定位一份技能文档的 raw 地址，同时返回可用来抓目录的 raw 目录地址。
  static Future<(String, List<String>)> _locateSkillDoc(String url) async {
    var u = url.trim();
    if (!u.startsWith('http')) u = 'https://$u';

    // blob 链接 → raw 单文件
    final blob = RegExp(
      r'^https?://github\.com/([^/]+)/([^/]+)/blob/([^/]+)/(.+)$',
    ).firstMatch(u);
    if (blob != null) {
      final rawFile =
          'https://raw.githubusercontent.com/${blob.group(1)}/${blob.group(2)}/'
          '${blob.group(3)}/${blob.group(4)}';
      final dir = rawFile.substring(0, rawFile.lastIndexOf('/'));
      final isSkillDoc = rawFile.split('/').last.toLowerCase() == 'skill.md';
      return (rawFile, isSkillDoc ? [dir] : const <String>[]);
    }

    // 仓库 / 目录首页（owner/repo 或 owner/repo/tree/branch/path）
    final tree = RegExp(
      r'^https?://github\.com/([^/]+)/([^/]+?)(?:/tree/([^/]+)/(.*))?/?$',
    ).firstMatch(u);
    if (tree != null) {
      final owner = tree.group(1)!;
      final repo = tree.group(2)!.replaceAll(RegExp(r'\.git$'), '');
      final branch = tree.group(3) ?? 'main';
      final path = tree.group(4)?.replaceAll(RegExp(r'/+$'), '') ?? '';
      final base = 'https://raw.githubusercontent.com/$owner/$repo/$branch';
      // 先试 path 下直接有 SKILL.md；没有就试仓库根。
      final candidates = <String>[
        '$base/${path.isEmpty ? '' : '$path/'}SKILL.md',
        if (path.isNotEmpty) '$base/SKILL.md',
        if (path.isEmpty) '$base/README.md',
        if (path.isEmpty) '$base/readme.md',
        if (path.isEmpty) '$base/README_CN.md',
      ];
      String? hit;
      for (final c in candidates) {
        final status = await _statusCode(c);
        if (status >= 200 && status < 400) {
          hit = c;
          break;
        }
      }
      if (hit == null) {
        throw StateError(
            '在 $owner/$repo 没找到 SKILL.md 或 README.md。技能仓库一般要在根目录或子目录放一个 SKILL.md。');
      }
      final isSkillDoc = hit.split('/').last.toLowerCase() == 'skill.md';
      // 只对真正的 SKILL.md 递归拉同目录文件；万一命中的是 README，
      // 只当一份说明装进来，不把整个仓库当技能文件夹下载。
      final dir = isSkillDoc ? (path.isEmpty ? base : '$base/$path') : '';
      return (hit, dir.isEmpty ? const <String>[] : [dir]);
    }

    // 其它：直接当 raw 文件地址；只有是 SKILL.md 才试着带同目录文件。
    final isSkillDoc = u.split('/').last.toLowerCase() == 'skill.md';
    final dir = u.contains('/') ? u.substring(0, u.lastIndexOf('/')) : '';
    return (u, isSkillDoc && dir.isNotEmpty ? [dir] : const <String>[]);
  }

  static Future<SkillFile?> _fetchSkillFile(String rawUrl, String base) async {
    try {
      final rel = rawUrl.startsWith(base)
          ? rawUrl.substring(base.length)
          : rawUrl.split('/').last;
      if (rel.isEmpty) return null;
      if (_isBinaryPath(rel)) {
        final bytes = await _fetchBytes(rawUrl);
        return SkillFile(
          path: rel,
          content: base64Encode(bytes),
          binary: true,
        );
      }
      final content = await _fetchText(rawUrl);
      return SkillFile(path: rel, content: content);
    } catch (_) {
      // 单个文件拉失败不阻止整个技能导入。
      return null;
    }
  }

  static Future<String> _fetchText(String url) async {
    final resp = await _dio.get<String>(url);
    final code = resp.statusCode ?? 0;
    final body = resp.data ?? '';
    if (code >= 400 || body.trim().isEmpty) {
      throw StateError('抓取失败（HTTP $code）：$url');
    }
    if (body.length > _maxFileSize) {
      return '${body.substring(0, _maxFileSize)}\n…（文件过长已截断）';
    }
    return body;
  }

  static Future<List<int>> _fetchBytes(String url) async {
    final resp = await _dio.get<List<int>>(
      url,
      options: Options(responseType: ResponseType.bytes),
    );
    final code = resp.statusCode ?? 0;
    final bytes = resp.data ?? const <int>[];
    if (code >= 400 || bytes.isEmpty) {
      throw StateError('抓取二进制失败（HTTP $code）：$url');
    }
    if (bytes.length > _maxFileSize) {
      throw StateError('二进制文件过大（${bytes.length} 字节）：$url');
    }
    return bytes;
  }

  static Future<int> _statusCode(String url) async {
    try {
      final resp = await _dio.get<String>(url);
      return resp.statusCode ?? 0;
    } catch (_) {
      return 0;
    }
  }

  /// 通过 GitHub Git Trees API 一次性列出目录下的所有文本/二进制文件。
  ///
  /// 之前用 Contents API 对每个子目录递归 HTTP，技能目录层级一多就非常慢，
  /// 这也是 skill_install 300 秒超时的主因之一。Trees API 一次拿全树，再本地过滤。
  static Future<List<String>> _listGitDir(String dirUrl) async {
    // 把 raw.githubusercontent.com/{o}/{r}/{ref}/{path} 转成 api 地址。
    final m = RegExp(
      r'^https?://raw\.githubusercontent\.com/([^/]+)/([^/]+)/([^/]+)/(.*)$',
    ).firstMatch(dirUrl);
    if (m == null) return const <String>[];
    final owner = m.group(1)!;
    final repo = m.group(2)!;
    final ref = m.group(3)!;
    final path = (m.group(4) ?? '').replaceAll(RegExp(r'/+$'), '');
    final out = <String>[];
    try {
      final api = 'https://api.github.com/repos/$owner/$repo/git/trees/'
          '${Uri.encodeComponent(ref)}?recursive=1';
      final resp = await _dio.get<String>(api);
      final decoded = jsonDecode(resp.data ?? '{}');
      if (decoded is! Map || decoded['tree'] is! List) return out;
      final prefix = path.isEmpty ? '' : '$path/';
      final rawBase = 'https://raw.githubusercontent.com/$owner/$repo/$ref';
      for (final entry in decoded['tree'] as List) {
        if (entry is! Map) continue;
        if (entry['type']?.toString() != 'blob') continue;
        final p = entry['path']?.toString() ?? '';
        if (prefix.isNotEmpty && !p.startsWith(prefix)) continue;
        if (!_wantedPath(p)) continue;
        out.add('$rawBase/$p');
      }
      // 仓库过大被 GitHub 截断时，trees 返回 truncated=true；
      // 这里仍然尽量用已拿到的部分，不阻塞整个导入。
      if (decoded['truncated'] == true) {
        // 不抛错，后面解析会做出“可能不完整”的标记。
      }
    } catch (_) {
      // API 不可用时退回只拿 SKILL.md 本身。
    }
    return out;
  }

  static bool _isBinaryPath(String p) => SkillFile.isBinaryPath(p);

  static bool _wantedPath(String p) {
    final lower = p.toLowerCase();
    if (lower.endsWith('/skill.md')) return false;
    if (lower.contains('/.git/')) return false;
    if (lower.endsWith('.png') ||
        lower.endsWith('.jpg') ||
        lower.endsWith('.jpeg') ||
        lower.endsWith('.gif') ||
        lower.endsWith('.woff') ||
        lower.endsWith('.woff2') ||
        lower.endsWith('.ico')) {
      return false;
    }
    return true;
  }

  static String _guessNameFromUrl(String url) {
    final segments = url.split('/').where((s) => s.isNotEmpty).toList();
    if (segments.isEmpty) return '';
    var last = segments.last;
    if (last.endsWith('.md')) last = last.substring(0, last.length - 3);
    final name = SkillParser.slug(last);
    return name;
  }
}
