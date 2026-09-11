import 'dart:convert';

import 'package:flutter_js/flutter_js.dart';

import '../../../core/llm/llm_client.dart';
import '../../../core/utils/logger.dart';
import '../../../core/local_shell/proot_bridge.dart';

/// 对外暴露的插件信息（不携带 JS 运行时，UI 只读展示用）。
class OutputPluginInfo {
  const OutputPluginInfo({
    required this.path,
    required this.name,
    required this.description,
  });

  final String path;
  final String name;
  final String description;
}

/// 一次插件 hook 调用的反馈记录。
class OutputPluginRunRecord {
  const OutputPluginRunRecord({
    required this.path,
    required this.name,
    required this.hook,
    required this.status,
    required this.detail,
    required this.at,
    required this.original,
    this.result,
  });

  /// hook 名：beforeSend / processResponse / process
  final String hook;

  /// ran=执行并返回结果；skipped=没定义该 hook；error=执行失败
  final String status;
  final String detail;
  final DateTime at;
  final String path;
  final String name;

  /// 传给该 hook 的原始内容（已按展示上限截断）。
  final String original;

  /// 该 hook 返回的结果；skipped/error 时为 null（点开看原始内容即可）。
  final String? result;
}

/// 解析结果：JS 插件源码和元信息。
class ParsedOutputPlugin {
  const ParsedOutputPlugin({
    required this.valid,
    required this.name,
    required this.description,
    required this.source,
  });

  final bool valid;
  final String name;
  final String description;
  final String source;
}

/// 内部已加载的插件实例：每个插件用独立 QuickJS 运行时，函数互不串味。
class _LoadedOutputPlugin {
  _LoadedOutputPlugin({
    required this.info,
    required this.runtime,
    required this.source,
    required this.hasProcessResponse,
  });

  final OutputPluginInfo info;
  final JavascriptRuntime runtime;
  final String source;

  /// 插件是否声明了 processResponse（哪怕执行失败也算“这一层归插件管”）。
  final bool hasProcessResponse;
}

/// 输出整理插件服务（支持多个插件按顺序链式执行）。
///
/// 插件是文件管理里用户自己新建的 `.js` 文件，必须带识别注释：
/// ```js
/// // @qinglong-plugin
/// // name: 输出整理
/// // description: 清理模型输出泄露的工具调用标记
/// function process(text) { ... }
/// ```
///
/// 支持 hook：
/// - `beforeSend(messages)`：提交前改写 messages
/// - `processResponse({content, reasoning, toolCalls})`：响应后同时改正文/思考/工具调用
/// - `process(text)` / `transform(text)`：文本清理，作为 processResponse 的兜底
class OutputPluginService {
  OutputPluginService._();

  static final OutputPluginService instance = OutputPluginService._();

  /// 单次运行最多保留的记录条数；超出后丢最早的，避免长任务把内存撑爆。
  static const maxRunRecords = 600;

  final List<_LoadedOutputPlugin> _plugins = [];
  final List<OutputPluginRunRecord> _runRecords = [];
  String? _lastError;

  bool get isLoaded => _plugins.isNotEmpty;
  List<OutputPluginInfo> get plugins => [for (final p in _plugins) p.info];
  List<String> get loadedPaths => [for (final p in _plugins) p.info.path];
  String get name => _plugins.map((p) => p.info.name).join('、');
  String get description => _plugins
      .map((p) => p.info.description)
      .where((d) => d.isNotEmpty)
      .join('；');
  String get loadedPath => _plugins.isEmpty ? '' : _plugins.first.info.path;

  /// 当前已加载插件里有没有人声明 processResponse。
  ///
  /// 有的话，内置 ToolMarkupRecovery 不再兜底，让插件真正负责捞回/清理；
  /// 这样插件坏了会直接暴露，而不是被内置兜底掩盖成“看起来生效了”。
  bool get hasResponseHook => _plugins.any((p) => p.hasProcessResponse);

  /// 最近一次的 hook 调用记录（点击聊天里的插件状态钮时展示）。
  List<OutputPluginRunRecord> get runRecords => List.unmodifiable(_runRecords);
  String? get lastError => _lastError;

  /// 开始一轮新运行前调用：清空上一轮的 hook 反馈。
  void beginRun() => _runRecords.clear();

  void _record(
    OutputPluginInfo info,
    String hook,
    String status,
    String detail, {
    required String original,
    String? result,
  }) {
    _runRecords.add(OutputPluginRunRecord(
      path: info.path,
      name: info.name,
      hook: hook,
      status: status,
      detail: detail,
      at: DateTime.now(),
      original: _clipSnapshot(original),
      result: result == null ? null : _clipSnapshot(result),
    ));
    if (_runRecords.length > maxRunRecords) {
      _runRecords.removeRange(0, _runRecords.length - maxRunRecords);
    }
  }

  static String _clipSnapshot(String text, {int max = 30000}) {
    if (text.length <= max) return text;
    return '${text.substring(0, max)}\n…（快照已截断，原始长度 ${text.length} 字符）';
  }

  /// 兼容旧单插件入口。
  Future<bool> load(String path) => loadAll([path]);

  /// 按给定顺序加载多个插件。某个插件坏了跳过并记错误，不拖垮后面的。
  Future<bool> loadAll(List<String> paths) async {
    _plugins.clear();
    _lastError = null;
    final errors = <String>[];

    for (final path in paths) {
      final trimmed = path.trim();
      if (trimmed.isEmpty) continue;
      try {
        // 插件可能建在 PRoot 的 /workspace（shell 作用域），也可能建在
        // App 自己的文件区（app 作用域）。文件选择器两个作用域都能进，
        // 所以这里两个都试：先 shell，再 app，避免“路径能选中但加载不到”。
        final bridge = ProotBridge();
        String raw;
        try {
          raw = await bridge.readFile(path: trimmed, scope: 'shell');
        } catch (shellError) {
          try {
            raw = await bridge.readFile(path: trimmed, scope: 'app');
          } catch (appError) {
            errors.add('$trimmed：读取失败（shell: $shellError；app: $appError）');
            continue;
          }
        }
        final parsed = OutputPluginService.parsePlugin(raw, trimmed);
        if (!parsed.valid) {
          errors.add('$trimmed：不是有效的 QingLong 插件文件'
              '（缺 @qinglong-plugin 或 process/transform/processResponse/beforeSend 函数）');
          continue;
        }
        final runtime = getJavascriptRuntime(
          xhr: false,
          forceJavascriptCoreOnAndroid: false,
        );
        final wrapped = '(function() {\n'
            '${parsed.source}\n'
            '  if (typeof process === "function") globalThis.process = process;\n'
            '  if (typeof transform === "function") globalThis.transform = transform;\n'
            '  if (typeof processResponse === "function") globalThis.processResponse = processResponse;\n'
            '  if (typeof beforeSend === "function") globalThis.beforeSend = beforeSend;\n'
            '})();';
        final result = runtime.evaluate(wrapped);
        if (result.isError) {
          errors.add('$trimmed：JS 执行失败 ${result.stringResult}');
          continue;
        }
        final probe = runtime.evaluate('typeof processResponse === "function"');
        final hasProcessResponse =
            !probe.isError && probe.stringResult == 'true';
        _plugins.add(
          _LoadedOutputPlugin(
            info: OutputPluginInfo(
              path: trimmed,
              name: parsed.name,
              description: parsed.description,
            ),
            runtime: runtime,
            source: parsed.source,
            hasProcessResponse: hasProcessResponse,
          ),
        );
        Logger.d(
            'output_plugin',
            'loaded ${parsed.name.isEmpty ? trimmed : parsed.name} '
                'hasProcessResponse=$hasProcessResponse');
      } catch (e) {
        errors.add('$trimmed：$e');
      }
    }

    if (errors.isNotEmpty) {
      _lastError = errors.join('\n');
      Logger.e('output_plugin', 'loadAll failed: $_lastError');
    }
    Logger.d('output_plugin',
        'loadAll done: paths=$paths loaded=${_plugins.length}');
    return _plugins.isNotEmpty;
  }

  /// 执行所有插件的 `process(text)`，串联处理。
  /// 没有任何插件实际处理时返回 null。
  String? clean(String text) {
    if (_plugins.isEmpty) return null;
    var current = text;
    var changed = false;
    for (final p in _plugins) {
      final out = _cleanOn(p, current);
      if (out != null) {
        current = out;
        changed = true;
        _record(
          p.info,
          'process',
          'ran',
          '已执行文本清理',
          original: text,
          result: out,
        );
      } else {
        _record(
          p.info,
          'process',
          'skipped',
          '未定义 process/transform，跳过',
          original: text,
        );
      }
    }
    return changed ? current : null;
  }

  /// 提交前 hook：多插件按顺序链式执行。
  List<LlmMessage>? transformMessages(List<LlmMessage> messages) {
    if (_plugins.isEmpty) return null;
    var current = messages;
    var changed = false;
    for (final p in _plugins) {
      final out = _transformMessagesOn(p, current);
      if (out != null) {
        current = out;
        changed = true;
        _record(
          p.info,
          'beforeSend',
          'ran',
          '返回 ${out.length} 条 messages',
          original: _messagesJson(messages),
          result: _messagesJson(out),
        );
      } else {
        _record(
          p.info,
          'beforeSend',
          'skipped',
          '未定义 beforeSend，跳过',
          original: _messagesJson(current),
        );
      }
    }
    return changed ? current : null;
  }

  /// 响应后 hook：多插件按顺序链式执行，后一个拿到前一个的结果。
  LlmResponse? transformResponse(LlmResponse response) {
    if (_plugins.isEmpty) return null;
    var current = response;
    var changed = false;
    for (final p in _plugins) {
      final out = _transformResponseOn(p, current);
      if (out != null) {
        current = out;
        changed = true;
        _record(
          p.info,
          'processResponse',
          'ran',
          '已改写 content/reasoning/toolCalls',
          original: _responseJson(response),
          result: _responseJson(out),
        );
      } else {
        _record(
          p.info,
          'processResponse',
          'skipped',
          '未定义 processResponse，跳过',
          original: _responseJson(current),
        );
      }
    }
    // 兜底清理：即使某个插件只处理了正文、忘了过滤思考，也不能让
    // <｜tool｜ calls> 这类泄漏标签继续显示在思考/正文里。
    final cleanedContent = clean(current.content);
    if (cleanedContent != null) {
      current = current.copyWith(content: cleanedContent);
    }
    final cleanedReasoning = clean(current.reasoningContent);
    if (cleanedReasoning != null) {
      current = current.copyWith(reasoningContent: cleanedReasoning);
    }
    return changed ? current : null;
  }

  static String _messagesJson(List<LlmMessage> messages) =>
      const JsonEncoder.withIndent('  ')
          .convert([for (final m in messages) m.toJson()]);

  static String _responseJson(LlmResponse r) =>
      const JsonEncoder.withIndent('  ').convert({
        'content': r.content,
        'reasoning': r.reasoningContent,
        'toolCalls': [
          for (final t in r.toolCalls)
            {'id': t.id, 'name': t.name, 'arguments': t.arguments},
        ],
      });

  String? _cleanOn(_LoadedOutputPlugin p, String text) {
    final literal = jsonEncode(text);
    // 每次调用前把插件源码重新放进同一个 JS 上下文执行：
    // 不依赖 globalThis 在多次 evaluate 之间是否保持，函数一定在当前作用域里。
    final js = '${p.source}\n'
        'try {'
        '  const __f = (typeof process !== "undefined" && typeof process === "function")'
        '    ? process : (typeof transform !== "undefined" ? transform : null);'
        '  if (!__f) throw new Error("no process/transform");'
        '  JSON.stringify(__f($literal));'
        '} catch (e) { JSON.stringify(null); }';
    try {
      final result = p.runtime.evaluate(js);
      if (result.isError) return null;
      final decoded = jsonDecode(result.stringResult);
      if (decoded is String && decoded != text) {
        Logger.d('output_plugin',
            'clean ${p.info.name}: ${text.length}->${decoded.length}');
      }
      return decoded is String ? decoded : null;
    } catch (_) {
      _record(p.info, 'process', 'error', '执行异常', original: text);
      return null;
    }
  }

  List<LlmMessage>? _transformMessagesOn(
    _LoadedOutputPlugin p,
    List<LlmMessage> messages,
  ) {
    final js = '${p.source}\n'
        'try {'
        '  const __f = (typeof beforeSend !== "undefined" && typeof beforeSend === "function")'
        '    ? beforeSend : null;'
        '  if (!__f) return null;'
        '  JSON.stringify(__f(${jsonEncode([
          for (final m in messages) m.toJson()
        ])}));'
        '} catch (e) { JSON.stringify(null); }';
    try {
      final result = p.runtime.evaluate(js);
      if (result.isError) return null;
      final decoded = jsonDecode(result.stringResult);
      if (decoded is! List) return null;
      return [
        for (final item in decoded)
          if (item is Map<String, dynamic>)
            _messageFromJson(item)
          else if (item is Map)
            _messageFromJson(item.cast<String, dynamic>()),
      ];
    } catch (_) {
      _record(
        p.info,
        'beforeSend',
        'error',
        '执行异常',
        original: _messagesJson(messages),
      );
      return null;
    }
  }

  LlmResponse? _transformResponseOn(
    _LoadedOutputPlugin p,
    LlmResponse response,
  ) {
    final data = {
      'content': response.content,
      'reasoning': response.reasoningContent,
      'toolCalls': [
        for (final t in response.toolCalls)
          {'id': t.id, 'name': t.name, 'arguments': t.arguments},
      ],
    };
    final js = '${p.source}\n'
        'try {'
        '  const __f = (typeof processResponse !== "undefined" && typeof processResponse === "function")'
        '    ? processResponse : null;'
        '  if (!__f) return null;'
        '  JSON.stringify(__f(${jsonEncode(data)}));'
        '} catch (e) { JSON.stringify(null); }';
    try {
      final result = p.runtime.evaluate(js);
      if (result.isError) return null;
      final decoded = jsonDecode(result.stringResult);
      if (decoded is! Map) return null;
      final map = decoded.cast<String, dynamic>();
      var transformed = LlmResponse(
        content: map['content']?.toString() ?? response.content,
        reasoningContent:
            map['reasoning']?.toString() ?? response.reasoningContent,
        toolCalls: _toolCallsFromJson(map['toolCalls']) ?? response.toolCalls,
        finishReason: response.finishReason,
        usage: response.usage,
        recoveredToolCalls: response.recoveredToolCalls,
        brokenToolMarkup: response.brokenToolMarkup,
      );
      Logger.d(
        'output_plugin',
        'processResponse ${p.info.name}: '
            'content ${response.content.length}->${transformed.content.length}, '
            'reasoning ${response.reasoningContent.length}->'
            '${transformed.reasoningContent.length}, '
            'tools ${response.toolCalls.length}->${transformed.toolCalls.length}',
      );
      return transformed;
    } catch (_) {
      _record(
        p.info,
        'processResponse',
        'error',
        '执行异常',
        original: _responseJson(response),
      );
      return null;
    }
  }

  static LlmMessage _messageFromJson(Map<String, dynamic> json) => LlmMessage(
        role: json['role']?.toString() ?? 'user',
        content: json['content']?.toString() ?? '',
        toolCallId: json['tool_call_id']?.toString(),
        name: json['name']?.toString(),
        toolCalls: _toolCallsFromJson(json['tool_calls']) ?? const [],
      );

  static List<LlmToolCall>? _toolCallsFromJson(dynamic value) {
    if (value is! List) return null;
    final out = <LlmToolCall>[];
    for (final item in value) {
      if (item is! Map) continue;
      final map = item.cast<String, dynamic>();
      final fn = map['function'];
      if (fn is Map) {
        final f = fn.cast<String, dynamic>();
        out.add(LlmToolCall(
          id: map['id']?.toString() ?? '',
          name: f['name']?.toString() ?? '',
          arguments: _decodeArgs(f['arguments']),
        ));
      } else {
        out.add(LlmToolCall(
          id: map['id']?.toString() ?? '',
          name: map['name']?.toString() ?? '',
          arguments: _decodeArgs(map['arguments']),
        ));
      }
    }
    return out.isEmpty ? const [] : out;
  }

  static Map<String, dynamic> _decodeArgs(dynamic value) {
    if (value is Map) return value.cast<String, dynamic>();
    if (value is String && value.trim().isNotEmpty) {
      try {
        final decoded = jsonDecode(value);
        if (decoded is Map) return decoded.cast<String, dynamic>();
      } catch (_) {}
    }
    return const {};
  }

  /// 解析插件文件：识别注释 + 基本元信息。
  static ParsedOutputPlugin parsePlugin(String source, String path) {
    final head = source.length > 800 ? source.substring(0, 800) : source;
    final recognized = head.contains('@qinglong-plugin') ||
        head.contains('@ql-plugin') ||
        head.toLowerCase().contains('qinglong plugin');
    final hasFunction = RegExp(
      r'(function\s+(processResponse|beforeSend|process|transform)\b)'
      r'|((?:const|let|var)\s+(processResponse|beforeSend|process|transform)\s*=)'
      r'|((processResponse|beforeSend|process|transform)\s*[:=]\s*(?:async\s*)?(?:function|\())',
    ).hasMatch(source);
    if (!recognized || !hasFunction) {
      return ParsedOutputPlugin(
        valid: false,
        name: '',
        description: '',
        source: source,
      );
    }
    String name = path.split('/').last;
    final nameMatch = RegExp(
      r'^\s*(?://|/\*|\*|#)\s*(?:name|插件名)\s*[:：]\s*(.+?)\s*$',
      multiLine: true,
    ).firstMatch(source);
    if (nameMatch != null) name = nameMatch.group(1)!.trim();

    String description = '';
    final descMatch = RegExp(
      r'^\s*(?://|/\*|\*|#)\s*(?:description|描述)\s*[:：]\s*(.+?)\s*$',
      multiLine: true,
    ).firstMatch(source);
    if (descMatch != null) description = descMatch.group(1)!.trim();

    return ParsedOutputPlugin(
      valid: true,
      name: name,
      description: description,
      source: source,
    );
  }
}
