import '../../features/crons/models/cron_task.dart';

/// 从定时任务命令里提取脚本文件路径（相对青龙 scripts 根目录）。
///
/// 青龙最常见的是 `task xxx.js` / `node xxx.js` / `python3 xxx.py`。
/// 也兼容绝对路径 `/ql/scripts/xxx.js`，统一转成 API 能用的 `xxx.js`。
String? extractCronScriptPath(CronTask task) {
  final command = task.command.trim();
  if (command.isEmpty) return null;
  final tokens = command.split(RegExp(r'\s+'));
  var file = command;
  final first = tokens.first.toLowerCase();
  if (first == 'task' ||
      first == 'node' ||
      first == 'python3' ||
      first == 'python' ||
      first == 'bash' ||
      first == 'sh' ||
      first == 'deno' ||
      first == 'bun' ||
      first == 'tsx') {
    if (tokens.length < 2) return null;
    file = tokens[1];
  }
  if (file.startsWith('/ql/scripts/')) {
    file = file.substring('/ql/scripts/'.length);
  } else if (file.startsWith('/ql/')) {
    // 其它 /ql/ 路径不属于脚本根，先不猜，保留原样。
  }
  if (file.startsWith('/')) {
    final index = file.indexOf('scripts/');
    if (index >= 0) {
      file = file.substring(index + 'scripts/'.length);
    }
  }
  final lower = file.toLowerCase();
  if (lower.endsWith('.js') ||
      lower.endsWith('.py') ||
      lower.endsWith('.ts') ||
      lower.endsWith('.sh') ||
      lower.endsWith('.tsx')) {
    return file;
  }
  return null;
}
