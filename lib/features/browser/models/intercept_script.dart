/// 一条抓包脚本。
///
/// 只有四个字段是有意义的：名字、开关、代码、命中次数。没有 when/then 这种
/// 结构——匹配和改写都在代码里，脚本自己 `if` 就完了。这样 AI 写起来自然，
/// 用户看起来也和常见抓包工具一致。
class InterceptScript {
  InterceptScript({
    required this.id,
    required this.name,
    required this.code,
    this.enabled = true,
    this.hits = 0,
    this.error = '',
  });

  final int id;
  final String name;
  final String code;
  final bool enabled;

  /// 命中次数：脚本真的改动了某个包才算一次（页面侧比对前后快照后上报）。
  /// 这是判断"脚本到底生效了没"的唯一硬证据，所以不落盘、每次进程重开归零。
  int hits;

  /// 页面侧编译/运行报的错。同样不落盘。
  String error;

  bool get hasCode => code.trim().isNotEmpty;

  /// 代码里出现的钩子，给列表页显示。
  String get hooks {
    final has = <String>[];
    if (RegExp(r'function\s+onRequest\b').hasMatch(code) ||
        RegExp(r'onRequest\s*=').hasMatch(code)) {
      has.add('请求');
    }
    if (RegExp(r'function\s+onResponse\b').hasMatch(code) ||
        RegExp(r'onResponse\s*=').hasMatch(code)) {
      has.add('响应');
    }
    return has.isEmpty ? '没有钩子' : has.join(' + ');
  }

  String get summary {
    final parts = <String>['#$id $name', hooks];
    if (!enabled) parts.add('已停用');
    if (hits > 0) parts.add('命中 $hits 次');
    if (error.isNotEmpty) parts.add('出错：$error');
    return parts.join(' ｜ ');
  }

  /// 明显写错的情况先拦下来，省得注入进页面才报错。
  /// 真正的语法检查在页面侧（`new Function`），错了会通过 `serr` 报回来。
  String validate() {
    if (name.trim().isEmpty) return '脚本要有名字';
    if (!hasCode) return '脚本是空的';
    if (!RegExp(r'\bonRequest\b').hasMatch(code) &&
        !RegExp(r'\bonResponse\b').hasMatch(code)) {
      return '代码里既没有 onRequest 也没有 onResponse，不会被调用';
    }
    return '';
  }

  InterceptScript copyWith({
    String? name,
    String? code,
    bool? enabled,
  }) {
    return InterceptScript(
      id: id,
      name: name ?? this.name,
      code: code ?? this.code,
      enabled: enabled ?? this.enabled,
      hits: hits,
      error: error,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'code': code,
        'enabled': enabled,
      };

  /// 推给页面的形态：命中次数和报错是页面往回报的，不用送过去。
  Map<String, dynamic> toPageJson() => {
        'id': id,
        'name': name,
        'enabled': enabled,
        'code': code,
      };

  factory InterceptScript.fromJson(
    Map<String, dynamic> json, {
    int? fallbackId,
  }) {
    return InterceptScript(
      id: (json['id'] as num?)?.toInt() ?? fallbackId ?? 0,
      name: json['name']?.toString() ?? '未命名脚本',
      code: json['code']?.toString() ?? '',
      enabled: json['enabled'] != false,
    );
  }
}
