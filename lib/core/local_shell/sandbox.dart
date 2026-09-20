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

  /// 系统关键目录/文件：无论确认策略是“全部放行”还是一般模式，
  /// 都禁止删除、覆盖、移动/拷贝到这些路径里，避免把运行环境搞坏。
  static const protectedPaths = [
    '/bin',
    '/boot',
    '/data',
    '/dev',
    '/etc',
    '/lib',
    '/lib64',
    '/lost+found',
    '/proc',
    '/root',
    '/run',
    '/sbin',
    '/srv',
    '/sys',
    '/system',
    '/usr',
    '/var',
  ];

  /// [fullAllow] 为 true 时完全放行：确认策略选“全部放行”后，
  /// AI 可以自由删除/覆盖/执行命令，不再受命令沙箱限制。
  ///
  /// 默认（严格/仅危险/未传）仍保留黑名单与受保护路径防线。
  void validate(String command, {bool fullAllow = false}) {
    if (fullAllow) return;
    final normalized = command.trim().toLowerCase();
    for (final pattern in blockedPatterns) {
      if (normalized.contains(pattern.toLowerCase())) {
        throw ArgumentError('命令被沙箱拦截：$pattern');
      }
    }
    _guardProtectedPaths(normalized);
    if (normalized.length > 8192) {
      throw ArgumentError('命令过长');
    }
  }

  static void _guardProtectedPaths(String command) {
    final tokens =
        command.split(RegExp(r'\s+')).where((t) => t.isNotEmpty).toList();
    final hasRm = tokens.any((t) => _isCommand(t, 'rm'));
    final hasMoveCopy = tokens.any((t) =>
        _isCommand(t, 'mv') ||
        _isCommand(t, 'cp') ||
        _isCommand(t, 'install') ||
        _isCommand(t, 'ln'));
    final hasTeeDd = tokens.any((t) =>
        _isCommand(t, 'tee') ||
        _isCommand(t, 'dd') ||
        _isCommand(t, 'truncate'));
    final hasSedInPlace = command.contains('sed ') && command.contains('-i');

    // 1) rm：只拦“删到受保护路径里”。rm -rf /tmp/垃圾 放行。
    if (hasRm) {
      for (final token in tokens) {
        if (_isProtectedPath(token)) {
          throw ArgumentError('沙箱拒绝删除受保护路径：$token');
        }
      }
    }

    // 2) 重定向覆盖：> /etc/xxx、> /var/xxx 一律拦截。
    final redir = RegExp(r'>\s*[^;|&\s]+');
    for (final m in redir.allMatches(command)) {
      final target = m.group(0)!.substring(1).trim();
      if (_isProtectedPath(target)) {
        throw ArgumentError('沙箱拒绝覆盖受保护文件：$target');
      }
    }

    // 3) mv/cp/install/ln/tee/dd/truncate 只要碰到受保护路径就拦截。
    if (hasMoveCopy || hasTeeDd) {
      for (final token in tokens) {
        if (_isProtectedPath(token) || _isOfParameter(token)) {
          throw ArgumentError('沙箱拒绝危险文件操作：$token');
        }
      }
    }

    // 4) sed -i 直接改受保护文件也拦。
    if (hasSedInPlace) {
      for (final token in tokens) {
        if (_isProtectedPath(token)) {
          throw ArgumentError('沙箱拒绝覆盖受保护文件：$token');
        }
      }
    }
  }

  static bool _isCommand(String token, String name) {
    // 兼容 rm、/bin/rm、rm.exe、busybox rm 等写法。
    return token == name ||
        token.endsWith('/$name') ||
        token.endsWith('$name.exe');
  }

  static bool _isProtectedPath(String token) {
    var t = token
        .replaceAll("'", '')
        .replaceAll('"', '')
        .replaceAll(r'$', '')
        .replaceAll('`', '')
        .replaceAll('(', '')
        .replaceAll(')', '')
        .trim();
    // 去掉常见结尾符号：;、|、&、>、<，避免 `rm -rf /etc;` 这类漏网。
    t = t.replaceAll(RegExp(r'[;|&><]+$'), '');
    if (!t.startsWith('/')) return false;
    for (final p in protectedPaths) {
      if (t == p || t.startsWith('$p/')) return true;
    }
    // 形如 /dev/block/sda1 这类也被 /dev 覆盖；这里不需要再扩展。
    return false;
  }

  static bool _isOfParameter(String token) {
    // dd of=/dev/block/xx、truncate -s 0 /etc/xx
    return token.startsWith('of=') && _isProtectedPath(token.substring(3));
  }

  int get maxOutputBytes => _maxOutputBytes;
}
