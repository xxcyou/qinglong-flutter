import 'package:flutter_test/flutter_test.dart';
import 'package:qinglong_flutter/core/local_shell/shell_lock.dart';
import 'package:qinglong_flutter/features/ai/models/agent_event.dart';
import 'package:qinglong_flutter/features/ai/models/agent_task_plan.dart';
import 'package:qinglong_flutter/features/ai/models/ai_message.dart';
import 'package:qinglong_flutter/features/ai/models/canvas_result_bus.dart';
import 'package:qinglong_flutter/features/ai/models/canvas_window.dart';
import 'package:qinglong_flutter/features/browser/browser_engine.dart';
import 'package:qinglong_flutter/features/browser/models/browser_models.dart';

void main() {
  group('ShellLock', () {
    test('同一资源串行执行：交叉不会发生', () async {
      final trace = <String>[];
      Future<void> job(String tag, int delayMs) => ShellLock.run(
            ShellLock.terminal,
            () async {
              trace.add('$tag-start');
              await Future<void>.delayed(Duration(milliseconds: delayMs));
              trace.add('$tag-end');
            },
            label: tag,
          );

      // 故意让先来的那个慢：没有锁的话 b-start 会插在 a-end 前面。
      await Future.wait([job('a', 40), job('b', 1)]);
      expect(trace, ['a-start', 'a-end', 'b-start', 'b-end']);
      // 跑完不留痕迹，否则后面的调用会一直以为有人占着。
      expect(ShellLock.depthOf(ShellLock.terminal), 0);
      expect(ShellLock.holderOf(ShellLock.terminal), '');
    });

    test('不同资源互不阻塞', () async {
      final trace = <String>[];
      await Future.wait([
        ShellLock.run(ShellLock.terminal, () async {
          await Future<void>.delayed(const Duration(milliseconds: 30));
          trace.add('terminal');
        }),
        ShellLock.run(ShellLock.browser, () async {
          trace.add('browser');
        }),
      ]);
      // 浏览器那条不用等终端，所以它先记完。
      expect(trace, ['browser', 'terminal']);
    });

    test('前面的活抛异常也要放闸，不能把后面的人永远关在门外', () async {
      final first = ShellLock.run(
        ShellLock.terminal,
        () async => throw StateError('boom'),
      );
      await expectLater(first, throwsStateError);
      final second = await ShellLock.run(ShellLock.terminal, () async => 'ok');
      expect(second, 'ok');
    });

    test('排队超时给出明确错误，而不是无限挂着', () async {
      final slow = ShellLock.run(
        ShellLock.terminal,
        () => Future<void>.delayed(const Duration(milliseconds: 120)),
        label: '慢命令',
      );
      await expectLater(
        ShellLock.run(
          ShellLock.terminal,
          () async => 'never',
          timeout: const Duration(milliseconds: 10),
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('慢命令'),
          ),
        ),
      );
      await slow;
    });
  });

  group('BrowserEngine.isLocalTarget', () {
    test('本地路径都认得出来', () {
      expect(BrowserEngine.isLocalTarget('/workspace/a.html'), isTrue);
      expect(BrowserEngine.isLocalTarget('file:///data/x.html'), isTrue);
      expect(BrowserEngine.isLocalTarget('./demo.html'), isTrue);
      expect(BrowserEngine.isLocalTarget('~/report.htm'), isTrue);
      expect(BrowserEngine.isLocalTarget('workspace/game.html'), isTrue);
    });

    test('网址和搜索词不能被误判成本地文件', () {
      expect(BrowserEngine.isLocalTarget('https://example.com/a.html'), isFalse);
      expect(BrowserEngine.isLocalTarget('example.com'), isFalse);
      expect(BrowserEngine.isLocalTarget('青龙 面板 怎么装'), isFalse);
      expect(BrowserEngine.isLocalTarget(''), isFalse);
    });
  });

  group('CanvasWindow.layoutFor', () {
    test('rect 优先于 position', () {
      const canvas = AiCanvas(
        id: 'c1',
        title: 't',
        html: '<p>1</p>',
        position: 'center',
        rect: [0.1, 0.2, 0.3, 0.4],
      );
      final geo = CanvasWindow.layoutFor(canvas, 0);
      expect(geo.x, closeTo(0.1, 1e-9));
      expect(geo.y, closeTo(0.2, 1e-9));
      expect(geo.w, closeTo(0.3, 1e-9));
      expect(geo.h, closeTo(0.4, 1e-9));
    });

    test('预设位置：full 铺满，right 靠右半边', () {
      const full = AiCanvas(id: 'c', title: 't', html: 'x', position: 'full');
      final g1 = CanvasWindow.layoutFor(full, 0);
      expect(g1.w, 1);
      expect(g1.h, 1);

      const right = AiCanvas(id: 'c', title: 't', html: 'x', position: '右');
      final g2 = CanvasWindow.layoutFor(right, 0);
      expect(g2.x, closeTo(0.52, 1e-9));
    });

    test('没给位置时按序号错开，避免多个窗口精准重叠', () {
      const canvas = AiCanvas(id: 'c', title: 't', html: 'x');
      final a = CanvasWindow.layoutFor(canvas, 0);
      final b = CanvasWindow.layoutFor(canvas, 1);
      expect(b.x, greaterThan(a.x));
      expect(b.y, greaterThan(a.y));
    });
  });

  group('CanvasBus', () {
    tearDown(() {
      for (final w in CanvasBus.windows) {
        CanvasBus.unregister(w);
      }
    });

    test('点对点投递', () {
      final got = <String>[];
      CanvasBus.register('game', (from, payload) => got.add('$from:$payload'));
      CanvasBus.register('pad', (_, __) => fail('不该收到'));
      expect(CanvasBus.post('pad', 'game', 'up'), 1);
      expect(got, ['pad:up']);
    });

    test('广播不回给自己', () {
      final got = <String>[];
      CanvasBus.register('game', (from, p) => got.add('game<-$p'));
      CanvasBus.register('score', (from, p) => got.add('score<-$p'));
      expect(CanvasBus.post('game', '*', 'over'), 1);
      expect(got, ['score<-over']);
    });

    test('目标窗口没开就地丢掉，返回 0', () {
      expect(CanvasBus.post('game', 'nobody', 'x'), 0);
    });
  });

  group('AiCanvas 序列化', () {
    test('窗口字段能来回', () {
      const canvas = AiCanvas(
        id: 'c9',
        title: '成绩板',
        html: '<b>1</b>',
        window: 'score',
        chromeless: true,
        position: 'topright',
        rect: [0.5, 0, 0.5, 0.3],
      );
      final back = AiCanvas.fromJson(canvas.toJson());
      expect(back.window, 'score');
      expect(back.chromeless, isTrue);
      expect(back.position, 'topright');
      expect(back.rect, [0.5, 0, 0.5, 0.3]);
    });
  });

  group('AiChatMessage.sendError', () {
    test('发送失败的消息带着错误来回，并且标记为未发送', () {
      final msg = AiChatMessage(
        role: 'user',
        content: '帮我看看日志',
        createdAt: DateTime(2026, 1, 1),
      ).copyWith(sendError: '连不上 AI 服务');
      expect(msg.failedToSend, isTrue);
      final back = AiChatMessage.fromJson(msg.toJson());
      expect(back.sendError, '连不上 AI 服务');
      expect(back.failedToSend, isTrue);
      expect(back.content, '帮我看看日志');
    });

    test('正常消息不带错误字段', () {
      final msg = AiChatMessage(
        role: 'user',
        content: 'hi',
        createdAt: DateTime(2026, 1, 1),
      );
      expect(msg.failedToSend, isFalse);
      expect(msg.toJson().containsKey('sendError'), isFalse);
    });
  });

  group('CapturedRequest 请求头/响应头', () {
    test('头字段进 toJson，空的不占位', () {
      final r = CapturedRequest(
        id: 1,
        method: 'POST',
        url: 'https://example.com/api',
        kind: 'fetch',
        requestHeaders: 'content-type: application/json',
        startedAt: DateTime(2026, 1, 1),
      );
      final json = r.toJson();
      expect(json['requestHeaders'], 'content-type: application/json');
      expect(json.containsKey('responseHeaders'), isFalse);

      r.responseHeaders = 'set-cookie: a=1';
      expect(r.toJson()['responseHeaders'], 'set-cookie: a=1');
    });
  });

  group('AgentEventKind.answer', () {
    test('正文事件能存能取', () {
      const event = AgentEvent(
        kind: AgentEventKind.answer,
        message: '我先看一眼日志',
        result: '我先看一眼日志',
        turn: 2,
      );
      final back = AgentEvent.fromJson(event.toJson());
      expect(back.kind, AgentEventKind.answer);
      expect(back.message, '我先看一眼日志');
      expect(back.turn, 2);
    });
  });
}
