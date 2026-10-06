class ToolCallRecord {
  const ToolCallRecord({
    this.toolName = '',
    this.args = const {},
    this.status = '',
    this.result = '',
    this.durationMs,
    this.createdAt,
    this.eventIndex,
  });

  final String toolName;
  final Map<String, dynamic> args;
  final String status;
  final String result;
  final int? durationMs;
  final DateTime? createdAt;

  /// 对应消息里 agentEvents 的下标，用于审计跳转到思维链中的具体工具行。
  final int? eventIndex;
}
