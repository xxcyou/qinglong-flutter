class Dependency {
  const Dependency({
    this.id,
    this.type = 0,
    this.name = '',
    this.status = '',
    this.log,
    this.remark,
    this.updated,
  });

  final int? id;
  final int type;
  final String name;
  final String status;
  final String? log;
  final String? remark;
  final String? updated;

  factory Dependency.fromJson(Map<String, dynamic> json) {
    int? asInt(dynamic v) {
      if (v == null) return null;
      if (v is int) return v;
      if (v is num) return v.toInt();
      if (v is String) return int.tryParse(v.trim());
      return null;
    }

    return Dependency(
      id: asInt(json['id']),
      type: asInt(json['type']) ?? 0,
      name: json['name'] as String? ?? '',
      status: json['status']?.toString() ?? '',
      log: json['log'] is List
          ? (json['log'] as List).join('\n')
          : json['log']?.toString(),
      remark: json['remark']?.toString(),
      updated: json['updated']?.toString(),
    );
  }
}
