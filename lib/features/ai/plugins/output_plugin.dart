import 'dart:convert';

import 'package:flutter_js/flutter_js.dart';

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
  static String template() => '''
// @qinglong-plugin 输出整理插件
// name: 泄露标记清理
// description: 清理模型输出里泄露的 <｜tool｜ calls> 等内部工具调用标记
//
// 函数签名固定：function process(text) 或 function transform(text)
// 入参是模型原始输出文本，返回值是整理后的展示文本。
function process(text) {
  // 去掉伪造工具调用块。注意：这里只是展示层整理，不影响实际执行。
  return text
    .replace(/<｜tool｜ calls>[\\s\\S]*?<\\/｜tool｜ calls>/g, '')
    .replace(/<｜tool｜ invoke[\\s\\S]*?<\\/｜tool｜ invoke>/g, '')
    .replace(/<｜tool｜ parameter[\\s\\S]*?<\\/｜tool｜ parameter>/g, '')
    .replace(/<\\/｜tool｜ (calls|invoke|parameter)>/g, '');
}
''';
}
