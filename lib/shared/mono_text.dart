/// 等宽字体的唯一出口。
///
/// 以前全站散着 `fontFamily: 'monospace'`——那是交给系统兜底的家族名，
/// 在不同 ROM 上落到不同字体（这台机器上是 Roboto Mono，某些国产 ROM 上
/// 直接落回非等宽），于是代码、日志、cron 表达式在同一个 APP 里长得不一样。
/// 项目里已经打包了 JetBrains Mono，统一走它，系统 monospace 只做兜底。
library;

/// 打包进 APP 的等宽字体（见 pubspec.yaml 的 fonts 段）。
const String kMonoFamily = 'JetBrainsMono';

/// 字体缺字时的兜底链：中日韩字符 JetBrains Mono 没有，交给系统等宽。
const List<String> kMonoFallback = <String>['monospace'];
