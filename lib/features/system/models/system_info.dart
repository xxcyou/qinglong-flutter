class SystemInfo {
  const SystemInfo({this.version = '', this.logRemoveFrequency, this.data});

  final String version;
  final int? logRemoveFrequency;
  final Map<String, dynamic>? data;

  factory SystemInfo.fromJson(Map<String, dynamic> json) {
    int? asInt(dynamic v) {
      if (v == null) return null;
      if (v is int) return v;
      if (v is num) return v.toInt();
      if (v is String) return int.tryParse(v.trim());
      return null;
    }

    int? nestedFrequency;
    final nested = json['info'];
    if (nested is Map<String, dynamic>) {
      nestedFrequency = asInt(nested['frequency']);
    }

    return SystemInfo(
      version: (json['version'] ?? json['data']?['version'] ?? '').toString(),
      logRemoveFrequency: asInt(json['logRemoveFrequency']) ?? nestedFrequency,
      data: json,
    );
  }
}
