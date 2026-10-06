class AuditLog {
  AuditLog({
    required this.time,
    required this.module,
    required this.action,
    required this.detail,
    required this.result,
    this.messageIndex,
  }) : id = '${time.microsecondsSinceEpoch}_$module';

  final String id;
  final DateTime time;
  final String module;
  final String action;
  final String detail;
  final String result;

  /// 这条记录对应聊天列表里的消息下标；旧记录可能没有。
  final int? messageIndex;
}

extension AuditLogCodec on AuditLog {
  Map<String, dynamic> toJson() => {
        'time': time.toIso8601String(),
        'module': module,
        'action': action,
        'detail': detail,
        'result': result,
        'messageIndex': messageIndex,
      };

  static AuditLog fromJson(Map<String, dynamic> json) {
    return AuditLog(
      time: DateTime.tryParse(json['time']?.toString() ?? '') ?? DateTime.now(),
      module: json['module']?.toString() ?? '',
      action: json['action']?.toString() ?? '',
      detail: json['detail']?.toString() ?? '',
      result: json['result']?.toString() ?? '',
      messageIndex: json['messageIndex'] is int
          ? json['messageIndex'] as int
          : null,
    );
  }
}
