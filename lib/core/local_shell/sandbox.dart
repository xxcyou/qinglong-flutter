/// 本地命令沙箱：朴素但可用的黑名单 + 输出/超时控制。
class CommandSandbox {
  const CommandSandbox();

  static const blockedPatterns = [
    'rm -rf /',
    'rm -fr /',
    'mkfs',
    'shutdown',
    'reboot',
    'poweroff',
    'halt',
    'curl | sh',
    'curl|sh',
    'wget | sh',
    'wget|sh',
    '| sh',
    '|sh',
    '| bash',
    '|bash',
  ];

  static const _maxOutputBytes = 512 * 1024;

  void validate(String command) {
    final normalized = command.trim().toLowerCase();
    for (final pattern in blockedPatterns) {
      if (normalized.contains(pattern.toLowerCase())) {
        throw ArgumentError('命令被沙箱拦截：$pattern');
      }
    }
    if (normalized.length > 8192) {
      throw ArgumentError('命令过长');
    }
  }

  int get maxOutputBytes => _maxOutputBytes;
}
