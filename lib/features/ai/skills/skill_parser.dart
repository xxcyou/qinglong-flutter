/// SKILL.md 解析结果：frontmatter 字段 + 正文。
class ParsedSkillDoc {
  const ParsedSkillDoc({
    required this.name,
    required this.description,
    this.license = '',
    this.metadata = const {},
    required this.instructions,
  });

  final String name;
  final String description;
  final String license;

  /// metadata 里的附加键值（自定义字段）。
  final Map<String, String> metadata;

  /// 去掉 frontmatter 后的 Markdown 正文。
  final String instructions;

  String get whenToUse {
    // 优先取 metadata 里的 when_to_use（本 App 扩展字段，兼容旧版）；没有就留空。
    final w = metadata['when_to_use'] ?? metadata['whenToUse'];
    return w ?? '';
  }
}

/// 兼容市面 Agent Skills / Claude Skills 的 `SKILL.md` 解析器。
///
/// 格式：文件最开头是 `---` 包裹的 YAML frontmatter，之后是 Markdown 正文。
/// frontmatter 至少要有 `name`、`description` 两个字段。
class SkillParser {
  const SkillParser._();

  static final _frontmatterRe = RegExp(r'^---\r?\n([\s\S]*?)\r?\n---\r?\n?');

  /// 解析一份 SKILL.md 内容。
  ///
  /// - 没有合法 frontmatter 时：把整份当正文，name/description 尽力从标题里猜。
  /// - frontmatter 是宽松 YAML 子集（`key: value` 扁平键值、简单列表、引号剥离）。
  static ParsedSkillDoc parse(String raw) {
    final match = _frontmatterRe.firstMatch(raw);
    if (match == null) {
      final body = raw.trim();
      final (name, description) = _guessFromBody(body);
      return ParsedSkillDoc(
        name: name,
        description: description,
        instructions: body,
      );
    }
    final yamlBlock = match.group(1)!;
    final body = raw.substring(match.end).trim();
    final kv = _parseYaml(kv: yamlBlock);

    String name = kv['name']?.trim() ?? '';
    String description = kv['description']?.trim() ?? '';
    final license = kv['license']?.trim() ?? '';
    final metadata = <String, String>{};

    // metadata 可能是一个 map 块，或 metadata.key = val 这种拍平写法。
    final metaMap = _parseMetadata(kv);
    metadata.addAll(metaMap);

    // 缺 name/description 时从正文标题兜底。
    if (name.isEmpty || description.isEmpty) {
      final (guessName, guessDesc) = _guessFromBody(body);
      if (name.isEmpty) name = guessName;
      if (description.isEmpty) description = guessDesc;
    }

    return ParsedSkillDoc(
      name: name,
      description: description,
      license: license,
      metadata: metadata,
      instructions: body,
    );
  }

  static Map<String, String> _parseYaml({required String kv}) {
    final out = <String, String>{};
    String? topKey;
    for (final rawLine in kv.split('\n')) {
      final line = rawLine.trimRight();
      if (line.trim().isEmpty) continue;
      final indent = line.length - line.trimLeft().length;
      final content = line.trim();
      if (indent == 0) {
        final colon = content.indexOf(':');
        if (colon < 0) continue;
        topKey = content.substring(0, colon).trim();
        final rest = content.substring(colon + 1).trim();
        if (rest.isNotEmpty) {
          out[topKey] = _unquote(rest);
        } else {
          // 顶层是一个嵌套块，交给下一层处理。
          out[topKey] = '';
        }
      } else if (topKey != null && out[topKey] == '') {
        // 缩进行归到当前 topKey 的嵌套内容里（简单 map / 列表）。
        if (content.startsWith('- ')) {
          out['$topKey.items'] = (out['$topKey.items']?.isNotEmpty ?? false)
              ? '${out['$topKey.items']}\n${_unquote(content.substring(2).trim())}'
              : _unquote(content.substring(2).trim());
        } else {
          final colon = content.indexOf(':');
          if (colon >= 0) {
            final k = content.substring(0, colon).trim();
            final v = _unquote(content.substring(colon + 1).trim());
            // 拍平成 metadata.key = v，供上层读取。
            out['$topKey.$k'] = v;
          }
        }
      }
    }
    return out;
  }

  static Map<String, String> _parseMetadata(Map<String, String> kv) {
    final meta = <String, String>{};
    // metadata 无论是 map（metadata.key=...）还是列表块，都收进 metadata。
    for (final entry in kv.entries) {
      final k = entry.key;
      if (k.startsWith('metadata.')) {
        meta[k.substring('metadata.'.length)] = entry.value;
      }
    }
    return meta;
  }

  static (String, String) _guessFromBody(String body) {
    final lines = body.split('\n');
    final title = lines
        .map((l) => l.trim())
        .firstWhere((l) => l.startsWith('# '), orElse: () => '');
    final name = title.startsWith('# ') ? slug(title.substring(2).trim()) : '';
    final description = lines.map((l) => l.trim()).firstWhere(
        (l) => l.isNotEmpty && !l.startsWith('#'),
        orElse: () => '');
    return (name, description);
  }

  static String _unquote(String s) {
    var v = s.trim();
    if ((v.startsWith('"') && v.endsWith('"')) ||
        (v.startsWith("'") && v.endsWith("'"))) {
      v = v.substring(1, v.length - 1);
    }
    return v;
  }

  static String slug(String s) => s
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9\u4e00-\u9fff]+'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');
}
