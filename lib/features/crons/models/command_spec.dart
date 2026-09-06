/// 「用什么命令 + 空格 + 什么脚本」——命令行的积木拆解。
///
/// 青龙里 99% 的任务就是 `runner script args` 这个形状，
/// 所以把它拆成三块可视化选择，比让用户对着一个空输入框敲要快得多。
class CommandSpec {
  const CommandSpec({
    this.runner = 'task',
    this.script = '',
    this.args = '',
    this.raw = '',
    this.useRaw = false,
  });

  /// 执行器：task / python3 / node / bash / 自定义。
  final String runner;

  /// 脚本路径（相对青龙 scripts 目录）。
  final String script;

  /// 追加参数（如 now）。
  final String args;

  /// 完全自定义时的原始命令。
  final String raw;
  final bool useRaw;

  /// 常见执行器。任何时候都允许自定义，所以这只是快捷入口。
  static const runners = ['task', 'python3', 'node', 'bash', 'sh'];

  CommandSpec copyWith({
    String? runner,
    String? script,
    String? args,
    String? raw,
    bool? useRaw,
  }) {
    return CommandSpec(
      runner: runner ?? this.runner,
      script: script ?? this.script,
      args: args ?? this.args,
      raw: raw ?? this.raw,
      useRaw: useRaw ?? this.useRaw,
    );
  }

  String get command {
    if (useRaw) return raw.trim();
    final parts = [
      runner.trim(),
      script.trim(),
      args.trim(),
    ].where((p) => p.isNotEmpty);
    return parts.join(' ');
  }

  bool get isValid =>
      command.isNotEmpty && (useRaw || script.trim().isNotEmpty);

  /// 反解已有命令：认得出 `runner script args` 就落回积木，否则走原始模式。
  static CommandSpec parse(String raw) {
    final text = raw.trim();
    if (text.isEmpty) return const CommandSpec();
    final parts = text.split(RegExp(r'\s+'));
    if (parts.length < 2) {
      return CommandSpec(useRaw: true, raw: text);
    }
    // 管道 / 重定向 / 多命令一律当原始命令，别自作聪明拆坏了。
    if (RegExp(r'[|&;><$`]').hasMatch(text)) {
      return CommandSpec(useRaw: true, raw: text);
    }
    return CommandSpec(
      runner: parts.first,
      script: parts[1],
      args: parts.length > 2 ? parts.sublist(2).join(' ') : '',
      raw: text,
    );
  }
}
