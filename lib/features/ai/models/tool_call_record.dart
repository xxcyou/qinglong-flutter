class ToolCallRecord {
  const ToolCallRecord({
    this.toolName = '',
    this.args = const {},
    this.status = '',
    this.result = '',
    this.durationMs,
    this.createdAt,
  });

  final String toolName;
  final Map<String, dynamic> args;
  final String status;
  final String result;
  final int? durationMs;
  final DateTime? createdAt;
}
