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
  });

  final String toolName;
  final Map<String, dynamic> args;

  String get _path => args['path']?.toString() ?? '未知路径';

  bool get _isBinary =>
      args['base64'] != null && args['base64'].toString().trim().isNotEmpty;

  String get _content => args['content']?.toString() ?? '';

  String? get _action => args['action']?.toString();

  String get _find => args['find']?.toString() ?? '';

  num? get _start => args['start'] is num ? args['start'] as num : null;

  num? get _end => args['end'] is num ? args['end'] as num : null;

  bool get _append => args['append'] == true;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final label = _label();

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(top: 6),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLowest.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: scheme.outlineVariant.withValues(alpha: 0.6),
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 7, 8, 5),
            child: Row(
              children: [
                Icon(
                  _isBinary
                      ? Icons.insert_drive_file_outlined
                      : Icons.difference_outlined,
                  size: 14,
                  color: scheme.primary,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '$_path  ·  $label',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                Icon(
                  _isBinary
                      ? Icons.data_object_rounded
                      : Icons.code_rounded,
                  size: 14,
                  color: scheme.onSurfaceVariant,
                ),
              ],
            ),
          ),
          Divider(height: 1, color: scheme.outlineVariant.withValues(alpha: 0.4)),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 240),
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
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
    return '写入';
  }

  Widget _buildBody(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (_isBinary) {
      final len = args['base64'].toString().length;
      return Text(
        'base64 内容共 $len 字符，不在此展开。需要时可点右侧详情查看原始参数。',
        style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
      );
    }
    if (toolName == 'shell_write_binary') {
      return Text(
        '二进制文件已写入，不展示内容。',
        style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
      );
    }

    final lines = _diffLines();
    if (lines.isEmpty) {
      return Text(
        '（没有可展示的文件内容）',
        style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
      );
    }

    final isPlainWrite = lines.every((l) => l.type == _DiffLineType.plain);
    if (isPlainWrite) {
      final text = lines.map((l) => l.text).join('\n');
      return SelectableText(
        text,
        style: TextStyle(
          fontSize: 11.5,
          height: 1.45,
          fontFamily: kMonoFamily,
          fontFamilyFallback: kMonoFallback,
          color: scheme.onSurface,
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final line in lines)
          SelectableText.rich(
            TextSpan(
              children: [
                TextSpan(
                  text: '${line.prefix} ',
                  style: const TextStyle(
                    fontWeight: FontWeight.w800,
                    color: Colors.white70,
                  ),
                ),
                TextSpan(text: line.text),
              ],
            ),
            style: TextStyle(
              fontSize: 11.5,
              height: 1.45,
              fontFamily: kMonoFamily,
              fontFamilyFallback: kMonoFallback,
              color: line.type == _DiffLineType.add
                  ? const Color(0xFF7EE787)
                  : line.type == _DiffLineType.remove
                      ? const Color(0xFFFF7B72)
                      : scheme.onSurface,
            ),
          ),
      ],
    );
  }

  List<_DiffLine> _diffLines() {
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
              for (final line in contentLines) _DiffLine.add(line),
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
            for (final line in contentLines) _DiffLine.add(line),
          ];
        case 'overwrite':
          return [
            if (rangeHint.isNotEmpty) _DiffLine.remove(rangeHint),
            for (final line in contentLines) _DiffLine.add(line),
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

    // 新建/整体覆盖：直接展示完整代码片段，不是“纯新增”符号形式。
    if (contentLines.isNotEmpty) {
      return [
        for (final line in contentLines) _DiffLine.plain(line),
      ];
    }
    return [];
  }

  String _rangeHint() {
    if (_start == null && _end == null) return '';
    return '范围 ${_start ?? '?'}~${_end ?? '?'}（原内容未在参数中给出）';
  }

  static List<String> _split(String text) {
    if (text.isEmpty) return const [];
    return const LineSplitter().convert(text);
  }
}

enum _DiffLineType { add, remove, context, plain }

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
  factory _DiffLine.plain(String text) =>
      _DiffLine(_DiffLineType.plain, text, '');
}