import 'dart:convert';

import 'package:flutter/material.dart';

import '../../../shared/mono_text.dart';

/// 把 AI 的写文件/改文件工具调用渲染成可读的 Diff / 代码片段。
///
/// 支持：
/// - `script_write` / `shell_write_file`：新写内容（中性代码块）
/// - `script_modify_range` / `shell_modify_range`：overwrite / insert / delete
/// - `script_patch`：replace / delete / insert_before / insert_after
/// - `append=true`：显示追加内容
class FileDiffView extends StatelessWidget {
  const FileDiffView({
    super.key,
    required this.toolName,
    required this.args,
    this.result,
  });

  final String toolName;
  final Map<String, dynamic> args;
  final String? result;

  static final RegExp _diffFence =
      RegExp(r'```diff\s*\n(.*?)\n```', dotAll: true);

  String get _path {
    for (final key in const [
      'path',
      'file',
      'filename',
      'dest',
      'destination',
      'target',
      'targetPath',
      'scriptPath',
      'script_path',
      'scriptName',
      'script_name',
    ]) {
      final v = args[key]?.toString();
      if (v != null && v.trim().isNotEmpty) return v;
    }
    final fromArgs = _pathFromArgs();
    if (fromArgs != null && fromArgs.isNotEmpty) return fromArgs;
    final fromCommand = _pathFromCommand;
    if (fromCommand != null && fromCommand.isNotEmpty) return fromCommand;
    if (toolName == 'shell_exec' || toolName == 'shell_script') {
      return '本机命令';
    }
    if (toolName.toLowerCase().contains('script') ||
        toolName.toLowerCase().contains('browser') ||
        toolName.toLowerCase().contains('scr')) {
      return '脚本文件';
    }
    return '未知路径';
  }

  static const Set<String> _nonPathArgKeys = {
    'content',
    'code',
    'text',
    'new_text',
    'newText',
    'old_text',
    'oldText',
    'html',
    'command',
    'description',
    'result',
    'message',
    'stdin',
    'arguments',
    'args',
  };

  String? _pathFromArgs() {
    String? best;
    void walk(Map<String, dynamic> map) {
      for (final entry in map.entries) {
        final key = entry.key.toLowerCase();
        final value = entry.value;
        if (value is Map) {
          walk(value.cast<String, dynamic>());
          continue;
        }
        if (value is! String) continue;
        final v = value.trim();
        if (v.isEmpty || v.length > 200 || v.contains('\n')) continue;
        if (_nonPathArgKeys.contains(entry.key) ||
            key == 'code' ||
            key == 'text' ||
            key == 'html') {
          continue;
        }
        final looksPath = v.contains('/') ||
            v.contains('\\') ||
            v.endsWith('.dart') ||
            v.endsWith('.js') ||
            v.endsWith('.ts') ||
            v.endsWith('.py') ||
            v.endsWith('.sh') ||
            v.endsWith('.json') ||
            v.endsWith('.yaml') ||
            v.endsWith('.yml') ||
            v.endsWith('.txt') ||
            v.endsWith('.html') ||
            v.endsWith('.css') ||
            v.startsWith('script') ||
            v.startsWith('scripts/') ||
            v.startsWith('/') ||
            v.startsWith('./') ||
            v.startsWith('../');
        if (looksPath) {
          best ??= v;
          if (key.contains('path') ||
              key.contains('file') ||
              key.contains('name') ||
              key == 'scr') {
            return;
          }
        }
      }
    }

    walk(args);
    return best;
  }

  String? get _pathFromCommand {
    final cmd = args['command']?.toString() ?? '';
    if (cmd.isEmpty) return null;
    final patterns = [
      RegExp(r'(?:>>|>)\s*([^\s;|&]+)'),
      RegExp(r'sed\s+-i[^;|&]*?\s+([^\s;|&]+)'),
      RegExp(r'perl\s+-pi[^;|&]*?\s+([^\s;|&]+)'),
      RegExp(r'(?:^|\s)(?:cat|tee)\s+([^\s;|&]+)'),
      RegExp(r'python3?\s+([^\s;|&]+\.py)'),
      RegExp(r'(?:^|\s)(?:nano|vim|vi|touch)\s+([^\s;|&]+)'),
    ];
    for (final re in patterns) {
      final m = re.firstMatch(cmd);
      if (m != null) return m.group(1);
    }
    return null;
  }

  bool get _isBinary =>
      args['base64'] != null && args['base64'].toString().trim().isNotEmpty;

  String get _content {
    for (final key in const [
      'content',
      'code',
      'new_content',
      'newText',
      'new_text',
      'text',
      'script',
    ]) {
      final v = args[key];
      if (v != null && v.toString().isNotEmpty) return v.toString();
    }
    return '';
  }

  String? get _action {
    final raw = args['action']?.toString();
    if (raw != null && raw.isNotEmpty) return raw;
    final hasOld = args.containsKey('old_text') ||
        args.containsKey('oldText') ||
        args.containsKey('find');
    if (toolName == 'editor_patch' || hasOld) {
      if (_content.isEmpty) return 'delete';
      return 'replace';
    }
    if (toolName == 'editor_insert') return 'insert';
    if (toolName == 'editor_delete') return 'delete';
    return null;
  }

  String get _find {
    for (final key in const ['find', 'old_text', 'oldText', 'text']) {
      final v = args[key]?.toString();
      if (v != null && v.isNotEmpty) return v;
    }
    return '';
  }

  num? get _start => args['start'] is num ? args['start'] as num : null;

  num? get _end => args['end'] is num ? args['end'] as num : null;

  bool get _append => args['append'] == true;

  @override
  Widget build(BuildContext context) {
    final label = _label();
    final stats = _diffLines();
    final addCount = stats.where((l) => l.type == _DiffLineType.add).length;
    final removeCount =
        stats.where((l) => l.type == _DiffLineType.remove).length;

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(top: 6),
      decoration: BoxDecoration(
        // GitHub 深色代码块风格：浅色主题下 + / - 也能一眼看清。
        color: const Color(0xFF0D1117),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFF30363D)),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 8, 8, 6),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(5),
                  decoration: BoxDecoration(
                    color: const Color(0xFF161B22),
                    borderRadius: BorderRadius.circular(9),
                    border: Border.all(color: const Color(0xFF30363D)),
                  ),
                  child: Icon(
                    _isBinary
                        ? Icons.insert_drive_file_outlined
                        : Icons.difference_rounded,
                    size: 14,
                    color: _isBinary
                        ? const Color(0xFF58A6FF)
                        : const Color(0xFF7EE787),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _path,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w700,
                          color: Colors.white,
                          fontFamily: kMonoFamily,
                          fontFamilyFallback: kMonoFallback,
                        ),
                      ),
                      const SizedBox(height: 1),
                      Text(
                        label,
                        style: const TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
                          color: Colors.white54,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 6),
                Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(
                        text: '+$addCount',
                        style: const TextStyle(
                          fontSize: 10.5,
                          fontWeight: FontWeight.w800,
                          color: Color(0xFF7EE787),
                          fontFamily: kMonoFamily,
                          fontFamilyFallback: kMonoFallback,
                        ),
                      ),
                      const TextSpan(
                        text: '  ',
                        style: TextStyle(fontSize: 10),
                      ),
                      TextSpan(
                        text: '-$removeCount',
                        style: const TextStyle(
                          fontSize: 10.5,
                          fontWeight: FontWeight.w800,
                          color: Color(0xFFFF7B72),
                          fontFamily: kMonoFamily,
                          fontFamilyFallback: kMonoFallback,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 7,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1C2128),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: const Color(0xFF30363D)),
                  ),
                  child: const Text(
                    'DIFF',
                    style: TextStyle(
                      fontSize: 9,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.8,
                      color: Color(0xFF8B949E),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1, color: Color(0xFF30363D)),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 240),
            child: SingleChildScrollView(
              padding: const EdgeInsets.only(top: 6, bottom: 6),
              scrollDirection: Axis.vertical,
              child: _buildBody(context),
            ),
          ),
        ],
      ),
    );
  }

  String _label() {
    if (_isBinary) return '二进制写入';
    final action = _action;
    if (action != null && action.isNotEmpty) {
      switch (action) {
        case 'replace':
          return '替换';
        case 'delete':
          return '删除';
        case 'insert':
          return '插入';
        case 'overwrite':
          return '覆盖';
        case 'insert_before':
          return '前插';
        case 'insert_after':
          return '后插';
      }
    }
    if (_append) return '追加';

    if (toolName == 'shell_write_file') return '覆盖';
    if (toolName == 'script_write') return '保存/覆盖';
    if (toolName == 'config_save') return '覆盖配置';
    if (toolName == 'editor_write') return '全量覆盖';
    if (toolName == 'shell_write_binary') return '二进制覆盖';
    if (toolName == 'shell_archive_extract') return '解压';
    if (toolName == 'shell_exec' || toolName == 'shell_script') {
      final cmd = args['command']?.toString().trimLeft() ?? '';
      if (cmd.startsWith('rm ') ||
          cmd.startsWith('rmdir ') ||
          cmd.startsWith('unlink ') ||
          cmd.startsWith('rm -rf')) {
        return '命令删除';
      }
      if (cmd.startsWith('mv ') ||
          cmd.startsWith('cp ') ||
          cmd.startsWith('cat >') ||
          cmd.startsWith('tee ') ||
          cmd.startsWith('sed ')) {
        return '命令写入';
      }
      return '命令执行';
    }
    return '写入';
  }

  Widget _buildBody(BuildContext context) {
    if (_isBinary) {
      final len = args['base64'].toString().length;
      return Text(
        'base64 内容共 $len 字符，不在此展开。需要时可点右侧详情查看原始参数。',
        style: const TextStyle(fontSize: 11, color: Colors.white60),
      );
    }
    if (toolName == 'shell_write_binary') {
      return const Text(
        '二进制文件已写入，不展示内容。',
        style: TextStyle(fontSize: 11, color: Colors.white60),
      );
    }

    final lines = _diffLines();
    if (lines.isEmpty) {
      // 兜底：即使某个工具漏进了 Diff 卡，也不要出现一张空白的
      // “没有可展示的文件内容”。直接把参数/返回摊开，信息至少不丢。
      final buffer = StringBuffer();
      if (args.isNotEmpty) {
        buffer.writeln('参数：');
        try {
          buffer.writeln(const JsonEncoder.withIndent('  ').convert(args));
        } catch (_) {
          buffer.writeln(args);
        }
      }
      final out = result?.trim() ?? '';
      if (out.isNotEmpty) {
        if (buffer.isNotEmpty) buffer.writeln();
        buffer.writeln('返回：');
        buffer.writeln(out);
      }
      return SelectableText(
        buffer.isEmpty ? '（这一步没有更多内容）' : buffer.toString().trim(),
        style: const TextStyle(
          fontSize: 11,
          height: 1.45,
          color: Colors.white70,
          fontFamily: kMonoFamily,
          fontFamilyFallback: kMonoFallback,
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: _buildDiffRows(lines),
    );
  }

  List<Widget> _buildDiffRows(List<_DiffLine> lines) {
    var oldLine = 1;
    var newLine = 1;
    final rows = <Widget>[];
    var i = 0;
    while (i < lines.length) {
      final line = lines[i];

      if (line.type == _DiffLineType.command) {
        final start = i;
        while (i < lines.length && lines[i].type == _DiffLineType.command) {
          i++;
        }
        rows.add(_buildTerminalBlock(lines.sublist(start, i)));
        continue;
      }

      // 从 hunk 头里尽量恢复起始行号：@@ path 10..10 @@
      if (line.text.startsWith('@@')) {
        final m = RegExp(r'(-?\d+)\s*\.\.\s*(-?\d+)').firstMatch(line.text);
        if (m != null) {
          oldLine = int.tryParse(m.group(1) ?? '') ?? oldLine;
          newLine = int.tryParse(m.group(2) ?? '') ?? newLine;
        }
      }
      rows.add(_buildDiffLine(
        line,
        oldLine: oldLine,
        newLine: newLine,
      ));
      switch (line.type) {
        case _DiffLineType.add:
          newLine++;
        case _DiffLineType.remove:
          oldLine++;
        case _DiffLineType.context:
          oldLine++;
          newLine++;
        case _DiffLineType.command:
          break;
      }
      i++;
    }
    return rows;
  }

  Widget _buildTerminalBlock(List<_DiffLine> commands) {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 2, horizontal: 2),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF0A1220), Color(0xFF101D30)],
        ),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFF1F3A5F)),
        boxShadow: const [
          BoxShadow(
            color: Color(0x33000000),
            blurRadius: 8,
            offset: Offset(0, 3),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 7, 10, 5),
            child: Row(
              children: [
                for (final color in const [
                  Color(0xFFFF5F56),
                  Color(0xFFFFBD2E),
                  Color(0xFF27C93F),
                ])
                  Padding(
                    padding: const EdgeInsets.only(right: 4),
                    child: Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: color,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
                const SizedBox(width: 8),
                const Icon(
                  Icons.terminal_rounded,
                  size: 13,
                  color: Color(0xFF79B8FF),
                ),
                const SizedBox(width: 6),
                const Text(
                  'SHELL',
                  style: TextStyle(
                    fontSize: 9,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1,
                    color: Color(0xFF8B949E),
                  ),
                ),
                const Spacer(),
                const Text(
                  'bash',
                  style: TextStyle(
                    fontSize: 9,
                    fontFamily: kMonoFamily,
                    fontFamilyFallback: kMonoFallback,
                    color: Color(0xFF6E7681),
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1, color: Color(0xFF1F3A5F)),
          for (final cmd in commands)
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 3, 10, 3),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '❯',
                    style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w800,
                      color: Color(0xFF7EE787),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: SelectableText.rich(
                      TextSpan(children: _highlightShell(cmd.text)),
                      style: const TextStyle(
                        fontSize: 11.5,
                        height: 1.45,
                        fontFamily: kMonoFamily,
                        fontFamilyFallback: kMonoFallback,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 5),
        ],
      ),
    );
  }

static const Set<String> _shellCommands = {
    'cd', 'rm', 'cp', 'mv', 'mkdir', 'touch', 'chmod', 'chown', 'cat', 'echo',
    'printf', 'sed', 'awk', 'grep', 'ls', 'pwd', 'find', 'head', 'tail', 'tar',
    'unzip', 'zip', 'curl', 'wget', 'git', 'python', 'python3', 'node', 'bash',
    'sh', 'source', 'export', 'env', 'sudo', 'apt', 'apt-get', 'yum', 'pnpm',
    'npm', 'yarn', 'docker', 'ps', 'kill', 'pkill', 'pgrep', 'systemctl',
    'which', 'whereis', 'date', 'sleep', 'timeout', 'tee', 'tr', 'sort',
    'uniq', 'wc', 'xargs', 'jq', 'nohup',
  };

  static List<TextSpan> _highlightShell(String text) {
    final spans = <TextSpan>[];
    final whitespace = RegExp(r'\s+');
    final patterns = <(RegExp, Color)>[
      (RegExp(r'#[^\n]*'), const Color(0xFF8B949E)),
      (RegExp(r"'[^'\\\n]*'"), const Color(0xFFDBAB79)),
      (RegExp(r'"(?:[^"\\\n]|\\.)*"'), const Color(0xFFDBAB79)),
      (RegExp(r'\$\{[^}]*\}'), const Color(0xFF79B8FF)),
      (RegExp(r'\$[A-Za-z_][A-Za-z0-9_]*'), const Color(0xFF79B8FF)),
      (RegExp(r'--?[A-Za-z0-9][A-Za-z0-9_-]*'), const Color(0xFFF97583)),
      (RegExp(r'&&|\|\||>>|<<|>|<|;|\(|\)|\|'), const Color(0xFFFFA657)),
      (RegExp(r'\b\d+\b'), const Color(0xFFFFA657)),
    ];
    var cursor = 0;
    while (cursor < text.length) {
      final ws = whitespace.matchAsPrefix(text, cursor);
      if (ws != null) {
        spans.add(TextSpan(text: ws.group(0)));
        cursor = ws.end;
        continue;
      }
      var matched = false;
      for (final (re, color) in patterns) {
        final m = re.matchAsPrefix(text, cursor);
        if (m != null) {
          spans.add(TextSpan(text: m.group(0), style: TextStyle(color: color)));
          cursor = m.end;
          matched = true;
          break;
        }
      }
      if (matched) continue;

      final word = RegExp(r'[A-Za-z_][A-Za-z0-9_./-]*')
          .matchAsPrefix(text, cursor);
      if (word != null) {
        final prev = cursor == 0 ? ' ' : text[cursor - 1];
        final isCmd = [' ', '\t', '|', '&', ';', '(', '\n'].contains(prev) &&
            _shellCommands.contains(word.group(0));
        spans.add(TextSpan(
          text: word.group(0),
          style: TextStyle(
            color: isCmd ? const Color(0xFF79B8FF) : const Color(0xFFE6EDF3),
            fontWeight: isCmd ? FontWeight.w700 : FontWeight.w400,
          ),
        ));
        cursor = word.end;
        continue;
      }

      final ch = text[cursor];
      spans.add(TextSpan(
        text: ch,
        style: const TextStyle(color: Color(0xFFE6EDF3)),
      ));
      cursor++;
    }
    return spans;
  }

  static List<TextSpan> _highlightOutput(String text) {
    final spans = <TextSpan>[];
    final patterns = <(RegExp, Color)>[
      (RegExp(r'https?://[^\s]+'), const Color(0xFF79B8FF)),
      (RegExp(r'\b\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}:\d{2}\b'), const Color(0xFF8B949E)),
      (RegExp(r'\b(?:[0-9]{1,3}\.){3}[0-9]{1,3}\b'), const Color(0xFF79B8FF)),
      (RegExp(r'"[^"\n]*"'), const Color(0xFFDBAB79)),
      (RegExp(r"'[^'\n]*'"), const Color(0xFFDBAB79)),
      (RegExp(r'\b\d+(?:\.\d+)?\b'), const Color(0xFFFFA657)),
      (RegExp(r'\b(?:true|false|null|undefined|NaN)\b'), const Color(0xFF79B8FF)),
      (RegExp(r'\b(?:ERROR|FAILED?|Exception|错误|失败)\b', caseSensitive: false), const Color(0xFFFF7B72)),
      (RegExp(r'\b(?:SUCCESS|OK|DONE|PASS|成功|完成)\b', caseSensitive: false), const Color(0xFF7EE787)),
      (RegExp(r'[{}[\]]'), const Color(0xFF79B8FF)),
    ];
    final quoted = RegExp(r'"[^"\n]*"');
    var cursor = 0;
    while (cursor < text.length) {
      var matched = false;
      for (final (re, color) in patterns) {
        final m = re.matchAsPrefix(text, cursor);
        if (m != null) {
          spans.add(TextSpan(
            text: m.group(0),
            style: TextStyle(color: color, fontWeight: FontWeight.w600),
          ));
          cursor = m.end;
          matched = true;
          break;
        }
      }
      if (matched) continue;
      final m = quoted.matchAsPrefix(text, cursor);
      if (m != null) {
        final after = text.substring(cursor + m.end).replaceFirst(RegExp(r'^\s*'), '');
        if (after.startsWith(':')) {
          spans.add(TextSpan(
            text: m.group(0),
            style: const TextStyle(color: Color(0xFF7EE787)),
          ));
          cursor = m.end;
          continue;
        }
      }
      spans.add(TextSpan(
        text: text[cursor],
        style: const TextStyle(color: Color(0xFFC9D1D9)),
      ));
      cursor++;
    }
    return spans;
  }

  Widget _buildDiffLine(
    _DiffLine line, {
    int oldLine = 1,
    int newLine = 1,
  }) {
    final isAdd = line.type == _DiffLineType.add;
    final isRemove = line.type == _DiffLineType.remove;
    final isCommand = line.type == _DiffLineType.command;
    final isHunk = line.text.startsWith('@@') ||
        line.text.startsWith('（') ||
        line.text.startsWith('文件末尾追加') ||
        line.text.startsWith('heredoc') ||
        line.text.startsWith('command') ||
        line.text.startsWith('命令');
    final bg = isAdd
        ? const Color(0xFF12261E)
        : isRemove
            ? const Color(0xFF2D1517)
            : isCommand
                ? const Color(0xFF0F1B2D)
                : isHunk
                    ? const Color(0xFF161B22)
                    : Colors.transparent;
    final accent = isAdd
        ? const Color(0xFF238636)
        : isRemove
            ? const Color(0xFFDA3633)
            : isCommand
                ? const Color(0xFF58A6FF)
                : isHunk
                    ? const Color(0xFF58A6FF)
                    : Colors.transparent;
    final textColor = isAdd
        ? const Color(0xFF7EE787)
        : isRemove
            ? const Color(0xFFFF7B72)
            : isCommand
                ? const Color(0xFF79B8FF)
                : isHunk
                    ? const Color(0xFF8B949E)
                    : Colors.white54;

    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: bg,
        border: Border(
          left: BorderSide(
            color: accent,
            width: isHunk ? 0 : 3,
          ),
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 20,
            child: Text(
              isCommand ? '\$' : line.prefix,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontWeight: FontWeight.w800,
                color: accent,
              ),
            ),
          ),
          const SizedBox(width: 2),
          Expanded(
            child: SelectableText.rich(
              TextSpan(
                children: isCommand
                    ? _highlightShell(line.text)
                    : toolName == 'shell_exec' &&
                            line.type == _DiffLineType.context
                        ? _highlightOutput(line.text)
                        : [TextSpan(text: line.text)],
              ),
              style: TextStyle(
                fontSize: 11.5,
                height: 1.45,
                fontFamily: kMonoFamily,
                fontFamilyFallback: kMonoFallback,
                color: textColor,
              ),
            ),
          ),
        ],
      ),
    );
  }

  List<_DiffLine> _diffLines() {
    final fromResult = _diffLinesFromResult();
    if (fromResult.isNotEmpty) return fromResult;
    final action = _action;
    final contentLines = _split(_content);
    final findLines = _split(_find);
    final rangeHint = _rangeHint();

    if (action != null && action.isNotEmpty) {
      switch (action) {
        case 'replace':
          return [
            if (findLines.isNotEmpty) ...[
              for (final line in findLines) _DiffLine.remove(line),
            ] else if (rangeHint.isNotEmpty)
              _DiffLine.remove(rangeHint),
            if (contentLines.isNotEmpty)
              for (final line in contentLines) _DiffLine.add(line)
            else
              _DiffLine.add('（新内容为空 / 未提供）'),
          ];
        case 'delete':
          return [
            if (findLines.isNotEmpty)
              for (final line in findLines) _DiffLine.remove(line)
            else if (rangeHint.isNotEmpty)
              _DiffLine.remove(rangeHint)
            else
              _DiffLine.remove('(删除内容为空)'),
          ];
        case 'insert':
          return [
            if (rangeHint.isNotEmpty)
              _DiffLine.context('$rangeHint 前插入'),
            if (contentLines.isNotEmpty)
              for (final line in contentLines) _DiffLine.add(line)
            else
              _DiffLine.add('（插入内容为空 / 未提供）'),
          ];
        case 'overwrite':
          return [
            if (rangeHint.isNotEmpty) _DiffLine.remove(rangeHint),
            if (contentLines.isNotEmpty)
              for (final line in contentLines) _DiffLine.add(line)
            else
              _DiffLine.add('（新内容为空 / 未提供）'),
          ];
        case 'insert_before':
          return [
            if (contentLines.isNotEmpty)
              for (final line in contentLines) _DiffLine.add(line),
            if (findLines.isNotEmpty)
              for (final line in findLines) _DiffLine.context(line),
          ];
        case 'insert_after':
          return [
            if (findLines.isNotEmpty)
              for (final line in findLines) _DiffLine.context(line),
            if (contentLines.isNotEmpty)
              for (final line in contentLines) _DiffLine.add(line),
          ];
      }
    }

    if (_append) {
      return [
        if (contentLines.isNotEmpty) ...[
          _DiffLine.context('文件末尾追加：'),
          for (final line in contentLines) _DiffLine.add(line),
        ],
      ];
    }

    // shell_exec / shell_script 没有结构化 diff 时，至少把命令/输出亮出来，
    // 不要再出现“没有可展示的文件内容”的白卡。
    if (toolName == 'shell_exec' || toolName == 'shell_script') {
      final shell = _shellFallbackLines();
      if (shell.isNotEmpty) return shell;
    }

    // 新建/整体覆盖：因为参数里没有旧内容，所以整段按“新增行”展示，
    // 用户至少能一眼看出这是这次写进去的内容。
    if (contentLines.isNotEmpty) {
      return [
        _DiffLine.context('（全新写入 / 覆盖写入）'),
        for (final line in contentLines) _DiffLine.add(line),
      ];
    }
    return [];
  }

  List<_DiffLine> _diffLinesFromResult() {
    final raw = result;
    if (raw == null || raw.isEmpty) return const [];
    final match = _diffFence.firstMatch(raw);
    if (match == null) return const [];
    final lines = match.group(1)?.split('\n') ?? const [];
    return [
      for (final line in lines)
        if (line.startsWith('+ '))
          _DiffLine.add(line.substring(2))
        else if (line.startsWith('- '))
          _DiffLine.remove(line.substring(2))
        else if (line.startsWith('+'))
          _DiffLine.add(line.substring(1))
        else if (line.startsWith('-'))
          _DiffLine.remove(line.substring(1))
        else if (line.startsWith('@@'))
          _DiffLine.context(line)
        else
          _DiffLine.context(line),
    ];
  }

  List<_DiffLine> _shellFallbackLines() {
    if (toolName == 'shell_script') {
      final code = args['code']?.toString() ?? '';
      if (code.trim().isNotEmpty) {
        return [
          _DiffLine.context('（脚本源码）'),
          for (final line in _split(code)) _DiffLine.add(line),
        ];
      }
      final out = result?.trim() ?? '';
      if (out.isNotEmpty) {
        return [
          _DiffLine.context('（命令输出）'),
          for (final line in _split(out)) _DiffLine.context(line),
        ];
      }
      return const [];
    }

    final cmd = args['command']?.toString() ?? '';
    // 尽量把 heredoc 写入的正文抽出来，直接显示成新增绿行。
    final heredoc = RegExp(
      r'''<<-?\s*['"]?([A-Za-z_][A-Za-z0-9_]*)['"]?\s*
?
([\s\S]*?)
?
\s*\s*$''',
    ).firstMatch(cmd);
    if (heredoc != null) {
      final body = heredoc.group(2) ?? '';
      if (body.trim().isNotEmpty) {
        return [
          _DiffLine.context('（heredoc 写入内容）'),
          for (final line in _split(body)) _DiffLine.add(line),
        ];
      }
    }

    final out = result?.trim() ?? '';
    final lines = <_DiffLine>[
      if (cmd.trim().isNotEmpty) ...[
        _DiffLine.context('（命令）'),
        for (final line in _split(cmd)) _DiffLine.command(line),
      ],
      if (out.isNotEmpty) ...[
        if (cmd.trim().isNotEmpty) _DiffLine.context('（命令输出）'),
        for (final line in _split(out)) _DiffLine.context(line),
      ],
    ];
    return lines;
  }

  String _rangeHint() {
    if (_start == null && _end == null) return '';
    return '范围 ${_start ?? '?'}~${_end ?? '?'}（原内容未在参数中给出）';
  }

  static List<String> _split(String text) {
    if (text.isEmpty) return const [];
    final normalized = text
        .replaceAll(r'\r\n', '\n')
        .replaceAll(r'\n', '\n')
        .replaceAll(r'\r', '\n');
    return const LineSplitter().convert(normalized);
  }
}

enum _DiffLineType { add, remove, context, command }

class _DiffLine {
  const _DiffLine(this.type, this.text, this.prefix);

  final _DiffLineType type;
  final String text;
  final String prefix;

  factory _DiffLine.add(String text) => _DiffLine(_DiffLineType.add, text, '+');
  factory _DiffLine.remove(String text) =>
      _DiffLine(_DiffLineType.remove, text, '-');
  factory _DiffLine.context(String text) =>
      _DiffLine(_DiffLineType.context, text, ' ');
  factory _DiffLine.command(String text) =>
      _DiffLine(_DiffLineType.command, text, '>');
}