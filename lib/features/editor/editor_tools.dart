import 'dart:convert';

import '../ai/agent/external_tool.dart';
import '../../shared/editor_bus.dart';

/// 把"用户眼前的代码编辑器"包成 AI 工具。
///
/// 和 script_write / shell_write 那类工具的区别：这些工具不写磁盘，
/// 而是直接改**用户正在看的那个编辑框**——一段一段地打字、一段一段地删，
/// 用户全程看得见改动过程，改完还能自己撤销、再点保存。
///
/// 最大的坑是"改错编辑器"：同时可能开着青龙脚本编辑器、浏览器抓包脚本编辑器、
/// 文件管理器里的文件编辑器、面板配置编辑器。所以每个工具都有 target 参数，
/// 默认 active，一旦点名的编辑器没开就直接报错，绝不退化成"随便找一个改"。
class EditorTools {
  EditorTools._();

  static const _origin = '代码编辑器';

  static Map<String, dynamic> _obj(
    List<String> required,
    Map<String, dynamic> props,
  ) =>
      {'type': 'object', 'properties': props, 'required': required};

  static const _targetProp = {
    'type': 'string',
    'description': '改哪个编辑器：active=用户当前活跃的那个（默认）、'
        'qinglong=青龙脚本编辑器、browser=浏览器抓包脚本编辑器、'
        'file=文件管理器里的文件、config=面板配置文件编辑器、'
        '或 #id 精确点名（id 从 editor_list 拿）。'
        '点名的编辑器没打开就会直接报错，不会改到别的编辑器上。',
  };

  /// 提示词里的静态说明块（不含"当前开着谁"，所以能吃满提示词缓存）。
  ///
  /// 用户没开编辑器时只留一句话：editor_* 工具此时根本没挂上去（见
  /// chat_provider._buildExternalTools），再挂着一大段"改代码要用 editor_*"
  /// 只会引导模型去调不存在的工具。
  static String promptBlock() {
    if (!EditorBus.instance.hasEditor) {
      return '## 可视化代码编辑（editor_*）\n'
          '用户现在**没有打开任何代码编辑器**，所以这组工具没挂上来，别去调。'
          '改代码走 script_write / shell_write_file / browser_hook；'
          '用户打开编辑器之后这组工具会自动出现。';
    }
    return [
      '## 可视化代码编辑（editor_*）',
      '用户打开代码编辑器 + 悬浮窗提问时，改代码要用 editor_* 工具，'
          '**不要**把整段代码贴回聊天让用户自己复制，也不要改用 script_write / shell_write 覆盖文件。'
          'editor_* 会在用户眼前一段段打字/删除，改完由用户自己决定保不保存。',
      '- 有四套编辑器：青龙脚本编辑器（qinglong，可运行、有执行日志）、'
          '浏览器抓包脚本编辑器（browser）、文件管理器里的文件编辑器（file）、'
          '面板配置文件编辑器（config，改 config.sh / notify.js 这类）。',
      '- 铁律：先 editor_list 看清用户开着哪个、活跃的是哪个，再动手。'
          '绝不能把青龙脚本的代码写进浏览器抓包脚本，反之亦然。不确定就问用户。',
      '- 改法优先级：小改用 editor_patch（给出唯一的 old_text），'
          '插入用 editor_insert，删除用 editor_delete，只有整篇重写才用 editor_write。',
      '- editor_patch 的 old_text 必须和当前内容**逐字一致**（含缩进和空格），'
          '所以改之前先 editor_read 读一遍。',
      '- old_text 报"匹配到多处"时别在原文上死磕：改传 line（+ end_line）按行号替换，'
          '行号唯一，一次就成。像 `// line 20` 这种同时又是 `// line 200` 前缀的内容，'
          '本来就只能按行号改。',
      '- editor_save 才会真正落盘/落库；editor_run / editor_log 只有青龙脚本编辑器有。',
      '- 没有打开编辑器时 editor_* 会报错，那时候该走 script_* / shell_* / browser_hook。',
    ].join('\n');
  }

  /// 提示词里的动态一段：现在开着哪些编辑器。排在提示词末尾，少破坏缓存。
  static String promptState() {
    final bus = EditorBus.instance;
    if (!bus.hasEditor) return '';
    return '- 用户当前打开的代码编辑器（▶ = 活跃，editor_* 默认改它）：\n'
        '${bus.listText().split('\n').map((l) => '  $l').join('\n')}';
  }

  static List<ExternalTool> build() {
    final bus = EditorBus.instance;

    Future<String> guard(Future<String> Function() body) async {
      try {
        return await body();
      } on EditorBusException catch (e) {
        return e.message;
      } catch (e) {
        return '编辑器操作失败：$e';
      }
    }

    return [
      ExternalTool(
        name: 'editor_list',
        description: '列出用户当前打开的代码编辑器'
            '（青龙脚本 / 浏览器抓包脚本 / 文件 / 面板配置），'
            '以及哪个是活跃的。改代码之前先调它，确认自己要动的是哪一个。',
        parameters: _obj([], const {}),
        origin: _origin,
        invoke: (args) async {
          if (!bus.hasEditor) {
            return '用户现在没有打开任何代码编辑器。'
                '要改文件可以用 shell_write / script_write，'
                '要改抓包脚本可以用 browser_hook。';
          }
          return '当前打开的编辑器（▶ = 活跃，editor_* 默认改它）：\n${bus.listText()}';
        },
      ),
      ExternalTool(
        name: 'editor_read',
        description: '读取某个编辑器里当前的内容（含用户还没保存的修改）。'
            '改代码前必须先读，否则 editor_patch 的 old_text 对不上。',
        parameters: _obj([], {
          'target': _targetProp,
          'with_line_numbers': {
            'type': 'boolean',
            'description': '是否带行号返回，默认 true（方便按行插入/删除）',
          },
          'from_line': {'type': 'integer', 'description': '只读某段：起始行（1 开始）'},
          'to_line': {'type': 'integer', 'description': '只读某段：结束行'},
          'max_chars': {'type': 'integer', 'description': '最多返回多少字符，默认 8000'},
        }),
        origin: _origin,
        invoke: (args) => guard(() async {
          final handle = bus.resolve(args['target']?.toString());
          final numbered = args['with_line_numbers'] != false;
          final lines = handle.text.split('\n');
          final from = ((args['from_line'] as num?)?.toInt() ?? 1)
              .clamp(1, lines.isEmpty ? 1 : lines.length);
          final to = ((args['to_line'] as num?)?.toInt() ?? lines.length)
              .clamp(from, lines.isEmpty ? 1 : lines.length);
          final slice = lines.sublist(from - 1, to);
          final body = numbered
              ? [
                  for (var i = 0; i < slice.length; i++)
                    '${from + i}\t${slice[i]}',
                ].join('\n')
              : slice.join('\n');
          final max = (args['max_chars'] as num?)?.toInt() ?? 8000;
          final clipped = body.length > max
              ? '${body.substring(0, max)}\n…（已截断，共 ${body.length} 字符）'
              : body;
          return [
            '${handle.kind.label} #${handle.id}「${handle.title}」'
                '（${handle.path}，共 ${lines.length} 行'
                '${handle.readOnly ? '，只读' : ''}）',
            '',
            clipped,
          ].join('\n');
        }),
      ),
      ExternalTool(
        name: 'editor_patch',
        description: '把编辑器里的一段代码替换成新代码——最常用的改法。'
            '两种定位方式选一个：① old_text（必须逐字一致且唯一，不唯一就多带几行上下文，'
            '或传 all=true）；② line/end_line 按行号替换。'
            '行内容互为前缀时（`// line 20` 也是 `// line 200` 的前缀）用行号更稳。'
            '用户会看到这段被逐字删掉、新代码被逐字打出来。',
        parameters: _obj([
          'new_text'
        ], {
          'target': _targetProp,
          'old_text': {'type': 'string', 'description': '要被替换掉的原文（含缩进）'},
          'new_text': {'type': 'string', 'description': '替换后的新代码，可为空串表示删掉'},
          'all': {'type': 'boolean', 'description': '匹配到多处时是否全部替换，默认 false'},
          'line': {'type': 'integer', 'description': '按行号替换时的起始行（从 1 开始）'},
          'end_line': {'type': 'integer', 'description': '结束行，默认与 line 相同'},
        }),
        isWrite: true,
        origin: _origin,
        invoke: (args) => guard(() async {
          final handle = bus.resolve(args['target']?.toString());
          final line = (args['line'] as num?)?.toInt();
          if (line != null && line > 0) {
            return bus.replaceLines(
              handle,
              from: line,
              to: (args['end_line'] as num?)?.toInt() ?? line,
              text: args['new_text']?.toString() ?? '',
            );
          }
          final oldText = args['old_text']?.toString() ?? '';
          if (oldText.isEmpty) {
            return 'old_text 和 line 至少给一个：按原文改传 old_text，按行号改传 line。';
          }
          return bus.patch(
            handle,
            oldText: oldText,
            newText: args['new_text']?.toString() ?? '',
            all: args['all'] == true,
          );
        }),
      ),
      ExternalTool(
        name: 'editor_insert',
        description: '在指定行处插入整段代码（不动其它内容）。'
            '比 editor_write 安全得多：加一个函数、加几行日志用这个。',
        parameters: _obj([
          'line',
          'text'
        ], {
          'target': _targetProp,
          'line': {
            'type': 'integer',
            'description': '插在第几行的位置（1 开始）。0 表示插到文件最前面。',
          },
          'text': {'type': 'string', 'description': '要插入的代码，不用自己补末尾换行'},
          'before': {
            'type': 'boolean',
            'description': 'true = 插在该行之前，默认 false（插在该行之后）',
          },
        }),
        isWrite: true,
        origin: _origin,
        invoke: (args) => guard(() async {
          final handle = bus.resolve(args['target']?.toString());
          return bus.insertAtLine(
            handle,
            line: (args['line'] as num?)?.toInt() ?? 0,
            text: args['text']?.toString() ?? '',
            after: args['before'] != true,
          );
        }),
      ),
      ExternalTool(
        name: 'editor_delete',
        description: '删掉编辑器里的一段：按行区间（from_line/to_line）或按原文（text）。',
        parameters: _obj([], {
          'target': _targetProp,
          'from_line': {'type': 'integer', 'description': '起始行（1 开始）'},
          'to_line': {'type': 'integer', 'description': '结束行（含）。不填等于只删一行'},
          'text': {'type': 'string', 'description': '要删掉的原文（和行区间二选一）'},
        }),
        isWrite: true,
        danger: true,
        origin: _origin,
        invoke: (args) => guard(() async {
          final handle = bus.resolve(args['target']?.toString());
          final snippet = args['text']?.toString();
          if (snippet != null && snippet.isNotEmpty) {
            return bus.deleteText(handle, snippet: snippet);
          }
          final from = (args['from_line'] as num?)?.toInt();
          if (from == null) {
            return '要么给 text（要删的原文），要么给 from_line/to_line（行区间）。';
          }
          return bus.deleteLines(
            handle,
            from: from,
            to: (args['to_line'] as num?)?.toInt() ?? from,
          );
        }),
      ),
      ExternalTool(
        name: 'editor_write',
        description: '整篇重写编辑器内容（旧内容会被逐段删掉，再逐段打出新内容）。'
            '只在新建脚本或确实要全量替换时用；改几行请用 editor_patch。',
        parameters: _obj([
          'content'
        ], {
          'target': _targetProp,
          'content': {'type': 'string', 'description': '新的完整内容'},
        }),
        isWrite: true,
        danger: true,
        origin: _origin,
        invoke: (args) => guard(() async {
          final handle = bus.resolve(args['target']?.toString());
          return bus.replaceAll(handle, args['content']?.toString() ?? '');
        }),
      ),
      ExternalTool(
        name: 'editor_save',
        description: '保存编辑器里的内容（青龙脚本写回面板、文件写回磁盘、'
            '抓包脚本写回脚本表、面板配置写回青龙配置）。'
            '改完先问用户要不要保存，用户点了保存或明确说保存再调。',
        parameters: _obj([], {'target': _targetProp}),
        isWrite: true,
        danger: true,
        origin: _origin,
        invoke: (args) => guard(() async {
          final handle = bus.resolve(args['target']?.toString());
          final save = handle.save;
          if (save == null) {
            return '${handle.kind.label}「${handle.title}」不支持从这里保存，'
                '让用户点编辑器上的保存按钮。';
          }
          return save();
        }),
      ),
      ExternalTool(
        name: 'editor_run',
        description: '运行编辑器里的脚本（只有青龙脚本编辑器支持，跑的是编辑器里的当前内容，'
            '含未保存修改）。跑完用 editor_log 看输出。',
        parameters: _obj([], {'target': _targetProp}),
        isWrite: true,
        danger: true,
        origin: _origin,
        invoke: (args) => guard(() async {
          final handle = bus.resolve(args['target']?.toString());
          final run = handle.run;
          if (run == null) {
            return '${handle.kind.label}「${handle.title}」不能在这里运行'
                '（只有青龙脚本编辑器可以）。';
          }
          return run();
        }),
      ),
      ExternalTool(
        name: 'editor_log',
        description: '读编辑器里的执行日志（青龙脚本编辑器的运行输出）。',
        parameters: _obj([], {
          'target': _targetProp,
          'max_chars': {'type': 'integer', 'description': '默认 4000'},
        }),
        origin: _origin,
        invoke: (args) => guard(() async {
          final handle = bus.resolve(args['target']?.toString());
          final readLog = handle.readLog;
          if (readLog == null) {
            return '${handle.kind.label}「${handle.title}」没有执行日志。';
          }
          final text = readLog();
          if (text.trim().isEmpty) return '还没有执行日志（先 editor_run）。';
          final max = (args['max_chars'] as num?)?.toInt() ?? 4000;
          if (text.length <= max) return text;
          return '…（前面省略）\n${text.substring(text.length - max)}';
        }),
      ),
      ExternalTool(
        name: 'editor_remove',
        description: '删掉编辑器正在编辑的这个脚本/文件本身（不是删内容）。不可逆，先跟用户确认。',
        parameters: _obj([], {'target': _targetProp}),
        isWrite: true,
        danger: true,
        origin: _origin,
        invoke: (args) => guard(() async {
          final handle = bus.resolve(args['target']?.toString());
          final remove = handle.remove;
          if (remove == null) {
            return '${handle.kind.label}「${handle.title}」不支持从这里删除。';
          }
          return remove();
        }),
      ),
      ExternalTool(
        name: 'editor_focus',
        description: '把某个编辑器设成活跃目标（用户同时开了多个，需要切换时用）。',
        parameters: _obj(['target'], {'target': _targetProp}),
        origin: _origin,
        invoke: (args) => guard(() async {
          final handle = bus.resolve(args['target']?.toString());
          bus.touch(handle.id);
          return '之后 editor_* 默认改 ${handle.kind.label} #${handle.id}'
              '「${handle.title}」。';
        }),
      ),
    ];
  }

  /// 调试用：把清单序列化。
  static String debugJson() => jsonEncode({
        'active': EditorBus.instance.active?.id,
        'handles': [
          for (final h in EditorBus.instance.handles)
            {
              'id': h.id,
              'kind': h.kind.code,
              'title': h.title,
              'path': h.path,
              'lines': h.lineCount,
            },
        ],
      });
}
