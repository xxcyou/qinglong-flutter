class AuditLog {
  AuditLog({
    required this.time,
    required this.module,
    required this.action,
    required this.detail,
    required this.result,
  }) : id = '${time.microsecondsSinceEpoch}_$module';

  final String id;
  final DateTime time;
  final String module;
  final String action;
  final String detail;
  final String result;
}

extension AuditLogCodec on AuditLog {
  Map<String, dynamic> toJson() => {
        'time': time.toIso8601String(),
        'module': module,
        'action': action,
        'detail': detail,
        'result': result,
      };

  static AuditLog fromJson(Map<String, dynamic> json) {
    return AuditLog(
      time: DateTime.tryParse(json['time']?.toString() ?? '') ?? DateTime.now(),
      module: json['module']?.toString() ?? '',
      action: json['action']?.toString() ?? '',
      detail: json['detail']?.toString() ?? '',
      result: json['result']?.toString() ?? '',
    );
  }
}
