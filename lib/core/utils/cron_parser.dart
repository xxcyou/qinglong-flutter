/// 简易 Cron 解析器，支持 5 段（分 时 日 月 周）、6 段（秒 分 时 日 月 周）
/// 与 7 段 Quartz（秒 分 时 日 月 周 年）。
///
/// 用于表单实时校验与“下次执行时间”预览。仅覆盖青龙常用语法：
/// `*`、`*/n`、`a`、`a,b`、`a-b`、`a-b/n`，以及 `?`（视为 `*`）。
///
/// 时间一律按**本地时区**推算。
class CronParser {
  CronParser._();

  /// 「下次执行」结果缓存：同一表达式在同一分钟内只算一次。
  /// 列表滚动时 tile 会反复 build，没有缓存就会反复推算。
  static final Map<String, _CachedNext> _nextCache = {};
  static const int _cacheLimit = 256;

  static bool isValid(String expr) {
    final parts = expr.trim().split(RegExp(r'\s+'));
    if (parts.length < 5 || parts.length > 7) return false;
    try {
      return _parse(parts) != null;
    } catch (_) {
      return false;
    }
  }

  /// 青龙 cron：
  /// - 标准 6 段 = 秒 分 时 日 月 周；
  /// - Quartz 7 段 = 秒 分 时 日 月 周 年，允许 `?`（QL 现有任务就是这么存的）。
  /// 用户/老版本常用 5 段（分 时 日 月 周），直接提交会被面板 400。
  ///
  /// 统一规则：
  /// - 5 段补前导 0 秒；
  /// - 带 `?` 的必须是 Quartz 7 段，6 段带 `?` 会自动补第 7 段 `*`；
  /// - 不带 `?` 的 6 段保持标准 6 段。
  static String normalizeForQinglong(String expr) {
    var parts = expr.trim().split(RegExp(r'\s+'));
    if (parts.length == 5) {
      // "0 2 1 1 *" -> "0 0 2 1 1 *"
      parts = ['0', ...parts];
    }
    final hasQuestion = parts.any((f) => f.contains('?'));
    if (hasQuestion && parts.length == 6) {
      // "0 1 0 2 9 ?" -> "0 1 0 2 9 ? *"（补年段，否则 QL 解析 400）
      parts = [...parts, '*'];
    }
    return parts.join(' ');
  }

  static DateTime? nextExecution(String expr, {DateTime? after}) {
    if (after != null) return _computeNext(expr, after);
    // 无显式起点时走缓存：key 精确到分钟，跨分钟自动失效。
    final now = DateTime.now();
    final bucket = DateTime(
      now.year,
      now.month,
      now.day,
      now.hour,
      now.minute,
    );
    final cached = _nextCache[expr];
    if (cached != null && cached.bucket == bucket) return cached.value;
    final value = _computeNext(expr, now);
    if (_nextCache.length >= _cacheLimit) _nextCache.clear();
    _nextCache[expr] = _CachedNext(bucket, value);
    return value;
  }

  static String describe(String expr) {
    if (!isValid(expr)) return 'Cron 表达式不合法';
    final next = nextExecution(expr);
    if (next == null) return 'Cron 表达式合法（近期无匹配）';
    String two(int v) => v.toString().padLeft(2, '0');
    return '下次执行：${next.year}-${two(next.month)}-${two(next.day)} '
        '${two(next.hour)}:${two(next.minute)}';
  }

  /// 逐字段推进求解，不做逐秒暴力扫描。
  ///
  /// 早先的实现是「每次 +1 秒再匹配，上限 5 年」：遇到 `0 0 2 1 1 *`
  /// 这种一年只跑一次的表达式要循环上千万次，直接把 UI 线程卡住。
  static DateTime? _computeNext(String expr, DateTime from) {
    final _CronFields? f;
    try {
      f = _parse(expr.trim().split(RegExp(r'\s+')));
    } catch (_) {
      return null;
    }
    if (f == null) return null;

    // 从下一秒开始找，避免返回“现在”。
    var t = DateTime(
      from.year,
      from.month,
      from.day,
      from.hour,
      from.minute,
      from.second,
    ).add(const Duration(seconds: 1));

    final limitYear = from.year + 6;
    // 每一步都让时间前进，且多数步进是「跳到下一天/下一月」，
    // guard 只是兜底防死循环。
    for (var guard = 0; guard < 200000; guard++) {
      if (t.year > limitYear) return null;
      if (f.years != null && !f.years!.contains(t.year)) {
        t = DateTime(t.year + 1);
        continue;
      }
      if (!f.months.contains(t.month)) {
        t = t.month == 12
            ? DateTime(t.year + 1)
            : DateTime(t.year, t.month + 1);
        continue;
      }
      if (!_dayMatches(t, f)) {
        t = DateTime(t.year, t.month, t.day).add(const Duration(days: 1));
        continue;
      }
      if (!f.hours.contains(t.hour)) {
        t = DateTime(t.year, t.month, t.day, t.hour)
            .add(const Duration(hours: 1));
        continue;
      }
      if (!f.minutes.contains(t.minute)) {
        t = DateTime(t.year, t.month, t.day, t.hour, t.minute)
            .add(const Duration(minutes: 1));
        continue;
      }
      if (!f.seconds.contains(t.second)) {
        t = t.add(const Duration(seconds: 1));
        continue;
      }
      return t;
    }
    return null;
  }

  /// cron 的日/周语义：两者都限定时取「或」（任一命中即执行）。
  static bool _dayMatches(DateTime t, _CronFields f) {
    // DateTime.weekday：周一=1…周日=7；cron：周日=0…周六=6。
    final dow = t.weekday % 7;
    final dayOk = f.days.contains(t.day);
    final dowOk = f.weekdays.contains(dow);
    if (f.dayRestricted && f.weekdayRestricted) return dayOk || dowOk;
    if (f.dayRestricted) return dayOk;
    if (f.weekdayRestricted) return dowOk;
    return true;
  }

  static _CronFields? _parse(List<String> parts) {
    if (parts.length < 5 || parts.length > 7) return null;
    // 统一补齐成 [秒, 分, 时, 日, 月, 周, (年)]
    final p = parts.length == 5 ? <String>['0', ...parts] : <String>[...parts];
    return _CronFields(
      seconds: _parseField(p[0], 0, 59),
      minutes: _parseField(p[1], 0, 59),
      hours: _parseField(p[2], 0, 23),
      days: _parseField(p[3], 1, 31),
      months: _parseField(p[4], 1, 12),
      weekdays: _parseWeekday(p[5]),
      years: p.length == 7 ? _parseYear(p[6]) : null,
      dayRestricted: !_isWildcard(p[3]),
      weekdayRestricted: !_isWildcard(p[5]),
    );
  }

  static bool _isWildcard(String field) => field == '*' || field == '?';

  static Set<int>? _parseYear(String field) {
    if (_isWildcard(field)) return null;
    return _parseField(field, 1970, 2999);
  }

  static Set<int> _parseField(String field, int min, int max) {
    if (_isWildcard(field)) {
      return {for (var i = min; i <= max; i++) i};
    }
    final result = <int>{};
    for (final piece in field.split(',')) {
      final stepMatch = RegExp(r'^(.+)/(\d+)$').firstMatch(piece);
      if (stepMatch != null) {
        final base = stepMatch.group(1)!;
        final step = int.parse(stepMatch.group(2)!);
        if (step <= 0) throw const FormatException('step must be positive');
        // cron 的 `a/n` = 从 a 起到上界每 n（不是只有 a 一个值）。
        // `a-b/n` 才受 b 限制。少了这一步，`0/3` 会被解析成只有 0，
        // 「下次执行」就会算到几小时后。
        final hasRange = base.contains('-');
        final range = _parseRange(base, min, max);
        final from = range.$1;
        final to = hasRange || _isWildcard(base) ? range.$2 : max;
        for (var n = from; n <= to; n += step) {
          result.add(n);
        }
      } else {
        final range = _parseRange(piece, min, max);
        for (var n = range.$1; n <= range.$2; n++) {
          result.add(n);
        }
      }
    }
    if (result.isEmpty) throw const FormatException('empty field');
    return result;
  }

  static (int, int) _parseRange(String text, int min, int max) {
    if (_isWildcard(text)) return (min, max);
    final dash = text.split('-');
    final start = dash[0] == '*' ? min : int.parse(dash[0]);
    final end =
        dash.length > 1 ? (dash[1] == '*' ? max : int.parse(dash[1])) : start;
    if (start < min || end > max || start > end) {
      throw const FormatException('range out of bounds');
    }
    return (start, end);
  }

  static Set<int> _parseWeekday(String field) {
    // 周字段：0-6，允许 7 表示周日。
    return _parseField(field.replaceAll('7', '0'), 0, 6);
  }
}

class _CronFields {
  const _CronFields({
    required this.seconds,
    required this.minutes,
    required this.hours,
    required this.days,
    required this.months,
    required this.weekdays,
    required this.years,
    required this.dayRestricted,
    required this.weekdayRestricted,
  });

  final Set<int> seconds;
  final Set<int> minutes;
  final Set<int> hours;
  final Set<int> days;
  final Set<int> months;
  final Set<int> weekdays;
  final Set<int>? years;
  final bool dayRestricted;
  final bool weekdayRestricted;
}

class _CachedNext {
  const _CachedNext(this.bucket, this.value);

  final DateTime bucket;
  final DateTime? value;
}
