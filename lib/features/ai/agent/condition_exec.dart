import 'dart:convert';

/// 条件执行/微流程引擎 v2。
///
/// 比第一版强的地方：
/// - 变量可以存动态值（数字/字符串/布尔/列表/字典），不再只有字符串
/// - 支持完整表达式：`+ - * / %`、比较、`&& || !`、三元 `?:`、函数调用
/// - 支持 `set / if / for / while / break / return / try` 控制流
/// - 支持函数：`functions` 或 `type:"function"` 定义，`type:"call"` 调用，
///   `return` 返回值，参数数组/默认值，调用时局部变量不污染外层
/// - 工具结果自动尝试 JSON 解码，后面可以直接 `$result.items[0]`
/// - 保留延迟、嵌套、思维链步骤可视化
class ConditionExecEngine {
  ConditionExecEngine({
    required this.callTool,
    required this.emitStep,
  });

  /// 调用外部工具，返回工具文本结果。
  final Future<String> Function(String name, Map<String, dynamic> args)
      callTool;

  /// 每个可执行步骤往前端思维链发一条可视化事件。
  final void Function({
    required String message,
    Map<String, dynamic>? args,
    String? result,
    required bool ok,
    int? durationMs,
    required int depth,
  }) emitStep;

  Map<String, dynamic> _vars = {};
  final Map<String, _DslFunction> _functions = {};
  final StringBuffer _out = StringBuffer();

  Future<String> run(
    List<dynamic> steps,
    Map<String, dynamic> initialVars, {
    List<dynamic> functions = const [],
  }) async {
    _vars.clear();
    _vars.addAll(initialVars);
    _functions.clear();
    _out.clear();
    for (final fn in functions) {
      _registerFunction(fn);
    }
    for (final step in steps) {
      _registerFunction(step);
    }
    try {
      await _runSteps(steps, depth: 0);
    } on _ReturnSignal catch (r) {
      if (r.value != null) _out.writeln('return: ${_stringify(r.value)}');
    } catch (e) {
      _out.writeln('条件执行中断：$e');
    }
    final text = _out.toString().trim();
    return text.isEmpty ? '条件执行：没有可执行步骤。' : text;
  }

  void _registerFunction(Object? raw) {
    if (raw is! Map) return;
    final step = raw.map((k, v) => MapEntry(k.toString(), v));
    if (step['type']?.toString() != 'function') return;
    final name = (step['name'] ?? step['fn'] ?? '').toString().trim();
    if (name.isEmpty) throw const FormatException('函数名不能为空');
    if (step['body'] is! List) {
      throw FormatException('函数 $name 缺少 body 步骤数组');
    }
    final params = step['params'];
    final names = <String>[];
    final defaults = <String, Object?>{};
    if (params is List) {
      for (final p in params) {
        names.add(p.toString());
      }
    } else if (params is Map) {
      for (final e in params.entries) {
        names.add(e.key.toString());
        defaults[e.key.toString()] = e.value;
      }
    } else if (params != null) {
      throw FormatException('函数 $name 的 params 必须是数组或对象');
    }
    _functions[name] = _DslFunction(
      name: name,
      params: names,
      defaults: defaults,
      body: (step['body'] as List).cast<dynamic>(),
    );
  }

  Future<Object?> _invokeDslFunction(
    String name,
    Map<String, dynamic> args,
    int depth,
  ) async {
    if (depth > 12) throw StateError('函数调用嵌套超过 12 层');
    final fn = _functions[name];
    if (fn == null) throw FormatException('未定义函数 $name');
    final local = <String, dynamic>{..._vars};
    for (final p in fn.params) {
      if (args.containsKey(p)) {
        local[p] = args[p];
      } else if (fn.defaults.containsKey(p)) {
        local[p] = _eval(fn.defaults[p]);
      } else {
        local[p] = null;
      }
    }
    final saved = _vars;
    _vars = local;
    Object? ret;
    try {
      await _runSteps(fn.body, depth: depth);
    } on _ReturnSignal catch (r) {
      ret = r.value;
    } finally {
      _vars = saved;
    }
    return ret;
  }

  void _emit({
    required String message,
    Map<String, dynamic>? args,
    String? result,
    bool ok = true,
    int? durationMs,
    required int depth,
  }) {
    emitStep(
      message: message,
      args: {...?args, '_depth': depth},
      result: result,
      ok: ok,
      durationMs: durationMs,
      depth: depth,
    );
  }

  Future<void> _runSteps(List<dynamic> steps, {required int depth}) async {
    if (depth > 12) throw StateError('条件执行嵌套超过 12 层');
    for (var i = 0; i < steps.length; i++) {
      final raw = steps[i];
      if (raw is! Map) continue;
      final step = raw.map((k, v) => MapEntry(k.toString(), v));
      final type = (step['type'] ?? 'tool').toString();
      final id = (step['id'] ?? step['name'] ?? '步骤${i + 1}').toString();
      final indent = List.filled(depth, '  ').join();
      switch (type) {
        case 'tool':
          await _tool(step, id, indent, depth);
        case 'function':
          _emit(
            message: '条件执行 · $id · 定义函数 ${step['name'] ?? step['fn'] ?? ''}',
            args: {'step': id, 'type': 'function'},
            result: '已注册函数',
            ok: true,
            depth: depth,
          );
        case 'call':
          await _call(step, id, indent, depth);
        case 'set':
          _set(step, id, indent, depth);
        case 'delay':
          await _delay(step, id, indent, depth);
        case 'if':
          await _if(step, id, indent, depth);
        case 'for':
          await _for(step, id, indent, depth);
        case 'while':
          await _while(step, id, indent, depth);
        case 'try':
          await _try(step, id, indent, depth);
        case 'break':
          throw const _BreakSignal();
        case 'return':
          throw _ReturnSignal(
              step['value'] == null ? null : _eval(step['value']!));
        case 'log':
          _log(step, id, indent, depth);
        default:
          final msg = '未知步骤类型 $type';
          _out.writeln('$indent- $id: $msg');
          _emit(
            message: '条件执行 · $id · 未知类型',
            args: {'step': id, 'type': type},
            result: msg,
            ok: false,
            depth: depth,
          );
      }
    }
  }

  Future<void> _tool(
    Map<String, dynamic> step,
    String id,
    String indent,
    int depth,
  ) async {
    final name = (step['tool'] ?? step['name'] ?? '').toString().trim();
    if (name.isEmpty) {
      _out.writeln('$indent- $id: 缺少 tool 名字');
      return;
    }
    if (name == 'condition_exec') {
      _out.writeln('$indent- $id: 不允许递归调用 condition_exec');
      return;
    }
    final rawArgs = step['args'];
    final args = <String, dynamic>{};
    if (rawArgs is Map) {
      for (final e in rawArgs.entries) {
        args[e.key.toString()] = _argValue(e.value);
      }
    }
    final sw = Stopwatch()..start();
    String result;
    var ok = true;
    try {
      result = await callTool(name, args);
    } catch (e) {
      result = '调用失败：$e';
      ok = false;
    }
    sw.stop();
    _vars['last'] = _tryParse(result);
    final saveTo = (step['save_to'] ?? step['as'] ?? '').toString().trim();
    if (saveTo.isNotEmpty) _vars[saveTo] = _tryParse(result);
    _out.writeln('$indent- $id · $name：${_snippet(result)}');
    _emit(
      message: '条件执行 · $id · $name',
      args: {'step': id, 'tool': name, ...args},
      result: result,
      ok: ok,
      durationMs: sw.elapsedMilliseconds,
      depth: depth,
    );
  }

  Future<void> _call(
    Map<String, dynamic> step,
    String id,
    String indent,
    int depth,
  ) async {
    final name = (step['fn'] ?? step['function'] ?? step['name'] ?? '')
        .toString()
        .trim();
    if (name.isEmpty) {
      _out.writeln('$indent- $id: 缺少 fn 函数名');
      return;
    }
    if (!_functions.containsKey(name)) {
      throw FormatException('未定义函数 $name');
    }
    final rawArgs = step['args'];
    final args = <String, dynamic>{};
    if (rawArgs is Map) {
      for (final e in rawArgs.entries) {
        args[e.key.toString()] = _argValue(e.value);
      }
    }
    final sw = Stopwatch()..start();
    final result = await _invokeDslFunction(name, args, depth + 1);
    sw.stop();
    _vars['last'] = result;
    final saveTo = (step['save_to'] ?? step['as'] ?? '').toString().trim();
    if (saveTo.isNotEmpty) _vars[saveTo] = result;
    final display = result == null ? 'null' : _snippet(_stringify(result));
    _out.writeln('$indent- $id · 调用 $name = $display');
    _emit(
      message: '条件执行 · $id · 调用 $name',
      args: {'step': id, 'fn': name, ...args},
      result: display,
      ok: true,
      durationMs: sw.elapsedMilliseconds,
      depth: depth,
    );
  }

  void _set(Map<String, dynamic> step, String id, String indent, int depth) {
    final to = (step['to'] ?? step['var'] ?? 'last').toString();
    final value = _eval(step['value'] ?? '');
    _vars[to] = value;
    _out.writeln('$indent- $id · 赋值 $to = ${_snippet(_stringify(value))}');
    _emit(
      message: '条件执行 · $id · 赋值 $to',
      args: {'step': id, 'to': to, 'value': value},
      result: _stringify(value),
      ok: true,
      depth: depth,
    );
  }

  Future<void> _delay(
    Map<String, dynamic> step,
    String id,
    String indent,
    int depth,
  ) async {
    final value =
        _evalNum(step['ms'] ?? step['duration'] ?? step['duration_ms'] ?? 1000);
    final ms = value.toInt().clamp(0, 60000);
    final sw = Stopwatch()..start();
    await Future<void>.delayed(Duration(milliseconds: ms));
    sw.stop();
    _out.writeln('$indent- $id · 延迟 ${ms}ms');
    _emit(
      message: '条件执行 · $id · 延迟 ${ms}ms',
      args: {'step': id, 'ms': ms},
      result: '已等待 ${ms}ms',
      ok: true,
      durationMs: sw.elapsedMilliseconds,
      depth: depth,
    );
  }

  Future<void> _if(
    Map<String, dynamic> step,
    String id,
    String indent,
    int depth,
  ) async {
    final condition = (step['if'] ?? step['condition'] ?? 'true').toString();
    final picked = _truthy(_eval(condition));
    final branch = picked ? step['then'] : step['else'];
    _out.writeln('$indent- $id · 分支($condition) → ${picked ? 'then' : 'else'}');
    _emit(
      message: '条件执行 · $id · 分支 ${picked ? 'then' : 'else'}',
      args: {'step': id, 'condition': condition},
      result: '命中 ${picked ? 'then' : 'else'}',
      ok: true,
      depth: depth,
    );
    if (branch is List && branch.isNotEmpty) {
      await _runSteps(branch.cast<dynamic>(), depth: depth + 1);
    }
  }

  Future<void> _for(
    Map<String, dynamic> step,
    String id,
    String indent,
    int depth,
  ) async {
    final varName = (step['var'] ?? step['variable'] ?? 'item').toString();
    List<dynamic> items;
    if (step['items'] != null) {
      final v = _eval(step['items']!);
      if (v is List) {
        items = v;
      } else {
        items = _stringify(v).split(',');
      }
    } else {
      final start = _evalNum(step['start'] ?? 0).toInt();
      final end = _evalNum(step['end'] ?? 0).toInt();
      final stepVal = _evalNum(step['step'] ?? 1).toInt().clamp(1, 1000000);
      items = [
        for (var i = start; i < end; i += stepVal) i,
      ];
    }
    _out.writeln('$indent- $id · 循环 ${items.length} 次');
    _emit(
      message: '条件执行 · $id · 循环',
      args: {'step': id, 'count': items.length},
      result: '循环 ${items.length} 次',
      ok: true,
      depth: depth,
    );
    if (step['body'] is! List) return;
    final body = (step['body'] as List).cast<dynamic>();
    try {
      for (final item in items) {
        _vars[varName] = item;
        await _runSteps(body, depth: depth + 1);
      }
    } on _BreakSignal {
      _out.writeln('$indent- $id · break');
    }
  }

  Future<void> _while(
    Map<String, dynamic> step,
    String id,
    String indent,
    int depth,
  ) async {
    final condition =
        (step['while'] ?? step['condition'] ?? 'false').toString();
    final max = _evalNum(step['max'] ?? 1000).toInt().clamp(1, 100000);
    var count = 0;
    while (_truthy(_eval(condition)) && count < max) {
      _out.writeln('$indent- $id · 第 ${count + 1} 次循环');
      _emit(
        message: '条件执行 · $id · 循环 ${count + 1}',
        args: {'step': id, 'iteration': count + 1},
        result: '第 ${count + 1} 次循环',
        ok: true,
        depth: depth,
      );
      if (step['body'] is! List) break;
      try {
        await _runSteps(
          (step['body'] as List).cast<dynamic>(),
          depth: depth + 1,
        );
      } on _BreakSignal {
        _out.writeln('$indent- $id · break');
        break;
      }
      count++;
    }
    if (count == max) _out.writeln('$indent- $id · 达到最大次数 $max');
  }

  Future<void> _try(
    Map<String, dynamic> step,
    String id,
    String indent,
    int depth,
  ) async {
    final errorVar = (step['error_var'] ?? 'error').toString();
    try {
      if (step['try'] is List) {
        await _runSteps(
          (step['try'] as List).cast<dynamic>(),
          depth: depth + 1,
        );
      }
    } catch (e) {
      if (e is _ReturnSignal || e is _BreakSignal) rethrow;
      _vars[errorVar] = e.toString();
      _out.writeln('$indent- $id · 捕获错误：${_snippet(e.toString())}');
      _emit(
        message: '条件执行 · $id · 捕获错误',
        args: {'step': id},
        result: e.toString(),
        ok: false,
        depth: depth,
      );
      if (step['catch'] is List) {
        await _runSteps(
          (step['catch'] as List).cast<dynamic>(),
          depth: depth + 1,
        );
      }
    }
  }

  void _log(Map<String, dynamic> step, String id, String indent, int depth) {
    final hasMessage = step['message'] != null;
    final hasValue = step['value'] != null;
    String msg;
    if (hasMessage) {
      final raw = step['message']!.toString();
      msg = raw.trim().startsWith('expr:')
          ? _stringify(_eval(raw.trim().substring(5)))
          : _template(raw);
    } else if (hasValue) {
      msg = _stringify(_eval(step['value']!));
    } else {
      msg = '';
    }
    _out.writeln('$indent- $id · $msg');
    _emit(
      message: '条件执行 · $id',
      args: {'step': id, 'message': msg},
      result: msg,
      ok: true,
      depth: depth,
    );
  }

  // ------------------------------------------------------------ 表达式

  dynamic _argValue(Object? value) {
    if (value is String) {
      final trimmed = value.trim();
      if (trimmed.startsWith('expr:')) {
        return _eval(trimmed.substring(5));
      }
      return _template(value);
    }
    return value;
  }

  String _template(String s) {
    return s.replaceAllMapped(
      RegExp(r'\$\{([A-Za-z_][A-Za-z0-9_]*)\}|\$([A-Za-z_][A-Za-z0-9_]*)'),
      (m) {
        final name = m.group(1) ?? m.group(2) ?? '';
        return _stringify(_vars[name]);
      },
    );
  }

  dynamic _eval(Object? raw) {
    if (raw is num || raw is bool || raw == null) return raw;
    if (raw is List) return [for (final v in raw) _eval(v)];
    if (raw is Map) {
      return raw.map(
        (k, v) => MapEntry(_stringify(_eval(k)), _eval(v)),
      );
    }
    final source = raw.toString().trim();
    if (source.isEmpty) return '';
    final lexer = _Lexer(source);
    final parser = _Parser(lexer.tokens, _vars);
    return parser.parse();
  }

  num _evalNum(Object? raw) {
    final v = _eval(raw);
    if (v is num) return v;
    final n = num.tryParse(_stringify(v).trim());
    if (n != null) return n;
    return 0;
  }

  bool _truthy(Object? v) {
    if (v == null) return false;
    if (v is bool) return v;
    if (v is num) return v != 0;
    if (v is String) return v.isNotEmpty;
    if (v is List) return v.isNotEmpty;
    if (v is Map) return v.isNotEmpty;
    return true;
  }

  Object? _tryParse(String result) {
    final t = result.trim();
    if (!(t.startsWith('{') || t.startsWith('['))) return result;
    try {
      return jsonDecode(t);
    } catch (_) {
      return result;
    }
  }

  static String _snippet(String text, [int max = 240]) {
    final oneLine = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (oneLine.length <= max) return oneLine;
    return '${oneLine.substring(0, max)}…';
  }

  static String _stringify(Object? v) {
    if (v == null) return '';
    if (v is String) return v;
    if (v is num || v is bool) return v.toString();
    return const JsonEncoder.withIndent('  ').convert(v);
  }
}

class _DslFunction {
  _DslFunction({
    required this.name,
    required this.params,
    required this.defaults,
    required this.body,
  });

  final String name;
  final List<String> params;
  final Map<String, Object?> defaults;
  final List<dynamic> body;
}

class _BreakSignal implements Exception {
  const _BreakSignal();
}

class _ReturnSignal implements Exception {
  const _ReturnSignal(this.value);
  final Object? value;
}

enum _TokType { number, string, ident, variable, op, eof }

class _Token {
  const _Token(this.type, this.value, this.pos);
  final _TokType type;
  final Object value;
  final int pos;
}

class _Lexer {
  _Lexer(String source) {
    _src = source;
    _pos = 0;
    _scan();
  }

  late String _src;
  late int _pos;
  final List<_Token> tokens = [];

  void _scan() {
    while (_pos < _src.length) {
      final ch = _src[_pos];
      if (_isSpace(ch)) {
        _pos++;
        continue;
      }
      final start = _pos;
      if (_isDigit(ch) ||
          (ch == '.' && _pos + 1 < _src.length && _isDigit(_src[_pos + 1]))) {
        while (_pos < _src.length && _isDigit(_src[_pos])) {
          _pos++;
        }
        if (_pos < _src.length && _src[_pos] == '.') {
          _pos++;
          while (_pos < _src.length && _isDigit(_src[_pos])) {
            _pos++;
          }
        }
        tokens.add(_Token(
            _TokType.number, num.parse(_src.substring(start, _pos)), start));
        continue;
      }
      if (ch == '"' || ch == "'") {
        final quote = ch;
        _pos++;
        final buf = StringBuffer();
        while (_pos < _src.length && _src[_pos] != quote) {
          if (_src[_pos] == '\\' && _pos + 1 < _src.length) {
            _pos++;
            buf.write(_src[_pos]);
          } else {
            buf.write(_src[_pos]);
          }
          _pos++;
        }
        if (_pos >= _src.length) throw const FormatException('字符串没有闭合');
        _pos++;
        tokens.add(_Token(_TokType.string, buf.toString(), start));
        continue;
      }
      if (ch == r'$') {
        _pos++;
        final name = StringBuffer();
        while (_pos < _src.length &&
            (_isAlpha(_src[_pos]) ||
                _isDigit(_src[_pos]) ||
                _src[_pos] == '_')) {
          name.write(_src[_pos]);
          _pos++;
        }
        if (name.isEmpty) throw const FormatException('变量名不能为空');
        tokens.add(_Token(_TokType.variable, name.toString(), start));
        continue;
      }
      if (_isAlpha(ch) || ch == '_') {
        while (_pos < _src.length &&
            (_isAlpha(_src[_pos]) ||
                _isDigit(_src[_pos]) ||
                _src[_pos] == '_')) {
          _pos++;
        }
        tokens.add(_Token(_TokType.ident, _src.substring(start, _pos), start));
        continue;
      }
      // 多字符运算符
      final two = _pos + 1 < _src.length ? _src.substring(_pos, _pos + 2) : '';
      if (two == '==' ||
          two == '!=' ||
          two == '<=' ||
          two == '>=' ||
          two == '&&' ||
          two == '||') {
        tokens.add(_Token(_TokType.op, two, start));
        _pos += 2;
        continue;
      }
      if ('+-*/%<>=!().,[]?:'.contains(ch)) {
        tokens.add(_Token(_TokType.op, ch, start));
        _pos++;
        continue;
      }
      throw FormatException('无法识别的字符 $ch');
    }
    tokens.add(const _Token(_TokType.eof, '', 0));
  }

  static bool _isSpace(String c) =>
      c == ' ' || c == '\t' || c == '\r' || c == '\n';
  static bool _isDigit(String c) =>
      c.codeUnitAt(0) >= 48 && c.codeUnitAt(0) <= 57;
  static bool _isAlpha(String c) {
    final u = c.codeUnitAt(0);
    return (u >= 65 && u <= 90) || (u >= 97 && u <= 122);
  }
}

class _Parser {
  _Parser(this._tokens, this._vars);
  final List<_Token> _tokens;
  final Map<String, dynamic> _vars;
  int _pos = 0;

  dynamic parse() {
    final v = _parseTernary();
    final t = _cur;
    if (t.type != _TokType.eof) throw FormatException('多余内容：${t.value}');
    return v;
  }

  _Token get _cur => _tokens[_pos];

  _Token _take() => _tokens[_pos++];
  _Token _expect(String op) {
    final t = _take();
    if (t.type != _TokType.op || t.value != op) {
      throw FormatException('期待 $op，实际 ${t.value}');
    }
    return t;
  }

  bool _peekOp(String op) => _cur.type == _TokType.op && _cur.value == op;

  dynamic _parseTernary() {
    final cond = _parseOr();
    if (_peekOp('?')) {
      _take();
      final then = _parseTernary();
      _expect(':');
      final els = _parseTernary();
      return _truthy(cond) ? then : els;
    }
    return cond;
  }

  dynamic _parseOr() {
    var left = _parseAnd();
    while (_peekOp('||')) {
      _take();
      final right = _parseAnd();
      // JS 语义：返回实际选中的操作数，允许 `$x || '默认值'` 这种兜底写法。
      left = _truthy(left) ? left : right;
    }
    return left;
  }

  dynamic _parseAnd() {
    var left = _parseEquality();
    while (_peekOp('&&')) {
      _take();
      final right = _parseEquality();
      left = _truthy(left) ? right : left;
    }
    return left;
  }

  dynamic _parseEquality() {
    var left = _parseRelational();
    while (_peekOp('==') || _peekOp('!=')) {
      final op = _take().value.toString();
      final right = _parseRelational();
      left = op == '==' ? _equals(left, right) : !_equals(left, right);
    }
    return left;
  }

  dynamic _parseRelational() {
    var left = _parseAdditive();
    while (_peekOp('<') || _peekOp('>') || _peekOp('<=') || _peekOp('>=')) {
      final op = _take().value.toString();
      final right = _parseAdditive();
      final int cmp;
      if (left is num && right is num) {
        cmp = left.compareTo(right);
      } else if (left is String && right is String) {
        cmp = left.compareTo(right);
      } else {
        throw FormatException(
            '不能比较不同类型：${_stringify(left)} $op ${_stringify(right)}');
      }
      left = switch (op) {
        '<' => cmp < 0,
        '>' => cmp > 0,
        '<=' => cmp <= 0,
        '>=' => cmp >= 0,
        _ => false,
      };
    }
    return left;
  }

  dynamic _parseAdditive() {
    var left = _parseMultiplicative();
    while (_peekOp('+') || _peekOp('-')) {
      final op = _take().value.toString();
      final right = _parseMultiplicative();
      if (op == '+') {
        if (left is num && right is num) {
          left = left + right;
        } else if (left is String && right is String) {
          left = left + right;
        } else if (left is List && right is List) {
          left = [...left, ...right];
        } else {
          throw FormatException(
            '不能直接相加不同类型：${_stringify(left)} + ${_stringify(right)}，请用 str()/num() 显式转换',
          );
        }
      } else {
        if (left is num && right is num) {
          left = left - right;
        } else {
          throw FormatException(
              '减法只支持数字：${_stringify(left)} - ${_stringify(right)}');
        }
      }
    }
    return left;
  }

  dynamic _parseMultiplicative() {
    var left = _parseUnary();
    while (_peekOp('*') || _peekOp('/') || _peekOp('%')) {
      final op = _take().value.toString();
      final right = _parseUnary();
      final a = _num(left);
      final b = _num(right);
      if (op != '*' && b == 0) {
        throw const FormatException('除数为 0');
      }
      left = switch (op) {
        '*' => a * b,
        '/' => a / b,
        '%' => a % b,
        _ => 0,
      };
    }
    return left;
  }

  dynamic _parseUnary() {
    if (_peekOp('!')) {
      _take();
      return !_truthy(_parseUnary());
    }
    if (_peekOp('-')) {
      _take();
      return -_num(_parseUnary());
    }
    return _parsePostfix();
  }

  dynamic _parsePostfix() {
    var v = _parsePrimary();
    while (true) {
      if (_peekOp('.')) {
        _take();
        final name = _take();
        if (name.type != _TokType.ident) {
          throw const FormatException('字段名必须为标识符');
        }
        v = _getField(v, name.value.toString());
      } else if (_peekOp('[')) {
        _take();
        final idx = _parseTernary();
        _expect(']');
        if (v is List) {
          if (idx is! num) throw const FormatException('索引必须是数字');
          final i = idx.toInt();
          if (i < 0 || i >= v.length) {
            throw FormatException('索引越界：$i，长度 ${v.length}');
          }
          v = v[i];
        } else if (v is Map) {
          final key = _stringify(idx);
          if (!v.containsKey(key)) throw FormatException('字段不存在：$key');
          v = v[key];
        } else if (v is String) {
          if (idx is! num) throw const FormatException('索引必须是数字');
          final i = idx.toInt();
          if (i < 0 || i >= v.length) {
            throw FormatException('索引越界：$i，长度 ${v.length}');
          }
          v = v[i];
        } else {
          throw FormatException('不能对 ${_stringify(v)} 做下标访问');
        }
      } else {
        break;
      }
    }
    return v;
  }

  dynamic _parsePrimary() {
    final t = _take();
    switch (t.type) {
      case _TokType.number:
      case _TokType.string:
        return t.value;
      case _TokType.variable:
        final varName = t.value.toString();
        if (!_vars.containsKey(varName)) {
          throw FormatException('未定义变量 $varName');
        }
        return _vars[varName];
      case _TokType.ident:
        final name = t.value.toString();
        if (name == 'true') return true;
        if (name == 'false') return false;
        if (name == 'null') return null;
        if (_peekOp('(')) {
          _take();
          final args = <dynamic>[];
          if (!_peekOp(')')) {
            args.add(_parseTernary());
            while (_peekOp(',')) {
              _take();
              args.add(_parseTernary());
            }
          }
          _expect(')');
          return _callFunction(name, args);
        }
        if (_vars.containsKey(name)) return _vars[name];
        return name;
      case _TokType.op:
        if (t.value == '(') {
          final v = _parseTernary();
          _expect(')');
          return v;
        }
        if (t.value == '[') {
          final list = <dynamic>[];
          if (!_peekOp(']')) {
            list.add(_parseTernary());
            while (_peekOp(',')) {
              _take();
              list.add(_parseTernary());
            }
          }
          _expect(']');
          return list;
        }
        throw FormatException('无法解析的符号 ${t.value}');
      case _TokType.eof:
        throw const FormatException('表达式意外结束');
    }
  }

  dynamic _callFunction(String name, List<dynamic> args) {
    Object? a(int i) => i < args.length ? args[i] : null;
    String reqString(String fn, int i) {
      final v = a(i);
      if (v is String) return v;
      throw FormatException('$fn 第 ${i + 1} 个参数必须是字符串，实际是 ${_typeName(v)}');
    }

    switch (name) {
      case 'contains':
        return reqString('contains', 0).contains(reqString('contains', 1));
      case 'starts':
        return reqString('starts', 0).startsWith(reqString('starts', 1));
      case 'ends':
        return reqString('ends', 0).endsWith(reqString('ends', 1));
      case 'len':
        final v = a(0);
        if (v is String) return v.length;
        if (v is List) return v.length;
        if (v is Map) return v.length;
        throw FormatException('len 参数必须是字符串/数组/对象，实际是 ${_typeName(v)}');
      case 'lower':
        return reqString('lower', 0).toLowerCase();
      case 'upper':
        return reqString('upper', 0).toUpperCase();
      case 'trim':
        return reqString('trim', 0).trim();
      case 'replace':
        return reqString('replace', 0)
            .replaceAll(reqString('replace', 1), reqString('replace', 2));
      case 'split':
        return reqString('split', 0).split(reqString('split', 1)).toList();
      case 'join':
        final list = a(0);
        if (list is! List) {
          throw FormatException('join 第一个参数必须是数组，实际是 ${_typeName(list)}');
        }
        return list.map(_stringify).join(reqString('join', 1));
      case 'num':
        if (a(0) is num) return a(0);
        return _num(a(0));
      case 'str':
        return _stringify(a(0));
      case 'json':
        final v = a(0);
        if (v is String) return _tryParse(v) ?? v;
        return v;
      case 'json_encode':
        return const JsonEncoder().convert(a(0));
      case 'get':
        final src = a(0);
        final key = _stringify(a(1));
        final fallback = args.length >= 3 ? a(2) : null;
        if (src is Map) {
          return src.containsKey(key) ? src[key] : fallback;
        }
        if (src is String) {
          final decoded = _tryParse(src);
          if (decoded is Map) {
            return decoded.containsKey(key) ? decoded[key] : fallback;
          }
        }
        return fallback;
      case 'type':
        final v = a(0);
        if (v is num) return 'number';
        if (v is String) return 'string';
        if (v is bool) return 'boolean';
        if (v is List) return 'list';
        if (v is Map) return 'object';
        return 'null';
      default:
        throw FormatException('未知函数 $name');
    }
  }

  Object? _getField(Object? v, String name) {
    if (v is Map) {
      if (!v.containsKey(name)) {
        throw FormatException(
            '字段不存在：$name（可用 get(${_stringify(v)}, \'$name\', 默认值) 带兜底）');
      }
      return v[name];
    }
    if (v is String) {
      final decoded = _tryParse(v);
      if (decoded is Map) {
        if (!decoded.containsKey(name)) {
          throw FormatException(
              '字段不存在：$name（可用 get(${_stringify(v)}, \'$name\', 默认值) 带兜底）');
        }
        return decoded[name];
      }
    }
    throw FormatException('不能对 ${_typeName(v)} 取字段 $name');
  }

  num _num(Object? v) {
    if (v is num) return v;
    if (v is String) {
      final t = v.trim();
      num? n;
      if (t.startsWith('0x') || t.startsWith('0X')) {
        n = num.tryParse(t);
      } else if (t.startsWith('0b') || t.startsWith('0B')) {
        n = int.tryParse(t.substring(2), radix: 2);
      } else if (t.startsWith('0o') || t.startsWith('0O')) {
        n = int.tryParse(t.substring(2), radix: 8);
      } else {
        n = num.tryParse(t);
      }
      if (n != null) return n;
      throw FormatException(
        '无法把字符串 "$v" 转成数字（支持十进制、0x 十六进制、0b 二进制、0o 八进制）',
      );
    }
    throw FormatException('无法把 ${_typeName(v)} 转成数字');
  }

  String _typeName(Object? v) {
    if (v == null) return 'null';
    if (v is num) return 'number';
    if (v is String) return 'string';
    if (v is bool) return 'boolean';
    if (v is List) return 'list';
    if (v is Map) return 'object';
    return v.runtimeType.toString();
  }

  bool _truthy(Object? v) {
    if (v == null) return false;
    if (v is bool) return v;
    if (v is num) return v != 0;
    if (v is String) return v.isNotEmpty;
    if (v is List) return v.isNotEmpty;
    if (v is Map) return v.isNotEmpty;
    return true;
  }

  bool _equals(Object? a, Object? b) {
    if (a is num && b is num) return a == b;
    if (a is String && b is String) return a == b;
    if (a is bool && b is bool) return a == b;
    if (a == null && b == null) return true;
    if (a is List && b is List) {
      if (a.length != b.length) return false;
      for (var i = 0; i < a.length; i++) {
        if (!_equals(a[i], b[i])) return false;
      }
      return true;
    }
    // 类型不同不相等，绝不隐式转换。
    return false;
  }

  Object? _tryParse(String s) {
    final t = s.trim();
    if (!(t.startsWith('{') || t.startsWith('['))) return null;
    try {
      return jsonDecode(t);
    } catch (_) {
      return null;
    }
  }

  static String _stringify(Object? v) {
    if (v == null) return '';
    if (v is String) return v;
    if (v is num || v is bool) return v.toString();
    return const JsonEncoder.withIndent('  ').convert(v);
  }
}
