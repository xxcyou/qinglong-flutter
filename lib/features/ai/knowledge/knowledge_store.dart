import '../../../core/local_shell/proot_bridge.dart';
import 'knowledge_models.dart';

/// 文件式知识库。
///
/// 不引入向量库/嵌入模型：
///  - 存成 /workspace/.knowledge/*.md，文件管理器直接可见、可改；
///  - 检索用「标题 + 标签 + 正文」的关键词全文匹配，足够覆盖"经验/方案/踩坑"
///   这类主动查一下的使用场景。
///
/// 知识库存放路径固定为 [/workspace/.knowledge]，因为 AI 的 shell_* 工具本来
/// 就能直接读写这个目录，管理页和 AI 看到的是同一份。
class KnowledgeStore {
  static const root = '/workspace/.knowledge';

  final ProotBridge _bridge = ProotBridge();

  Future<void> ensureRoot() async {
    try {
      await _bridge.makeDirectory(root);
    } catch (_) {
      // 已存在时原生侧不一定报错，但有些版本会；这里不抛。
    }
  }

  /// 列出全部文档，按修改时间倒序。
  Future<List<KnowledgeDoc>> list() async {
    await ensureRoot();
    final listing = await _bridge.listFiles(path: root);
    final docs = <KnowledgeDoc>[];
    for (final f in listing.entries) {
      if (f.isDirectory || !f.name.toLowerCase().endsWith('.md')) continue;
      final raw = await _bridge.readFile(path: f.path, maxBytes: 1024 * 1024);
      docs.add(
        KnowledgeDoc.parse(
          path: f.path,
          name: f.name,
          raw: raw,
          size: f.size,
          updatedAt: f.modified,
        ),
      );
    }
    docs.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return docs;
  }

  /// 读取某篇完整文档（正文 + frontmatter 已解析成 [KnowledgeDoc]）。
  Future<KnowledgeDoc> read(String path) async {
    if (!_isInsideRoot(path)) {
      throw ArgumentError('路径越界，知识库只能操作 $root 下的文档');
    }
    final name = path.split('/').last;
    final raw = await _bridge.readFile(path: path, maxBytes: 4 * 1024 * 1024);
    final stat = await _bridge.stat(path);
    return KnowledgeDoc.parse(
      path: path,
      name: name,
      raw: raw,
      size: stat.totalBytes,
      updatedAt: stat.entry.modified,
    );
  }

  /// 新建或覆盖一篇知识文档。
  ///
  /// [existingPath] 传了就更新那篇；不传按 [title] 生成文件名。
  /// 返回落盘后的文档。
  Future<KnowledgeDoc> write({
    required String title,
    required String content,
    List<String> tags = const [],
    String? existingPath,
  }) async {
    await ensureRoot();
    final cleanTitle = title.trim();
    if (cleanTitle.isEmpty) throw ArgumentError('标题不能为空');
    if (content.trim().isEmpty) throw ArgumentError('内容不能为空');

    final path = existingPath != null && existingPath.isNotEmpty
        ? (existingPath.endsWith('.md') ? existingPath : '$existingPath.md')
        : '$root/${_slug(cleanTitle)}.md';
    if (!_isInsideRoot(path)) {
      throw ArgumentError('路径越界，知识库只能写入 $root 下');
    }
    final name = path.split('/').last;
    String raw = '';
    // 覆盖旧文档时保留原始正文里可能存在的格式差异？为保持可预期，统一用 render。
    raw = KnowledgeDoc(
      path: path,
      name: name,
      title: cleanTitle,
      tags: tags,
      content: content.trim(),
      size: 0,
      updatedAt: DateTime.now(),
    ).render();

    final written = await _bridge.writeFile(path: path, content: raw);
    return KnowledgeDoc.parse(
      path: path,
      name: name,
      raw: raw,
      size: written.size,
      updatedAt: written.modified,
    );
  }

  /// 删除一篇知识文档。只能删 $root 下的 .md。
  Future<bool> delete(String path) async {
    if (!_isInsideRoot(path) || !path.toLowerCase().endsWith('.md')) {
      return false;
    }
    return _bridge.deletePath(path);
  }

  /// 关键词检索。
  ///
  /// 每个词都必须命中（标题/标签/正文任一），命中越多排序越靠前。
  /// 返回结果里带 [KnowledgeDoc.snippet]，不要求 AI 立刻读全文。
  Future<List<KnowledgeDoc>> search(
    String query, {
    int limit = 20,
  }) async {
    final docs = await list();
    final words = _tokens(query);
    if (words.isEmpty) return docs.take(limit).toList();

    final scored = <(KnowledgeDoc, int)>[];
    for (final doc in docs) {
      final haystack =
          '${doc.title} ${doc.tags.join(' ')} ${doc.content}'.toLowerCase();
      var score = 0;
      for (final w in words) {
        if (haystack.contains(w)) score += w.length >= 2 ? 2 : 1;
      }
      if (score == 0) continue;
      scored.add((doc, score));
    }
    scored.sort((a, b) {
      final byScore = b.$2.compareTo(a.$2);
      if (byScore != 0) return byScore;
      return b.$1.updatedAt.compareTo(a.$1.updatedAt);
    });
    return [for (final s in scored.take(limit)) s.$1];
  }

  static bool _isInsideRoot(String path) {
    final normalized = path.replaceAll('\\', '/');
    return normalized == root || normalized.startsWith('$root/');
  }

  static List<String> _tokens(String query) {
    final raw = query.trim().toLowerCase();
    if (raw.isEmpty) return const [];
    return raw
        .split(RegExp(r'[\s,，、;；:：]+'))
        .where((w) => w.isNotEmpty)
        .toList();
  }

  static String _slug(String title) {
    final clean = title
        .trim()
        .replaceAll(RegExp(r'[/\\?%*:|"<>\x00-\x1f]'), '-')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (clean.isEmpty) return DateTime.now().millisecondsSinceEpoch.toString();
    return clean.replaceAll(' ', '-');
  }
}
