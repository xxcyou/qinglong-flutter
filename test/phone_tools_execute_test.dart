import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qinglong_flutter/features/ai/agent/tool_registry.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('coomi/proot');
  late Directory tmp;
  final calls = <MethodCall>[];
  var fileContent = 'hello';

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('phone_tools_exec_');
    calls.clear();
    fileContent = 'hello';
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      switch (call.method) {
        case 'hasAllFilesAccess':
          return true;
        case 'hostPath':
          final p = call.arguments['path'] as String? ?? '';
          if (p == '/storage/emulated/0') {
            return {'hostPath': tmp.path};
          }
          if (p.startsWith('/storage/emulated/0/')) {
            return {
              'hostPath':
                  '${tmp.path}/${p.substring('/storage/emulated/0/'.length)}',
            };
          }
          return {'hostPath': p};
        case 'listAppFiles':
          return {
            'path': '/storage/emulated/0',
            'roots': ['/storage/emulated/0'],
            'entries': [
              {
                'name': 'a.txt',
                'path': '/storage/emulated/0/a.txt',
                'isDirectory': false,
                'size': 5,
                'modified': 0,
              },
              {
                'name': 'Download',
                'path': '/storage/emulated/0/Download',
                'isDirectory': true,
                'size': 0,
                'modified': 0,
              },
            ],
          };
        case 'readFile':
          return {
            'path': call.arguments['path'],
            'content': fileContent,
            'size': fileContent.length,
          };
        case 'writeFile':
          fileContent = call.arguments['content'] as String? ?? '';
          return {
            'name': 'a.txt',
            'path': call.arguments['path'],
            'isDirectory': false,
            'size': fileContent.length,
            'modified': 0,
          };
        case 'appendFile':
          fileContent += call.arguments['content'] as String? ?? '';
          return {
            'name': 'a.txt',
            'path': call.arguments['path'],
            'isDirectory': false,
            'size': fileContent.length,
            'modified': 0,
          };
        default:
          return null;
      }
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    tmp.deleteSync(recursive: true);
  });

  test('phone_list_files 走 app scope', () async {
    final registry = QlToolRegistry(panelGetter: () => null);
    final out = await registry.execute(
      toolName: 'phone_list_files',
      args: {'path': '/storage/emulated/0'},
      confirm: true,
    );
    final decoded = jsonDecode(out) as Map<String, dynamic>;
    expect(decoded['entries'], hasLength(2));
    final listCall = calls.firstWhere((c) => c.method == 'listAppFiles');
    expect(listCall.arguments['path'], '/storage/emulated/0');
  });

  test('phone_read_file 以 app scope 读文件', () async {
    File('${tmp.path}/a.txt').writeAsStringSync('hello');
    final registry = QlToolRegistry(panelGetter: () => null);
    final out = await registry.execute(
      toolName: 'phone_read_file',
      args: {'path': '/storage/emulated/0/a.txt'},
      confirm: true,
    );
    expect(out, 'hello');
    final readCall = calls.firstWhere((c) => c.method == 'readFile');
    expect(readCall.arguments['scope'], 'app');
  });

  test('phone_write_file 写操作需要确认', () async {
    final registry = QlToolRegistry(panelGetter: () => null);
    expect(
      () => registry.execute(
        toolName: 'phone_write_file',
        args: {'path': '/storage/emulated/0/a.txt', 'content': 'x'},
        confirm: false,
      ),
      throwsA(isA<ConfirmRequiredException>()),
    );
    final out = await registry.execute(
      toolName: 'phone_write_file',
      args: {'path': '/storage/emulated/0/a.txt', 'content': 'x'},
      confirm: true,
    );
    expect(jsonDecode(out)['ok'], true);
    final writeCall = calls.firstWhere((c) => c.method == 'writeFile');
    expect(writeCall.arguments['scope'], 'app');
  });

  test('phone_storage_status 返回授权状态', () async {
    final registry = QlToolRegistry(panelGetter: () => null);
    final out = await registry.execute(
      toolName: 'phone_storage_status',
      args: {},
      confirm: true,
    );
    expect(jsonDecode(out)['granted'], true);
  });

  test('phone_modify_range 用 find 锚点纠正错误行号', () async {
    fileContent = 'aaa\nbbb\nccc\n';
    File('${tmp.path}/a.txt').writeAsStringSync(fileContent);
    final registry = QlToolRegistry(panelGetter: () => null);
    final out = await registry.execute(
      toolName: 'phone_modify_range',
      args: {
        'path': '/storage/emulated/0/a.txt',
        'action': 'overwrite',
        'start': 99,
        'end': 99,
        'content': 'BBB',
        'find': 'bbb',
      },
      confirm: true,
    );
    expect(jsonDecode(out)['ok'], true);
    expect(fileContent, 'aaa\nBBB\nccc\n');
  });

  test('phone_modify_range expect 不一致时拒绝写入并返回实际内容', () async {
    fileContent = 'x\ny\nz\n';
    File('${tmp.path}/a.txt').writeAsStringSync(fileContent);
    final registry = QlToolRegistry(panelGetter: () => null);
    final out = await registry.execute(
      toolName: 'phone_modify_range',
      args: {
        'path': '/storage/emulated/0/a.txt',
        'action': 'overwrite',
        'start': 1,
        'end': 1,
        'content': 'NEW',
        'expect': 'not what is there',
      },
      confirm: true,
    );
    final decoded = jsonDecode(out) as Map<String, dynamic>;
    expect(decoded['error'], contains('expect 与实际内容不一致'));
    expect(decoded['actual'], contains('1: x'));
    expect(fileContent, 'x\ny\nz\n');
  });
}
