import 'dart:convert';

/// 知识库里的一条文档。
///
/// 知识库与记忆库完全分离：记忆会按相关度注入上下文，知识库**永远不会**被
/// 自动注入，只有 AI 主动调 kb_search / kb_read 时才碰得到。
class KnowledgeDoc {
  const KnowledgeDoc({
    required this.path,
    required this.name,
    required this.title,
    required this.tags,
    required this.content,
    required this.size,
    required this.updatedAt,
  });

  final String path;
  final String name;

  /// 展示/检索用标题（优先读 frontmatter title，没有则取文件名）。
  final String title;
  final List<String> tags;

  /// 全文（含 frontmatter 原始内容，UI 编辑时直接改它）。
  final String content;
  final int size;
  final DateTime updatedAt;

  String get snippet {
    final body = content.replaceFirst(RegExp(r'^---[\s\S]*?---'), '').trim();
    if (body.isEmpty) return '（空文档）';
    final single = body.replaceAll(RegExp(r'\s+'), ' ').trim();
    return single.length > 180 ? '${single.substring(0, 180)}…' : single;
  }

  KnowledgeDoc copyWith({
    String? path,
    String? name,
    String? title,
    List<String>? tags,
    String? content,
    int? size,
    DateTime? updatedAt,
  }) {
    return KnowledgeDoc(
      path: path ?? this.path,
      name: name ?? this.name,
      title: title ?? this.title,
      tags: tags ?? this.tags,
      content: content ?? this.content,
      size: size ?? this.size,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  /// 解析一个 Markdown 文档。frontmatter 示例：
  /// ```
  /// ---
  /// title: 青龙登录接口
  /// tags:
  ///   - 青龙
  ///   - API
  /// ---
  /// 正文...
  /// ```
  factory KnowledgeDoc.parse({
    required String path,
    required String name,
    required String raw,
    required int size,
    required DateTime updatedAt,
  }) {
    var title = name.endsWith('.md') ? name.substring(0, name.length - 3) : name;
    var tags = <String>[];
    var body = raw;
    final lines = raw.split('\n');
    if (lines.isNotEmpty && lines.first.trim() == '---') {
      var end = -1;
      for (var i = 1; i < lines.length; i++) {
        if (lines[i].trim() == '---') {
          end = i;
          break;
        }
      }
      if (end > 0) {
        final meta = lines.sublist(1, end);
        for (final line in meta) {
          final t = line.trim();
          if (t.startsWith('title:')) {
            final v = t.substring(6).trim();
            if (v.isNotEmpty) title = v;
          } else if (t.startsWith('- ')) {
            final tag = t.substring(2).trim();
            if (tag.isNotEmpty) tags.add(tag);
          }
        }
        body = lines.skip(end + 1).join('\n').trim();
      }
    }

    // tags 也许用 `tags: [a, b]` 或 JSON 数组写过，兜底解析一下。
    if (tags.isEmpty) {
      final tagsMatch = RegExp(r'tags\s*:\s*(\[.*?\])').firstMatch(raw);
      if (tagsMatch != null) {
        final arrText = tagsMatch.group(1)!;
        try {
          tags = [
            for (final t in (jsonDecode(arrText) as List? ?? const []))
              t.toString().trim(),
          ].where((t) => t.isNotEmpty).toList();
        } catch (_) {
          // 不是合法 JSON 就不强拆，留给人工改。
        }
      }
    }

    return KnowledgeDoc(
      path: path,
      name: name,
      title: title.trim(),
      tags: tags,
      content: body,
      size: size,
      updatedAt: updatedAt,
    );
  }

  /// 重新生成带 frontmatter 的 Markdown。
  String render() {
    final body = content.trim();
    final buffer = StringBuffer()
      ..writeln('---')
      ..writeln('title: ${_escapeMeta(title)}')
      ..writeln('tags: [${tags.map((t) => _escapeJson(t)).join(', ')}]')
      ..writeln('---');
    if (body.isNotEmpty) buffer.writeln('\n$body\n');
    return buffer.toString();
  }

  static String _escapeMeta(String v) =>
      v.replaceAll('\n', ' ').replaceAll('\r', '').trim();

  static String _escapeJson(String v) =>
      jsonEncode(v.replaceAll('\n', ' ').trim());
}
