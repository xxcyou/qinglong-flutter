import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 上拉菜单的两条兜底规则。真机上这两条都翻过车：
///
/// 1. 系统的"上滑回桌面"会把触摸从 APP 手里抢走，up/cancel 永远不来，
///    `_dragging` 永久卡 true——把手不见、菜单点不动、随便一划就跳页。
///    所以必须有超时兜底。
/// 2. 长按把手时手抖能轻松蹭出三四十像素横向位移，只看绝对阈值会被判成
///    "横滑选页"，于是菜单一闪就被收掉。所以要求先真的往上拉出一段。
void main() {
  group('拖拽超时兜底', () {
    testWidgets('丢了 up 事件也能自己收尾', (tester) async {
      var dragging = false;
      var ended = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: _Probe(
            onStart: () => dragging = true,
            onEnd: () {
              dragging = false;
              ended++;
            },
          ),
        ),
      );
      final probe = tester.state<_ProbeState>(find.byType(_Probe));
      // 模拟：按下 → 移动（进入拖拽）→ 系统把手势抢走，再也没有事件
      final g = await tester.startGesture(const Offset(100, 500));
      await tester.pump();
      await g.moveTo(const Offset(100, 450));
      await tester.pump();
      expect(dragging, isTrue, reason: '往上拉了 50 像素，应该进入拖拽');
      // 不发 up，直接等：看门狗必须自己收尾
      await tester.pump(const Duration(milliseconds: 750));
      expect(ended, 1, reason: '超时后必须强制 _endDrag');
      expect(dragging, isFalse);
      probe.cancelTimer();
      await g.cancel();
    });
  });

  group('横滑选页门槛', () {
    test('长按手抖：横向 45 像素但几乎没往上拉 → 不算横滑', () {
      expect(_movedX(pulled: 6, dx: 45), isFalse);
    });

    test('纯上拉：拉了 200 像素、横向漂 30 → 不算横滑', () {
      expect(_movedX(pulled: 200, dx: 30), isFalse);
    });

    test('真横滑：拉出 80 像素后横向走 120 → 算横滑', () {
      expect(_movedX(pulled: 80, dx: 120), isTrue);
    });

    test('边界：刚好 40 / 48 都不算（要严格大于）', () {
      expect(_movedX(pulled: 40, dx: 48), isFalse);
      expect(_movedX(pulled: 41, dx: 49), isTrue);
    });
  });
}

/// 与 home_shell 里同一份判定：拉出 > 40 且横移 > 48。
bool _movedX({required double pulled, required double dx}) =>
    pulled > 40 && dx.abs() > 48;

class _Probe extends StatefulWidget {
  const _Probe({required this.onStart, required this.onEnd});

  final VoidCallback onStart;
  final VoidCallback onEnd;

  @override
  State<_Probe> createState() => _ProbeState();
}

class _ProbeState extends State<_Probe> {
  bool _dragging = false;
  double? _startY;
  Timer? _timer;

  void cancelTimer() => _timer?.cancel();

  void _arm() {
    _timer?.cancel();
    _timer = Timer(const Duration(milliseconds: 700), () {
      if (!_dragging) return;
      _end();
    });
  }

  void _end() {
    _timer?.cancel();
    _timer = null;
    if (!_dragging) return;
    setState(() => _dragging = false);
    widget.onEnd();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      // 这个用例只验超时逻辑，用 opaque 让测试里的指针事件一定送得到。
      behavior: HitTestBehavior.opaque,
      onPointerDown: (e) => _startY = e.position.dy,
      onPointerMove: (e) {
        final startY = _startY;
        if (startY == null) return;
        if (!_dragging && startY - e.position.dy > 8) {
          setState(() => _dragging = true);
          widget.onStart();
          _arm();
          return;
        }
        if (_dragging) _arm();
      },
      onPointerUp: (_) => _end(),
      onPointerCancel: (_) => _end(),
      child: const SizedBox.expand(),
    );
  }
}
