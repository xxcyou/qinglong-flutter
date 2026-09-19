import 'dart:convert';

/// 模式库条目：一个“编辑模式/回答模式”由名字（标签）和具体指令内容组成。
///
/// 用户在输入框打 `/` 可以快速选择标签；选中后标签会出现在输入区上方，
/// 发送时把该模式的内容注入提示词，指导 AI 按这套规则干活。
class AiMode {
  const AiMode({
    required this.id,
    required this.name,
    required this.content,
    required this.createdAt,
    required this.updatedAt,
    this.enabled = true,
  });

  final String id;

  /// 标签名，也是用户在 `/标签` 里选的那个名字。
  final String name;

  /// 具体模式内容：AI 需要做什么、按什么步骤来、注意什么。
  final String content;
  final DateTime createdAt;
  final DateTime updatedAt;

  /// 如果关掉，普通 `/` 列表里不再显示，也不会被注入。
  final bool enabled;

  AiMode copyWith({
    String? name,
    String? content,
    DateTime? updatedAt,
    bool? enabled,
  }) {
    return AiMode(
      id: id,
      name: name ?? this.name,
      content: content ?? this.content,
      createdAt: createdAt,
      updatedAt: updatedAt ?? DateTime.now(),
      enabled: enabled ?? this.enabled,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'content': content,
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
        'enabled': enabled,
      };

  factory AiMode.fromJson(Map<String, dynamic> json) {
    DateTime parse(dynamic v) =>
        DateTime.tryParse(v?.toString() ?? '') ?? DateTime.now();
    return AiMode(
      id: json['id']?.toString() ??
          DateTime.now().microsecondsSinceEpoch.toString(),
      name: json['name']?.toString() ?? '',
      content: json['content']?.toString() ?? '',
      createdAt: parse(json['createdAt']),
      updatedAt: parse(json['updatedAt']),
      enabled: json['enabled'] != false,
    );
  }

  static String encodeList(List<AiMode> items) =>
      jsonEncode([for (final m in items) m.toJson()]);

  static List<AiMode> decodeList(String raw) {
    if (raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return [
        for (final item in decoded)
          if (item is Map<String, dynamic>) AiMode.fromJson(item),
      ];
    } catch (e) {
      return const [];
    }
  }
}
