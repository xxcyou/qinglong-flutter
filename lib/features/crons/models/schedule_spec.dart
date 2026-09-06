import '../../../core/utils/cron_parser.dart';

/// 可视化定时的几种"积木"。每种模式只暴露它真正需要的几个旋钮，
/// 用户点几下就出一条合法 cron，不用背 5 段语法。
enum ScheduleMode {
  everyNMinutes('每 N 分钟'),
  hourly('每小时'),
  daily('每天'),
  weekly('每周'),
  monthly('每月'),
  interval('每 N 小时'),
  custom('自定义表达式');

  const ScheduleMode(this.label);

  final String label;
}

/// 可视化定时的取值集合 → cron 表达式。
class ScheduleSpec {
  const ScheduleSpec({
    this.mode = ScheduleMode.daily,
    this.minute = 30,
    this.hour = 8,
    this.everyMinutes = 30,
    this.everyHours = 6,
    this.weekdays = const {1},
    this.monthDay = 1,
    this.custom = '',
  });

  final ScheduleMode mode;

  /// 分钟位（0-59），除 everyNMinutes 外都用它。
  final int minute;

  /// 小时位（0-23），daily/weekly/monthly 用。
  final int hour;

  final int everyMinutes;
  final int everyHours;

  /// cron 的星期取值 0=周日 … 6=周六。
  final Set<int> weekdays;
  final int monthDay;

  /// custom 模式下的原始表达式。
  final String custom;

  ScheduleSpec copyWith({
    ScheduleMode? mode,
    int? minute,
    int? hour,
    int? everyMinutes,
    int? everyHours,
    Set<int>? weekdays,
    int? monthDay,
    String? custom,
  }) {
    return ScheduleSpec(
      mode: mode ?? this.mode,
      minute: minute ?? this.minute,
      hour: hour ?? this.hour,
      everyMinutes: everyMinutes ?? this.everyMinutes,
      everyHours: everyHours ?? this.everyHours,
      weekdays: weekdays ?? this.weekdays,
      monthDay: monthDay ?? this.monthDay,
      custom: custom ?? this.custom,
    );
  }

  /// 生成 5 段 cron（提交时再由 CronParser 补秒）。
  String get expression {
    switch (mode) {
      case ScheduleMode.everyNMinutes:
        return '*/$everyMinutes * * * *';
      case ScheduleMode.hourly:
        return '$minute * * * *';
      case ScheduleMode.interval:
        return '$minute */$everyHours * * *';
      case ScheduleMode.daily:
        return '$minute $hour * * *';
      case ScheduleMode.weekly:
        final days =
            weekdays.isEmpty ? '1' : (weekdays.toList()..sort()).join(',');
        return '$minute $hour * * $days';
      case ScheduleMode.monthly:
        return '$minute $hour $monthDay * *';
      case ScheduleMode.custom:
        return custom.trim();
    }
  }

  /// 人话预览（含下一次执行时间）。
  String describe() {
    final expr = expression;
    if (expr.isEmpty) return '请填写表达式';
    if (!CronParser.isValid(expr)) return '表达式不合法';
    return CronParser.describe(expr);
  }

  bool get isValid => CronParser.isValid(expression);

  /// 反解已有表达式，让"编辑"也能落回可视化积木；
  /// 认不出来的形状就老实退回自定义模式，不猜。
  static ScheduleSpec parse(String raw) {
    final expr = raw.trim();
    if (expr.isEmpty) return const ScheduleSpec();
    var parts = expr.split(RegExp(r'\s+'));
    // 6 段（含秒）先去掉秒位，只要它是固定值。
    if (parts.length >= 6 && parts.first == '0') {
      parts = parts.sublist(1);
    }
    if (parts.length != 5) {
      return ScheduleSpec(mode: ScheduleMode.custom, custom: expr);
    }
    final [minute, hour, day, month, weekday] = parts;
    int? asInt(String v) => int.tryParse(v);

    bool wild(String v) => v == '*' || v == '?';

    // */N * * * *
    final minStep = RegExp(r'^\*/(\d+)$').firstMatch(minute);
    if (minStep != null &&
        wild(hour) &&
        wild(day) &&
        wild(month) &&
        wild(weekday)) {
      return ScheduleSpec(
        mode: ScheduleMode.everyNMinutes,
        everyMinutes: int.parse(minStep.group(1)!),
      );
    }
    final m = asInt(minute);
    if (m == null) return ScheduleSpec(mode: ScheduleMode.custom, custom: expr);

    // M */N * * *
    final hourStep = RegExp(r'^\*/(\d+)$').firstMatch(hour);
    if (hourStep != null && wild(day) && wild(month) && wild(weekday)) {
      return ScheduleSpec(
        mode: ScheduleMode.interval,
        minute: m,
        everyHours: int.parse(hourStep.group(1)!),
      );
    }
    // M * * * *
    if (wild(hour) && wild(day) && wild(month) && wild(weekday)) {
      return ScheduleSpec(mode: ScheduleMode.hourly, minute: m);
    }
    final h = asInt(hour);
    if (h == null) return ScheduleSpec(mode: ScheduleMode.custom, custom: expr);

    // M H * * D[,D]
    if (wild(day) && wild(month) && !wild(weekday)) {
      final days = <int>{};
      for (final piece in weekday.split(',')) {
        final v = asInt(piece);
        if (v == null || v < 0 || v > 7) {
          return ScheduleSpec(mode: ScheduleMode.custom, custom: expr);
        }
        days.add(v == 7 ? 0 : v);
      }
      return ScheduleSpec(
        mode: ScheduleMode.weekly,
        minute: m,
        hour: h,
        weekdays: days,
      );
    }
    // M H D * *
    if (!wild(day) && wild(month) && wild(weekday)) {
      final d = asInt(day);
      if (d != null && d >= 1 && d <= 31) {
        return ScheduleSpec(
          mode: ScheduleMode.monthly,
          minute: m,
          hour: h,
          monthDay: d,
        );
      }
    }
    // M H * * *
    if (wild(day) && wild(month) && wild(weekday)) {
      return ScheduleSpec(mode: ScheduleMode.daily, minute: m, hour: h);
    }
    return ScheduleSpec(mode: ScheduleMode.custom, custom: expr);
  }
}
