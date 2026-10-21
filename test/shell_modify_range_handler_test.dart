import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qinglong_flutter/features/ai/agent/tool_registry.dart';

/// 走完整 Dart handler + 内嵌 Python 脚本，确认 expect/find 参数被正确传递，
/// 且校验失败时返回可读的实际内容而不是写入文件。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('coomi/proot');
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('modify_range_handler_');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method != 'exec') return null;
      final command = call.arguments['command'] as String;
      final args = (call.arguments['args'] as List)
          .map((e) => e.toString())
          .toList();
      final r = await Process.run(command, args);
      return {
        'code': r.exitCode,
        'stdout': r.stdout.toString(),
        'stderr': r.stderr.toString(),
      };
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  test('handler 透传 expect：不一致时返回实际内容且不写入', () async {
    final file = '${tmp.path}/a.js';
    File(file).writeAsStringSync('line1\nline2\nline3\n');
    final registry = QlToolRegistry(panelGetter: () => null);

    final out = await registry.execute(
      toolName: 'shell_modify_range',
      args: {
        'path': file,
        'action': 'overwrite',
        'start': 1,
        'end': 1,
        'content': 'NEW',
        'expect': 'not what is there',
      },
      confirm: true,
    );

    expect(out, contains('expect 与实际内容不一致'));
    expect(out, contains('1: line1'));
    expect(File(file).readAsStringSync(), 'line1\nline2\nline3\n');
  });

  test('handler 透传 find：行号漂移时按锚点改对位置', () async {
    final file = '${tmp.path}/a.js';
    File(file).writeAsStringSync('aaa\nbbb\nccc\n');
    final registry = QlToolRegistry(panelGetter: () => null);

    final out = await registry.execute(
      toolName: 'shell_modify_range',
      args: {
        'path': file,
        'action': 'overwrite',
        'start': 99,
        'end': 99,
        'content': 'BBB',
        'find': 'bbb',
      },
      confirm: true,
    );

    expect(out, contains('已按行覆盖'));
    expect(File(file).readAsStringSync(), 'aaa\nBBB\nccc\n');
  });
}
