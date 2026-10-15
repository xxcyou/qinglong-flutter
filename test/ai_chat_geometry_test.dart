import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:qinglong_flutter/features/ai/floating/ai_dock_overlay.dart';
import 'package:qinglong_flutter/features/ai/floating/ai_dock_provider.dart';

void main() {
  const media = MediaQueryData(
    size: Size(400, 800),
    padding: EdgeInsets.only(top: 24, bottom: 24),
  );

  test('键盘没弹起时聊天窗保持原生几何', () {
    const dock = AiDockState(
      expanded: true,
      wx: 0.5,
      wy: 0.5,
      ww: 1,
      wh: 0.5,
    );
    final geometry = aiChatGeometry(media, dock);
    // 800 - (30 + 30) = 740 可用高；wy=0.5 -> top=400，wh=0.5 -> h=370。
    expect(geometry.rect.top, 400);
    expect(geometry.rect.height, 370);
  });

  test('输入框本来就在键盘上方时，聊天窗不动', () {
    const dock = AiDockState(
      expanded: true,
      wx: 0.5,
      wy: 0,
      ww: 1,
      wh: 0.5,
    );
    final mediaWithIme = media.copyWith(
      viewInsets: const EdgeInsets.only(bottom: 300),
    );
    final geometry = aiChatGeometry(mediaWithIme, dock);
    // top=30，h=370，bottom=400 < 键盘顶边 492：不应移动。
    expect(geometry.rect.top, 30);
    expect(geometry.rect.height, 370);
    expect(geometry.rect.bottom, 400);
  });

  test('输入框会被键盘盖住时，聊天窗只上移遮挡所需距离', () {
    const dock = AiDockState(
      expanded: true,
      wx: 0.5,
      wy: 0.5,
      ww: 1,
      wh: 0.5,
    );
    final mediaWithIme = media.copyWith(
      viewInsets: const EdgeInsets.only(bottom: 300),
    );
    final geometry = aiChatGeometry(mediaWithIme, dock);
    // 原 bottom=770，键盘顶边=492，需上移 278；上方空间够，h 不变。
    expect(geometry.rect.height, 370);
    expect(geometry.rect.bottom, 492);
  });

  test('上方空间不够时，聊天窗上移到顶后收窄到键盘上方', () {
    const dock = AiDockState(
      expanded: true,
      wx: 0.5,
      wy: 0,
      ww: 1,
      wh: 0.95,
    );
    final mediaWithIme = media.copyWith(
      viewInsets: const EdgeInsets.only(bottom: 300),
    );
    final geometry = aiChatGeometry(mediaWithIme, dock);
    // top=30，h≈703，bottom≈733；只能上移到 30，剩余 241 从底部收掉。
    expect(geometry.rect.top, 30);
    expect(geometry.rect.bottom, 492);
  });

  test('键盘收起后恢复原始几何', () {
    const dock = AiDockState(
      expanded: true,
      wx: 0.5,
      wy: 0.5,
      ww: 1,
      wh: 0.5,
    );
    final withIme = aiChatGeometry(
      media.copyWith(viewInsets: const EdgeInsets.only(bottom: 300)),
      dock,
    );
    final withoutIme = aiChatGeometry(media, dock);
    expect(withIme.rect, isNot(withoutIme.rect));
    expect(withoutIme.rect.top, 400);
    expect(withoutIme.rect.height, 370);
  });


  test('球旁边的状态文字没有内容时不占原生触摸区域', () {
    final rect = aiBubbleStatusLabelRect(
      size: const Size(400, 800),
      left: 344,
      top: 300,
      status: '',
    );
    expect(rect, isNull);
  });

  test('球在右边时状态文字向左展开，矩形包住整行', () {
    final rect = aiBubbleStatusLabelRect(
      size: const Size(400, 800),
      left: 344,
      top: 300,
      status: '正在调用工具',
    )!;
    expect(rect.right, lessThanOrEqualTo(344));
    expect(rect.width, 220);
    expect(rect.height, 18);
  });

  test('球在左边时状态文字向右展开', () {
    final rect = aiBubbleStatusLabelRect(
      size: const Size(400, 800),
      left: 0,
      top: 300,
      status: '思考中',
    )!;
    expect(rect.left, 60);
    expect(rect.width, 220);
  });

  test('侧面空间太窄放不下状态文字时不额外占区域', () {
    final rect = aiBubbleStatusLabelRect(
      size: const Size(100, 800),
      left: 50,
      top: 300,
      status: '思考中',
    );
    expect(rect, isNull);
  });
}
