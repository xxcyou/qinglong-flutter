/// 脚本文件树节点（P2 实现）。
class ScriptNode {
  const ScriptNode({
    this.title = '',
    this.key,
    this.isLeaf = false,
    this.children = const [],
    this.size,
  });

  final String title;
  final String? key;
  final bool isLeaf;
  final List<ScriptNode> children;

  /// 文件大小（字节）；后端未返回时为 null。
  final int? size;

  factory ScriptNode.fromJson(Map<String, dynamic> json) {
    bool? asBool(dynamic v) {
      if (v == null) return null;
      if (v is bool) return v;
      if (v is int) return v != 0;
      if (v is String) {
        final t = v.trim().toLowerCase();
        return t == '1' || t == 'true';
      }
      return null;
    }

    int? asInt(dynamic v) {
      if (v is int) return v;
      if (v is num) return v.toInt();
      if (v is String) return int.tryParse(v.trim());
      return null;
    }

    final type = json['type'] as String?;
    return ScriptNode(
      title: json['title'] as String? ?? '',
      key: json['key'] as String?,
      isLeaf: type == 'file' || (asBool(json['isLeaf']) ?? false),
      children: (json['children'] as List? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(ScriptNode.fromJson)
          .toList(),
      size: asInt(json['size']) ?? asInt(json['fileSize']),
    );
  }
}
