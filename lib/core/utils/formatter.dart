import 'package:intl/intl.dart';

/// 统一时间格式化。
class Formatter {
  Formatter._();

  static String dateTime(DateTime? dt) {
    if (dt == null) return '-';
    return DateFormat('yyyy-MM-dd HH:mm:ss').format(dt.toLocal());
  }

  /// token 计数的智能单位。
  ///
  /// 界面上到处都是 token 数字，六位数字挤在一个小药丸里既看不清也对不齐。
  /// 规则按"看一眼就知道量级"来定：
  /// 1000 以内原样；1k–10k 留一位小数；10k 以上取整；到百万换 M。
  /// 把服务端的 prompt_tokens 与缓存命中量换算成“上下文真实占用”。
  ///
  /// 网关口径分两种：
  /// - DeepSeek 风格：prompt_tokens 已包含 cache_hit，再加就重复统计；
  /// - Anthropic 兼容风格：prompt_tokens 只算未命中/新增，context 需要补上 cache_read。
  /// 这里用命中量是否大于 prompt_tokens 作为自适应判断，避免界面越加越大。
  static int serverContextTokens(int prompt, int cached) =>
      cached > prompt ? prompt + cached : (prompt > 0 ? prompt : cached);

  static String tokens(int value) {
    if (value < 0) return '0';
    if (value < 1000) return '$value';
    if (value < 10000) return '${(value / 1000).toStringAsFixed(1)}k';
    if (value < 1000000) return '${(value / 1000).round()}k';
    final m = value / 1000000;
    return '${m < 10 ? m.toStringAsFixed(2) : m.toStringAsFixed(1)}M';
  }

  /// 次数：上千也换单位，免得"1273 次"把一行挤爆。
  static String count(int value) {
    if (value < 1000) return '$value';
    if (value < 10000) return '${(value / 1000).toStringAsFixed(1)}k';
    return '${(value / 1000).round()}k';
  }

  static String durationMs(int? ms) {
    if (ms == null) return '-';
    if (ms < 1000) return '$ms ms';
    return '${(ms / 1000).toStringAsFixed(1)} s';
  }
}
