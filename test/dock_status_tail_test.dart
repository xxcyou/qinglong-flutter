import 'package:flutter_test/flutter_test.dart';
import 'package:qinglong_flutter/features/ai/floating/ai_dock_overlay.dart';

/// 悬浮球旁边那行字显示的是**思考原文的尾巴**，不是"正在思考"。
///
/// 用户原话："我希望他显示不是正在思考，而是思考内容也在那个字里面，
/// 不用长就滚动思考，短的就可以，主要用于看有没有思考进度而已。"
void main() {
  group('statusTail', () {
    test('换行和连续空白压成一个空格', () {
      expect(
        statusTail('先看日志\n\n然后   改脚本'),
        '先看日志 然后 改脚本',
      );
    });

    test('短文本原样返回', () {
      expect(statusTail('在查 cron 列表'), '在查 cron 列表');
    });

    test('长文本只留尾巴（最新写出来的那几个字）', () {
      final long = List.generate(50, (i) => '第$i段').join();
      final tail = statusTail(long, keep: 10);
      expect(tail.length, 10);
      expect(long.endsWith(tail), isTrue);
    });

    test('空白/空串 → 空串（这一行整体不显示）', () {
      expect(statusTail(''), isEmpty);
      expect(statusTail('   \n  '), isEmpty);
    });
  });
}
