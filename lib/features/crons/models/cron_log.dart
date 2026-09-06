class CronLog {
  const CronLog({
    required this.lines,
    this.dir,
    this.file,
  });

  final List<String> lines;
  final String? dir;
  final String? file;

  /// 青龙 `/crons/:id/log` 直接返回**整段字符串**（不是数组），
  /// 老实现只认 List/Map，遇到 String 静默返回空——表现就是「运行后弹出的
  /// 日志永远停在『还没有输出』」。这里三种形态都要吃下。
  factory CronLog.fromJson(dynamic data) {
    if (data is String) return CronLog(lines: _split(data));
    if (data is List) {
      return CronLog(lines: data.map((e) => e.toString()).toList());
    }
    if (data is Map<String, dynamic>) {
      final raw = data['data'] ?? data['lines'] ?? data['log'] ?? const [];
      if (raw is String) return CronLog(lines: _split(raw));
      return CronLog(
        lines: raw is List ? raw.map((e) => e.toString()).toList() : const [],
        dir: data['dir'] as String?,
        file: data['file'] as String?,
      );
    }
    return const CronLog(lines: []);
  }

  static List<String> _split(String text) {
    if (text.trim().isEmpty) return const [];
    // 去掉尾部空行，避免日志末尾一堆空白撑高列表。
    final lines = text.replaceAll('\r\n', '\n').split('\n');
    while (lines.isNotEmpty && lines.last.trim().isEmpty) {
      lines.removeLast();
    }
    return lines;
  }
}
