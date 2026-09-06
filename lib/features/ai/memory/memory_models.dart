import 'dart:convert';

/// AI 记忆的分类。分类只影响提示词里的分组展示与检索加权，
/// 不做强约束——模型写错类别不算错误，只是排序差一点。
enum MemoryKind {
  fact('事实', '面板结构、脚本用途、依赖关系等客观信息'),
  preference('偏好', '用户喜欢怎么做事、命名口味、通知渠道'),
  env('环境', '主机地址、路径、已装软件、凭据位置（不存明文密钥）'),
  lesson('经验', '踩过的坑与正确做法，避免重复犯错'),
  task('待办', '跨会话要继续跟进的事情');

  const MemoryKind(this.label, this.hint);

  final String label;
  final String hint;

  static MemoryKind parse(String? raw) {
    final key = (raw ?? '').trim().toLowerCase();
    for (final k in MemoryKind.values) {
      if (k.name == key || k.label == raw) return k;
    }
    return MemoryKind.fact;
  }
}

/// 一条长期记忆。
class AiMemory {
  const AiMemory({
    required this.id,
    required this.content,
    this.kind = MemoryKind.fact,
    this.tags = const [],
    this.importance = 3,
    this.pinned = false,
    required this.createdAt,
    required this.updatedAt,
    this.hits = 0,
  });

  final String id;
  final String content;
  final MemoryKind kind;
  final List<String> tags;

  /// 1-5，越大越优先注入。
  final int importance;

  /// 置顶的记忆每轮都注入，不参与淘汰。
  final bool pinned;
  final DateTime createdAt;
  final DateTime updatedAt;

  /// 被检索命中的次数，用于排序（常用的往前）。
  final int hits;

  AiMemory copyWith({
    String? content,
    MemoryKind? kind,
    List<String>? tags,
    int? importance,
    bool? pinned,
    DateTime? updatedAt,
    int? hits,
  }) {
    return AiMemory(
      id: id,
      content: content ?? this.content,
      kind: kind ?? this.kind,
      tags: tags ?? this.tags,
      importance: importance ?? this.importance,
      pinned: pinned ?? this.pinned,
      createdAt: createdAt,
      updatedAt: updatedAt ?? DateTime.now(),
      hits: hits ?? this.hits,
    );
  }

  /// 提示词里的一行。带 id 是为了让模型能精确更新/删除某条。
  String toPromptLine() {
    final tagText = tags.isEmpty ? '' : '［${tags.join('/')}］';
    return '- [$id]$tagText$content';
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'content': content,
        'kind': kind.name,
        'tags': tags,
        'importance': importance,
        'pinned': pinned,
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
        'hits': hits,
      };

  factory AiMemory.fromJson(Map<String, dynamic> json) {
    DateTime parse(dynamic v) =>
        DateTime.tryParse(v?.toString() ?? '') ?? DateTime.now();
    return AiMemory(
      id: json['id']?.toString() ??
          DateTime.now().microsecondsSinceEpoch.toString(),
      content: json['content']?.toString() ?? '',
      kind: MemoryKind.parse(json['kind']?.toString()),
      tags: [
        for (final t in (json['tags'] as List? ?? const [])) t.toString(),
      ],
      importance: (json['importance'] as num?)?.toInt().clamp(1, 5) ?? 3,
      pinned: json['pinned'] as bool? ?? false,
      createdAt: parse(json['createdAt']),
      updatedAt: parse(json['updatedAt']),
      hits: (json['hits'] as num?)?.toInt() ?? 0,
    );
  }

  static String encodeList(List<AiMemory> items) =>
      jsonEncode([for (final m in items) m.toJson()]);

  static List<AiMemory> decodeList(String raw) {
    if (raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return [
        for (final item in decoded)
          if (item is Map<String, dynamic>) AiMemory.fromJson(item),
      ];
    } catch (e) {
      return const [];
    }
  }
}
