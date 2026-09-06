import 'package:flutter_test/flutter_test.dart';
import 'package:qinglong_flutter/core/utils/cron_parser.dart';

void main() {
  test('5 段补秒', () {
    expect(CronParser.normalizeForQinglong('0 2 1 1 *'), '0 0 2 1 1 *');
  });

  test('6 段带 ? 补年段', () {
    expect(CronParser.normalizeForQinglong('0 1 0 2 9 ?'), '0 1 0 2 9 ? *');
  });

  test('一年一次的表达式必须瞬间算出', () {
    final sw = Stopwatch()..start();
    final next = CronParser.nextExecution('0 0 2 1 1 *');
    sw.stop();
    expect(next, isNotNull);
    expect(next!.month, 1);
    expect(next.day, 1);
    expect(next.hour, 2);
    expect(next.minute, 0);
    expect(sw.elapsedMilliseconds, lessThan(50));
  });

  test('5 段每分钟表达式按秒=0 对齐到下一分钟', () {
    final from = DateTime(2026, 5, 4, 10, 30, 15);
    final next = CronParser.nextExecution('* * * * *', after: from);
    expect(next, DateTime(2026, 5, 4, 10, 31, 0));
  });

  test('6 段每秒表达式', () {
    final from = DateTime(2026, 5, 4, 10, 30, 15);
    final next = CronParser.nextExecution('* * * * * *', after: from);
    expect(next, DateTime(2026, 5, 4, 10, 30, 16));
  });

  test('每天 8 点', () {
    final from = DateTime(2026, 5, 4, 10, 0, 0);
    final next = CronParser.nextExecution('0 8 * * *', after: from);
    expect(next, DateTime(2026, 5, 5, 8, 0, 0));
  });

  test('周一 9 点（日与周同时限定取或）', () {
    final from = DateTime(2026, 5, 4, 12, 0, 0);
    final next = CronParser.nextExecution('0 9 * * 1', after: from);
    expect(next!.weekday, DateTime.monday);
    expect(next.hour, 9);
  });

  test('7 段 Quartz 带 ? 可解析', () {
    final from = DateTime(2026, 5, 4, 12, 0, 0);
    final next = CronParser.nextExecution('0 1 0 2 9 ? *', after: from);
    expect(next, DateTime(2026, 9, 2, 0, 1, 0));
  });

  test('非法表达式', () {
    expect(CronParser.isValid('abc'), isFalse);
    expect(CronParser.isValid('99 * * * *'), isFalse);
    expect(CronParser.isValid('0 0 2 1 1 *'), isTrue);
  });

  test('a/n 语义：从 a 起每 n（0/3 分钟 = 0,3,6…）', () {
    final from = DateTime(2026, 9, 1, 2, 25, 30);
    final next = CronParser.nextExecution('0 0/3 * * * ?', after: from);
    expect(next, DateTime(2026, 9, 1, 2, 27, 0));
  });

  test('*/n 与 a/n 等价', () {
    final from = DateTime(2026, 9, 1, 2, 25, 30);
    expect(
      CronParser.nextExecution('0 */3 * * * ?', after: from),
      CronParser.nextExecution('0 0/3 * * * ?', after: from),
    );
  });

  test('a-b/n 仍受上界限制', () {
    final from = DateTime(2026, 9, 1, 2, 25, 30);
    final next = CronParser.nextExecution('0 0-10/3 * * * ?', after: from);
    expect(next, DateTime(2026, 9, 1, 3, 0, 0));
  });
}
