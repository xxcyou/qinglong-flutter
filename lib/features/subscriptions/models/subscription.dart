/// 订阅（`/subscriptions`）的数据模型。
///
/// ## 订阅和定时任务是两码事
///
/// 定时任务是"到点跑一条命令"；订阅是"到点去某个仓库/文件把脚本拉下来，
/// 顺带按白名单自动建/删对应的定时任务"。青龙里 90% 的人装脚本都是靠订阅
/// （`ql repo` / `ql raw`），之前这个 APP 只能看任务、看脚本，
/// 拉新脚本还得回网页版——这一块补上，手机上才算能独立干活。
///
/// 字段名照抄面板库表（`back/data/subscription.ts`）：面板对请求体做
/// Joi 白名单校验，多一个字段就 400，所以序列化这边只能发它认识的那几个。
library;

/// 订阅类型。面板用它决定是 `ql repo` 还是 `ql raw`。
enum SubType {
  publicRepo('public-repo', '公开仓库', 'git clone 公开仓库，按白名单挑脚本'),
  privateRepo('private-repo', '私有仓库', '要凭据：SSH 私钥或用户名密码'),
  file('file', '单文件', '直接拉一个脚本文件（ql raw）');

  const SubType(this.wire, this.label, this.hint);

  /// 传给面板的原始值。
  final String wire;
  final String label;
  final String hint;

  static SubType parse(String? raw) {
    for (final t in SubType.values) {
      if (t.wire == raw) return t;
    }
    return SubType.publicRepo;
  }

  bool get isRepo => this != SubType.file;
}

/// 定时方式：cron 表达式或固定间隔。
enum SubScheduleKind {
  crontab('crontab', 'cron 表达式'),
  interval('interval', '固定间隔');

  const SubScheduleKind(this.wire, this.label);
  final String wire;
  final String label;

  static SubScheduleKind parse(String? raw) =>
      raw == 'interval' ? SubScheduleKind.interval : SubScheduleKind.crontab;
}

/// 私有仓库的凭据方式。
enum SubPullType {
  sshKey('ssh-key', 'SSH 私钥'),
  userPwd('user-pwd', '用户名 + 密码/Token');

  const SubPullType(this.wire, this.label);
  final String wire;
  final String label;

  static SubPullType? parse(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    for (final t in SubPullType.values) {
      if (t.wire == raw) return t;
    }
    return null;
  }
}

/// 面板的 `SubscriptionStatus` 枚举：0 运行中 / 1 空闲 / 2 已禁用 / 3 排队中。
enum SubStatus {
  running(0, '运行中'),
  idle(1, '空闲'),
  disabled(2, '已禁用'),
  queued(3, '排队中');

  const SubStatus(this.code, this.label);
  final int code;
  final String label;

  static SubStatus parse(dynamic raw) {
    final code = raw is num ? raw.toInt() : int.tryParse('$raw');
    for (final s in SubStatus.values) {
      if (s.code == code) return s;
    }
    return SubStatus.idle;
  }

  /// 运行中和排队中都算"正在忙"：都不该再点一次运行，都该允许停止。
  bool get isBusy => this == SubStatus.running || this == SubStatus.queued;
}

/// 固定间隔调度：`{type: 'days'|'hours'|'minutes'|'seconds', value: n}`。
///
/// 面板底层是 toad-scheduler 的 SimpleIntervalSchedule，单位只有这几种，
/// 而且 value 必须 ≥ 1（Joi 里写死了 min(1)）。
class SubInterval {
  const SubInterval({this.unit = 'days', this.value = 1});

  final String unit;
  final int value;

  static const units = <String, String>{
    'seconds': '秒',
    'minutes': '分钟',
    'hours': '小时',
    'days': '天',
  };

  String get unitLabel => units[unit] ?? unit;

  String get describe => '每 $value $unitLabel';

  factory SubInterval.fromJson(dynamic raw) {
    if (raw is Map) {
      final unit = raw['type']?.toString() ?? 'days';
      final v = raw['value'];
      final value = v is num ? v.toInt() : int.tryParse('$v') ?? 1;
      return SubInterval(
        unit: units.containsKey(unit) ? unit : 'days',
        value: value < 1 ? 1 : value,
      );
    }
    return const SubInterval();
  }

  Map<String, dynamic> toJson() => {
        'type': unit,
        'value': value < 1 ? 1 : value,
      };

  SubInterval copyWith({String? unit, int? value}) =>
      SubInterval(unit: unit ?? this.unit, value: value ?? this.value);
}

class Subscription {
  const Subscription({
    this.id,
    this.name = '',
    this.alias = '',
    this.type = SubType.publicRepo,
    this.url = '',
    this.branch = '',
    this.scheduleKind = SubScheduleKind.crontab,
    this.schedule = '',
    this.interval = const SubInterval(),
    this.whitelist = '',
    this.blacklist = '',
    this.dependences = '',
    this.extensions = '',
    this.subBefore = '',
    this.subAfter = '',
    this.proxy = '',
    this.autoAddCron = true,
    this.autoDelCron = true,
    this.pullType,
    this.pullOption = const {},
    this.status = SubStatus.idle,
    this.isDisabled = false,
    this.pid,
    this.logPath,
    this.command = '',
  });

  final int? id;

  /// 显示名。面板允许留空，留空时它自己拿 alias 当名字。
  final String name;

  /// 别名：日志目录名，面板要求必填且唯一。
  final String alias;

  final SubType type;
  final String url;
  final String branch;

  final SubScheduleKind scheduleKind;

  /// cron 表达式（scheduleKind 为 crontab 时有效）。
  final String schedule;

  /// 固定间隔（scheduleKind 为 interval 时有效）。
  final SubInterval interval;

  /// 白名单/黑名单/依赖/扩展名：都是面板那套逗号分隔的字符串，原样传。
  final String whitelist;
  final String blacklist;
  final String dependences;
  final String extensions;

  final String subBefore;
  final String subAfter;
  final String proxy;

  /// 拉完自动新建/删除对应的定时任务。面板默认都是 true。
  final bool autoAddCron;
  final bool autoDelCron;

  final SubPullType? pullType;

  /// 私有仓库凭据：`{private_key: ...}` 或 `{username, password}`。
  ///
  /// 这里存的是明文，只在编辑页与请求体里出现；日志与"发给 AI"一律不带它。
  final Map<String, dynamic> pullOption;

  final SubStatus status;
  final bool isDisabled;
  final int? pid;
  final String? logPath;

  /// 面板算好的执行命令（只读，展示用）。
  final String command;

  bool get isRunning => status.isBusy;

  /// 界面上那一行副标题：定时方式说人话。
  String get scheduleLabel => scheduleKind == SubScheduleKind.interval
      ? interval.describe
      : (schedule.trim().isEmpty ? '未设置定时' : schedule.trim());

  /// 列表里显示什么名字：name 留空就退到 alias，再退到 URL。
  String get displayName {
    if (name.trim().isNotEmpty) return name.trim();
    if (alias.trim().isNotEmpty) return alias.trim();
    return url.trim();
  }

  factory Subscription.fromJson(Map<String, dynamic> json) {
    bool asBool(dynamic v, {bool fallback = false}) {
      if (v == null) return fallback;
      if (v is bool) return v;
      if (v is num) return v != 0;
      final t = v.toString().trim().toLowerCase();
      if (t.isEmpty) return fallback;
      return t == '1' || t == 'true';
    }

    int? asInt(dynamic v) {
      if (v == null) return null;
      if (v is num) return v.toInt();
      return int.tryParse(v.toString().trim());
    }

    String asStr(dynamic v) => v == null ? '' : v.toString();

    return Subscription(
      id: asInt(json['id']),
      name: asStr(json['name']),
      alias: asStr(json['alias']),
      type: SubType.parse(json['type']?.toString()),
      url: asStr(json['url']),
      branch: asStr(json['branch']),
      scheduleKind: SubScheduleKind.parse(json['schedule_type']?.toString()),
      schedule: asStr(json['schedule']),
      interval: SubInterval.fromJson(json['interval_schedule']),
      whitelist: asStr(json['whitelist']),
      blacklist: asStr(json['blacklist']),
      dependences: asStr(json['dependences']),
      extensions: asStr(json['extensions']),
      subBefore: asStr(json['sub_before']),
      subAfter: asStr(json['sub_after']),
      proxy: asStr(json['proxy']),
      // 面板对这两个字段是"没设过就当 true"（isNil 判断），所以缺省给 true。
      autoAddCron: asBool(json['autoAddCron'], fallback: true),
      autoDelCron: asBool(json['autoDelCron'], fallback: true),
      pullType: SubPullType.parse(json['pull_type']?.toString()),
      pullOption: json['pull_option'] is Map
          ? Map<String, dynamic>.from(json['pull_option'] as Map)
          : const {},
      status: SubStatus.parse(json['status']),
      isDisabled: asBool(json['is_disabled']),
      pid: asInt(json['pid']),
      logPath: json['log_path']?.toString(),
      command: asStr(json['command']),
    );
  }

  /// 请求体：**只发面板 Joi 白名单里的字段**。
  ///
  /// 踩过的坑（定时任务那边同一个坑）：多带一个 `status` 或 `is_disabled`
  /// 就会被回 `"status" is not allowed`，而界面上只会显示一句
  /// "面板拒绝请求（HTTP 400）"，很难猜到是哪个字段。
  ///
  /// [withId] 为 true 时是 PUT（更新），面板要求带 id。
  Map<String, dynamic> toRequestBody({bool withId = false}) {
    final interval = scheduleKind == SubScheduleKind.interval;
    return {
      if (withId) 'id': id,
      'type': type.wire,
      'schedule_type': scheduleKind.wire,
      'alias': alias.trim(),
      'url': url.trim(),
      'name': name.trim(),
      // cron 与 interval 互斥：把没在用的那个发成空，
      // 否则面板会拿旧值继续排程（改成间隔了却还在按老 cron 跑）。
      'schedule': interval ? '' : schedule.trim(),
      if (interval) 'interval_schedule': this.interval.toJson(),
      'whitelist': whitelist.trim(),
      'blacklist': blacklist.trim(),
      'dependences': dependences.trim(),
      'extensions': extensions.trim(),
      'branch': type.isRepo ? branch.trim() : '',
      'sub_before': subBefore.trim(),
      'sub_after': subAfter.trim(),
      'proxy': proxy.trim(),
      'autoAddCron': autoAddCron,
      'autoDelCron': autoDelCron,
      if (type == SubType.privateRepo && pullType != null) ...{
        'pull_type': pullType!.wire,
        'pull_option': pullOption,
      },
    };
  }

  /// 本地预览的执行命令，规则抄面板的 `formatCommand`。
  ///
  /// 为什么要在本地再算一遍：新建的时候面板还没给 command，
  /// 用户最想确认的恰恰是"我这一堆白名单黑名单最后拼出来是什么"。
  String get previewCommand {
    final b = StringBuffer('SUB_ID=${id ?? '?'} ql ');
    String q(String v) => '"$v"';
    if (type == SubType.file) {
      b.write('raw ${q(url.trim())} ${q(proxy.trim())} '
          '${q('$autoAddCron')} ${q('$autoDelCron')}');
    } else {
      b.write('repo ${q(url.trim())} ${q(whitelist.trim())} '
          '${q(blacklist.trim())} ${q(dependences.trim())} '
          '${q(branch.trim())} ${q(extensions.trim())} ${q(proxy.trim())} '
          '${q('$autoAddCron')} ${q('$autoDelCron')}');
    }
    return b.toString();
  }

  /// 从 URL 猜一个合法别名。
  ///
  /// 面板要求 alias 必填且唯一，还会当目录名使。让小白用户自己想一个
  /// "唯一且只含安全字符"的名字不现实，所以默认按 URL 推：
  /// 仓库取 `owner_repo`，单文件取文件名（去扩展名），非法字符换成 `_`。
  ///
  /// 中文仓库名（`gitee.com/张三/我的脚本`）过一遍安全字符过滤会被削成空串，
  /// 那样界面只会顶一句"别名不能为空"，用户根本不知道该填什么。所以削空之后
  /// 退到 `sub_<URL 哈希>`：同一个地址永远得到同一个别名（改完再存不会每次
  /// 换一个日志目录），而且一定是合法的目录名。
  static String aliasFromUrl(String url, {SubType? type}) {
    var text = url.trim();
    if (text.isEmpty) return '';
    // 去掉协议、去掉 .git 尾巴、去掉 query。
    text = text.replaceAll(RegExp(r'^[a-zA-Z]+://'), '');
    text = text.replaceAll(RegExp(r'^git@'), '');
    final q = text.indexOf('?');
    if (q > 0) text = text.substring(0, q);
    text = text.replaceAll(RegExp(r'\.git/?$'), '');
    text = text.replaceAll(RegExp(r'/+$'), '');
    final parts = text
        .split(RegExp(r'[/:]'))
        .where((e) => e.trim().isNotEmpty)
        .toList();
    if (parts.isEmpty) return _aliasFromHash(url);
    List<String> picked;
    if (type == SubType.file) {
      // 单文件：文件名去扩展名。
      final file = parts.last;
      final dot = file.lastIndexOf('.');
      picked = [dot > 0 ? file.substring(0, dot) : file];
    } else {
      // 仓库：owner_repo（第一段通常是域名，跳过）。
      picked = parts.length >= 3
          ? [parts[parts.length - 2], parts.last]
          : [parts.last];
    }
    final alias = picked
        .join('_')
        .replaceAll(RegExp(r'[^A-Za-z0-9_-]+'), '_')
        .replaceAll(RegExp(r'_+'), '_')
        .replaceAll(RegExp(r'^_|_$'), '');
    return alias.isEmpty ? _aliasFromHash(url) : alias;
  }

  /// URL → `sub_xxxxxx`。FNV-1a 取低 24 位：够短、够稳、同址同名。
  static String _aliasFromHash(String url) {
    var hash = 0x811c9dc5;
    for (final code in url.trim().codeUnits) {
      hash ^= code;
      hash = (hash * 0x01000193) & 0xFFFFFFFF;
    }
    final short = (hash & 0xFFFFFF).toRadixString(16).padLeft(6, '0');
    return 'sub_$short';
  }

  Subscription copyWith({
    int? id,
    String? name,
    String? alias,
    SubType? type,
    String? url,
    String? branch,
    SubScheduleKind? scheduleKind,
    String? schedule,
    SubInterval? interval,
    String? whitelist,
    String? blacklist,
    String? dependences,
    String? extensions,
    String? subBefore,
    String? subAfter,
    String? proxy,
    bool? autoAddCron,
    bool? autoDelCron,
    SubPullType? Function()? pullType,
    Map<String, dynamic>? pullOption,
    SubStatus? status,
    bool? isDisabled,
    int? pid,
    String? logPath,
    String? command,
  }) {
    return Subscription(
      id: id ?? this.id,
      name: name ?? this.name,
      alias: alias ?? this.alias,
      type: type ?? this.type,
      url: url ?? this.url,
      branch: branch ?? this.branch,
      scheduleKind: scheduleKind ?? this.scheduleKind,
      schedule: schedule ?? this.schedule,
      interval: interval ?? this.interval,
      whitelist: whitelist ?? this.whitelist,
      blacklist: blacklist ?? this.blacklist,
      dependences: dependences ?? this.dependences,
      extensions: extensions ?? this.extensions,
      subBefore: subBefore ?? this.subBefore,
      subAfter: subAfter ?? this.subAfter,
      proxy: proxy ?? this.proxy,
      autoAddCron: autoAddCron ?? this.autoAddCron,
      autoDelCron: autoDelCron ?? this.autoDelCron,
      pullType: pullType != null ? pullType() : this.pullType,
      pullOption: pullOption ?? this.pullOption,
      status: status ?? this.status,
      isDisabled: isDisabled ?? this.isDisabled,
      pid: pid ?? this.pid,
      logPath: logPath ?? this.logPath,
      command: command ?? this.command,
    );
  }
}

/// 订阅日志目录里的一个文件（`/subscriptions/:id/logs`）。
class SubLogFile {
  const SubLogFile({required this.filename, this.directory = '', this.time});

  final String filename;
  final String directory;
  final DateTime? time;

  factory SubLogFile.fromJson(Map<String, dynamic> json) {
    final raw = json['time'];
    DateTime? time;
    if (raw is num) {
      time = DateTime.fromMillisecondsSinceEpoch(raw.toInt());
    } else if (raw != null) {
      time = DateTime.tryParse(raw.toString());
    }
    return SubLogFile(
      filename: json['filename']?.toString() ?? '',
      directory: json['directory']?.toString() ?? '',
      time: time,
    );
  }
}
