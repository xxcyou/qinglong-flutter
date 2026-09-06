import 'package:flutter/material.dart';

/// 命令行语法高亮。
///
/// 为什么不直接用 highlight 包的 bash 模式：那是给"整段脚本"用的，
/// 逐字输入时半个引号、半个变量名都会让它把后面全部染成字符串色，
/// 输入框里看着就是一片红。这里手写一个宽容的分词器：
/// 只认得出来的东西才上色，认不出来就保持默认色，永远不会把整行染坏。
class ShellHighlighter {
  const ShellHighlighter({
    required this.command,
    required this.builtin,
    required this.option,
    required this.string,
    required this.variable,
    required this.number,
    required this.operatorColor,
    required this.comment,
    required this.path,
    required this.base,
  });

  final Color command;
  final Color builtin;
  final Color option;
  final Color string;
  final Color variable;
  final Color number;
  final Color operatorColor;
  final Color comment;
  final Color path;
  final Color base;

  /// 跟着终端配色走，两边看起来是一套。
  factory ShellHighlighter.fromScheme(ColorScheme scheme, {bool dark = true}) {
    return ShellHighlighter(
      command: dark ? const Color(0xFF7AA2F7) : const Color(0xFF1D4ED8),
      builtin: dark ? const Color(0xFFBB9AF7) : const Color(0xFF7C3AED),
      option: dark ? const Color(0xFFE0AF68) : const Color(0xFFB45309),
      string: dark ? const Color(0xFF9ECE6A) : const Color(0xFF15803D),
      variable: dark ? const Color(0xFF7DCFFF) : const Color(0xFF0E7490),
      number: dark ? const Color(0xFFFF9E64) : const Color(0xFFC2410C),
      operatorColor: dark ? const Color(0xFFF7768E) : const Color(0xFFBE123C),
      comment: dark ? const Color(0xFF565F89) : const Color(0xFF94A3B8),
      path: dark ? const Color(0xFF89DDFF) : const Color(0xFF0369A1),
      base: scheme.onSurface,
    );
  }

  /// shell 内建 + 控制结构：这些不是外部命令，单独一个颜色。
  static const _builtins = {
    'cd',
    'export',
    'source',
    'alias',
    'unalias',
    'set',
    'unset',
    'echo',
    'exit',
    'return',
    'if',
    'then',
    'else',
    'elif',
    'fi',
    'for',
    'while',
    'until',
    'do',
    'done',
    'case',
    'esac',
    'in',
    'function',
    'local',
    'read',
    'eval',
    'exec',
    'trap',
    'shift',
    'test',
    'true',
    'false',
    'pushd',
    'popd',
    'dirs',
    'jobs',
    'fg',
    'bg',
    'wait',
    'kill',
    'type',
    'command',
    'builtin',
    'declare',
    'readonly',
    'printf',
    'let',
    'time',
  };

  /// 危险命令：单独染成错误色，手抖打了 rm -rf 至少有个视觉警告。
  static const _dangerous = {'rm', 'dd', 'mkfs', 'shutdown', 'reboot', 'halt'};

  /// 把一行命令切成带色的 TextSpan。
  List<TextSpan> spans(String text, TextStyle style) {
    if (text.isEmpty) return const [];
    final out = <TextSpan>[];
    final buffer = StringBuffer();
    // 行首、以及每个 | && || ; 之后的第一个词是"命令"，其余是参数。
    var expectCommand = true;
    var i = 0;

    void flush([Color? color]) {
      if (buffer.isEmpty) return;
      out.add(
        TextSpan(
          text: buffer.toString(),
          style: style.copyWith(color: color ?? base),
        ),
      );
      buffer.clear();
    }

    while (i < text.length) {
      final ch = text[i];

      // 注释：# 之后到行尾（但 $# 之类不算）。
      if (ch == '#' && (i == 0 || _isSpace(text[i - 1]))) {
        flush();
        out.add(
          TextSpan(
            text: text.substring(i),
            style: style.copyWith(color: comment),
          ),
        );
        return out;
      }

      // 引号串：允许不闭合（正在输入），到行尾为止。
      if (ch == '"' || ch == "'") {
        flush();
        final quote = ch;
        var j = i + 1;
        while (j < text.length) {
          if (text[j] == r'\' && quote == '"' && j + 1 < text.length) {
            j += 2;
            continue;
          }
          if (text[j] == quote) {
            j++;
            break;
          }
          j++;
        }
        out.add(
          TextSpan(
            text: text.substring(i, j),
            style: style.copyWith(color: string),
          ),
        );
        i = j;
        expectCommand = false;
        continue;
      }

      // 变量：$VAR / ${VAR} / $1 / $? / $(...)
      if (ch == r'$') {
        flush();
        var j = i + 1;
        if (j < text.length && text[j] == '{') {
          while (j < text.length && text[j] != '}') {
            j++;
          }
          if (j < text.length) j++;
        } else if (j < text.length && text[j] == '(') {
          // 命令替换：括号里的东西按普通命令递归上色太重，整体染变量色即可。
          var depth = 0;
          while (j < text.length) {
            if (text[j] == '(') depth++;
            if (text[j] == ')') {
              depth--;
              j++;
              if (depth == 0) break;
              continue;
            }
            j++;
          }
        } else {
          while (j < text.length && _isWordChar(text[j])) {
            j++;
          }
          if (j == i + 1 && j < text.length) j++; // $? $# $$ $!
        }
        out.add(
          TextSpan(
            text: text.substring(i, j),
            style: style.copyWith(color: variable),
          ),
        );
        i = j;
        continue;
      }

      // 操作符 / 重定向：这些之后又要重新期待一个命令。
      if ('|&;><()'.contains(ch)) {
        flush();
        var j = i;
        while (j < text.length && '|&;><'.contains(text[j])) {
          j++;
        }
        if (j == i) j = i + 1; // 括号
        out.add(
          TextSpan(
            text: text.substring(i, j),
            style: style.copyWith(
              color: operatorColor,
              fontWeight: FontWeight.w600,
            ),
          ),
        );
        i = j;
        // ) 之后不是新命令，其它符号（| && ; 等）之后是。
        expectCommand = !text.substring(i - 1, i).contains(')');
        continue;
      }

      if (_isSpace(ch)) {
        flush();
        buffer.write(ch);
        flush();
        i++;
        continue;
      }

      // 普通词：一口气吃到分隔符。
      var j = i;
      while (j < text.length && !_isBreak(text[j])) {
        j++;
      }
      final word = text.substring(i, j);
      buffer.write(word);
      if (expectCommand) {
        if (_dangerous.contains(word)) {
          flush(operatorColor);
        } else if (_builtins.contains(word)) {
          flush(builtin);
        } else if (word.contains('=')) {
          // VAR=value 形式的前置赋值，后面还可能跟命令。
          flush(variable);
          i = j;
          continue;
        } else {
          flush(command);
        }
        // 控制结构（if/then/for…）之后紧跟的还是命令。
        expectCommand = _builtins.contains(word) &&
            const {
              'if',
              'then',
              'else',
              'elif',
              'do',
              'while',
              'until',
              'time',
              'command',
              'builtin',
              'exec',
              'eval',
              'source',
              'sudo',
            }.contains(word);
      } else if (word.startsWith('--') ||
          (word.startsWith('-') && word.length > 1)) {
        flush(option);
      } else if (word.startsWith('/') ||
          word.startsWith('./') ||
          word.startsWith('~/') ||
          word.startsWith('../')) {
        flush(path);
      } else if (_isNumber(word)) {
        flush(number);
      } else {
        flush();
      }
      i = j;
    }
    flush();
    return out;
  }

  static bool _isSpace(String c) => c == ' ' || c == '\t';

  static bool _isBreak(String c) => _isSpace(c) || '|&;><()\$"\'#'.contains(c);

  static bool _isWordChar(String c) {
    final code = c.codeUnitAt(0);
    return (code >= 48 && code <= 57) ||
        (code >= 65 && code <= 90) ||
        (code >= 97 && code <= 122) ||
        c == '_';
  }

  static bool _isNumber(String word) => double.tryParse(word) != null;
}

/// 带 shell 语法高亮的输入框控制器。
///
/// 走 `TextEditingController.buildTextSpan` 这条正路：高亮只影响绘制，
/// 不碰 value，所以光标、选区、输入法组词全都不受影响。
class ShellCommandController extends TextEditingController {
  ShellCommandController({super.text, this.enabled = true});

  /// 关掉就退回普通输入框（设置里可关）。
  bool enabled;

  ShellHighlighter? _highlighter;

  void updateHighlighter(ShellHighlighter value) => _highlighter = value;

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final highlighter = _highlighter;
    // 组词中（输入法拼音下划线）不重排 span，否则候选框会闪。
    final composing = value.composing;
    if (!enabled ||
        highlighter == null ||
        text.isEmpty ||
        (withComposing && composing.isValid && !composing.isCollapsed)) {
      return super.buildTextSpan(
        context: context,
        style: style,
        withComposing: withComposing,
      );
    }
    final base = style ?? const TextStyle();
    return TextSpan(style: base, children: highlighter.spans(text, base));
  }
}
