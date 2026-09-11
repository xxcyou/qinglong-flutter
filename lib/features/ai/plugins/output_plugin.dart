import 'dart:convert';

import 'package:flutter_js/flutter_js.dart';

import '../../../core/llm/llm_client.dart';

import '../../../core/local_shell/proot_bridge.dart';

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

/// 输出整理插件服务。
///
/// 插件是文件管理里用户自己新建的 `.js` 文件，必须带识别注释：
/// ```js
/// // @qinglong-plugin
/// // name: 输出整理
/// // description: 清理模型输出泄露的工具调用标记
/// function process(text) {
///   return text.replace(/<｜tool｜ calls>[\s\S]*?<\/｜tool｜ calls>/g, '');
/// }
/// ```
///
/// 选择后由 [load] 读取并用内置 QuickJS 引擎执行。`process` 或 `transform`
/// 函数负责把输入文本整理成最终展示文本。
class OutputPluginService {
  OutputPluginService._();

  static final OutputPluginService instance = OutputPluginService._();

  JavascriptRuntime? _runtime;
  String _loadedPath = '';
  String _name = '';
  String _description = '';
  bool _loaded = false;
  String? _lastError;

  bool get isLoaded => _loaded;
  String get loadedPath => _loadedPath;
  String get name => _name;
  String get description => _description;
  String? get lastError => _lastError;

  /// 从 PRoot 文件路径加载插件。失败会记录错误并返回 false。
  Future<bool> load(String path) async {
    _lastError = null;
    try {
      final bridge = ProotBridge();
      final raw = await bridge.readFile(path: path, scope: 'shell');
      final parsed = parsePlugin(raw, path);
      if (!parsed.valid) {
        _lastError =
            '不是有效的 QingLong 插件文件（缺 @qinglong-plugin 标记或 process/transform 函数）';
        return false;
      }
      final runtime = _runtime ??= getJavascriptRuntime(
        xhr: false,
        forceJavascriptCoreOnAndroid: false,
      );
      final result = runtime.evaluate(parsed.source);
      if (result.isError) {
        _lastError = 'JS 执行失败：${result.stringResult}';
        return false;
      }
      _loadedPath = path;
      _name = parsed.name;
      _description = parsed.description;
      _loaded = true;
      return true;
    } catch (e) {
      _lastError = e.toString();
      return false;
    }
  }

  /// 执行已加载插件的 `process(text)`。未加载/执行失败返回 null（上层继续用原文本）。
  String? clean(String text) {
    if (!_loaded || _runtime == null) return null;
    final literal = jsonEncode(text);
    final js = 'try {'
        '  const __f = (typeof process !== "undefined" && typeof process === "function")'
        '    ? process : (typeof transform !== "undefined" ? transform : null);'
        '  if (!__f) throw new Error("no process/transform");'
        '  JSON.stringify(__f($literal));'
        '} catch (e) { JSON.stringify(null); }';
    try {
      final result = _runtime!.evaluate(js);
      if (result.isError) return null;
      final decoded = jsonDecode(result.stringResult);
      return decoded is String ? decoded : null;
    } catch (_) {
      return null;
    }
  }

  /// 提交前 hook：插件 `beforeSend(messages)` 可以增删/改写要发给模型的 messages。
  ///
  /// 返回 null 表示插件没定义这个 hook 或执行失败，上层继续用原 messages。
  List<LlmMessage>? transformMessages(List<LlmMessage> messages) {
    if (!_loaded || _runtime == null) return null;
    final js = 'try {'
        '  const __f = (typeof beforeSend !== "undefined" && typeof beforeSend === "function")'
        '    ? beforeSend : null;'
        '  if (!__f) return null;'
        '  JSON.stringify(__f(${jsonEncode([
          for (final m in messages) m.toJson()
        ])}));'
        '} catch (e) { JSON.stringify(null); }';
    try {
      final result = _runtime!.evaluate(js);
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
      return null;
    }
  }

  /// 响应后 hook：插件 `processResponse({content, reasoning, toolCalls})`
  /// 可以同时改写正文、思考、甚至把“溢出成正文的工具调用”捞回结构化 toolCalls。
  ///
  /// 返回 null 表示插件没定义这个 hook 或执行失败，上层继续用原 response。
  LlmResponse? transformResponse(LlmResponse response) {
    if (!_loaded || _runtime == null) return null;
    final data = {
      'content': response.content,
      'reasoning': response.reasoningContent,
      'toolCalls': [
        for (final t in response.toolCalls)
          {'id': t.id, 'name': t.name, 'arguments': t.arguments},
      ],
    };
    final js = 'try {'
        '  const __f = (typeof processResponse !== "undefined" && typeof processResponse === "function")'
        '    ? processResponse : null;'
        '  if (!__f) return null;'
        '  JSON.stringify(__f(${jsonEncode(data)}));'
        '} catch (e) { JSON.stringify(null); }';
    try {
      final result = _runtime!.evaluate(js);
      if (result.isError) return null;
      final decoded = jsonDecode(result.stringResult);
      if (decoded is! Map) return null;
      final map = decoded.cast<String, dynamic>();
      return LlmResponse(
        content: map['content']?.toString() ?? response.content,
        reasoningContent:
            map['reasoning']?.toString() ?? response.reasoningContent,
        toolCalls: _toolCallsFromJson(map['toolCalls']) ?? response.toolCalls,
        finishReason: response.finishReason,
        usage: response.usage,
        recoveredToolCalls: response.recoveredToolCalls,
        brokenToolMarkup: response.brokenToolMarkup,
      );
    } catch (_) {
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
  ///
  /// [source] 整份源码直接交给 QuickJS 执行，函数名按约定 `process` / `transform`。
  static ParsedOutputPlugin parsePlugin(String source, String path) {
    final head = source.length > 800 ? source.substring(0, 800) : source;
    final recognized = head.contains('@qinglong-plugin') ||
        head.contains('@ql-plugin') ||
        head.toLowerCase().contains('qinglong plugin');
    final hasFunction = source.contains(RegExp(
      r'function\s+(process|transform)\s*\(',
    ));
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
      r'^.*?(?:name|插件名)\s*[:：]\s*(.+?)\s*$',
      multiLine: true,
    ).firstMatch(source);
    if (nameMatch != null) name = nameMatch.group(1)!.trim();

    String description = '';
    final descMatch = RegExp(
      r'^.*?(?:description|描述)\s*[:：]\s*(.+?)\s*$',
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

  /// 生成一个最常用的输出整理插件模板，方便用户照着改。
  static String template() => r'''
// @qinglong-plugin 输出整理插件
// name: 全面输出插件
// description: 底层 hook：清理泄露标记、过滤思考/正文、提交前注入提示词

// 1) 提交前 hook：可以增删/改写要发给模型的 messages。
//    messages 是 [{role, content, tool_calls?}] 数组。
function beforeSend(messages) {
  // 示例：在系统提示后注入一段自定义提示词
  // messages.unshift({role: 'system', content: '额外要求：回答用中文。'});
  return messages;
}

// 2) 响应后 hook：同时处理正文、思考和工具调用。
//    这是“标签溢出变成正文”的真正修复点：把泄露的 <｜tool｜ calls>
//    标签重新解析成结构化 toolCalls，让 APP 真的去调用工具。
function processResponse({content, reasoning, toolCalls}) {
  // —— 从正文里捞回“溢出成正文”的工具调用 ——
  // 匹配格式：
  // <｜tool｜ invoke name="shell_exec">
  //   <｜tool｜ parameter name="command" string="true">ls</｜tool｜ parameter>
  //   <｜tool｜ parameter name="timeoutSeconds" string="false">20</｜tool｜ parameter>
  // </｜tool｜ invoke>
  const invokeRe = /<｜tool｜ invoke name="([^"]+)">([\s\S]*?)<\/｜tool｜ invoke>/g;
  const paramRe = /<｜tool｜ parameter name="([^"]+)" string="(true|false)">([\s\S]*?)<\/｜tool｜ parameter>/g;
  let m;
  while ((m = invokeRe.exec(content)) !== null) {
    const name = m[1];
    const body = m[2];
    const args = {};
    let p;
    while ((p = paramRe.exec(body)) !== null) {
      const key = p[1];
      const isString = p[2] === 'true';
      const raw = p[3].trim();
      try {
        args[key] = isString ? raw : (
          raw === 'true' ? true : raw === 'false' ? false : Number(raw)
        );
      } catch (e) {
        args[key] = raw;
      }
      // 重置 lastIndex，避免多条 parameter 之间互相跳过。
      // （上面 while 用同一个 regex，exec 会推进；这里其实已经推进，
      //   但要小心 invoke 外层复用 paramRe 时 lastIndex 不会串。）
    }
    paramRe.lastIndex = 0;
    toolCalls.push({
      id: 'plugin_' + Date.now() + '_' + toolCalls.length,
      name: name,
      arguments: args
    });
  }

  // 去掉正文里残留的工具调用标签，避免“又显示一遍”。
  content = content
    .replace(/<｜tool｜ calls>[\s\S]*?<\/｜tool｜ calls>/g, '')
    .replace(/<｜tool｜ invoke[\s\S]*?<\/｜tool｜ invoke>/g, '')
    .replace(/<\/｜tool｜ (calls|invoke|parameter)>/g, '');

  // —— 过滤思考里多余的内容 ——
  // if (reasoning.includes('某段不想显示的思考')) reasoning = '';

  // —— 正文屏蔽 ——
  // content = content.replace(/不允许出现的词/g, '***');

  return {content, reasoning, toolCalls};
}

// 3) 简单文本处理（兼容旧插件）：只有 process/transform 时也会自动生效。
function process(text) {
  return text
    .replace(/<｜tool｜ calls>[\s\S]*?<\/｜tool｜ calls>/g, '')
    .replace(/<｜tool｜ invoke[\s\S]*?<\/｜tool｜ invoke>/g, '')
    .replace(/<\/｜tool｜ (calls|invoke|parameter)>/g, '');
}
''';
}
