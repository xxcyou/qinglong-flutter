import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:qinglong_flutter/features/ai/agent/tool_registry.dart';

/// 直接执行 shell_modify_range 内嵌的 Python 脚本，验证「行号漂移保护」。
///
/// 背景：AI 经常先看一遍行号、再调 shell_modify_range；中间若文件被别的
/// 编辑改过，行号就漂了，旧逻辑会照着错行号硬改，越改越乱。
/// 现在支持 expect（原文校验）和 find/endFind（文本锚点），这里锁住行为。
void main() {
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('modify_range_guard_');
  });

  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  Future<ProcessResult> runScript(
    String file, {
    required String action,
    required int start,
    required int end,
    String content = '',
    String expect = '',
    String find = '',
    String endFind = '',
    String position = 'before',
  }) {
    return Process.run('python3', [
      '-c',
      shellModifyRangeScript,
      file,
      action,
      '$start',
      '$end',
      content,
      '0',
      expect,
      find,
      endFind,
      position,
    ]);
  }

  String read(String file) => File(file).readAsStringSync();

  test('expect 不一致时拒绝写入，并返回实际内容', () async {
    final f = '${dir.path}/a.js';
    File(f).writeAsStringSync('line1\nline2\nline3\n');

    final r = await runScript(
      f,
      action: 'overwrite',
      start: 1,
      end: 1,
      content: 'NEW',
      expect: 'wrong text',
    );

    expect(r.exitCode, 0);
    expect(r.stdout.toString(), contains('__MODIFY_MISMATCH__'));
    expect(r.stdout.toString(), contains('1: line1'));
    expect(read(f), 'line1\nline2\nline3\n', reason: '校验失败时文件必须原样不动');
  });

  test('expect 一致时正常覆盖', () async {
    final f = '${dir.path}/a.js';
    File(f).writeAsStringSync('x\ny\nz\n');

    final r = await runScript(
      f,
      action: 'overwrite',
      start: 2,
      end: 2,
      content: 'Y',
      expect: 'y',
    );

    expect(r.exitCode, 0);
    expect(r.stdout.toString(), isNot(contains('__MODIFY_MISMATCH__')));
    expect(read(f), 'x\nY\nz\n');
  });

  test('find 锚点可纠正错误行号', () async {
    final f = '${dir.path}/a.js';
    File(f).writeAsStringSync('aaa\nbbb\nccc\n');

    final r = await runScript(
      f,
      action: 'overwrite',
      start: 99,
      end: 99,
      content: 'BBB',
      find: 'bbb',
    );

    expect(r.exitCode, 0);
    expect(r.stdout.toString(), isNot(contains('__MODIFY_MISMATCH__')));
    expect(read(f), 'aaa\nBBB\nccc\n');
  });

  test('endFind 锚点按文本定位多行块', () async {
    final f = '${dir.path}/a.js';
    File(f).writeAsStringSync('a\nSTART\nmid\nEND\nz\n');

    final r = await runScript(
      f,
      action: 'overwrite',
      start: 0,
      end: 0,
      content: 'X\nY',
      find: 'START',
      endFind: 'END',
    );

    expect(r.exitCode, 0);
    expect(r.stdout.toString(), isNot(contains('__MODIFY_MISMATCH__')));
    expect(read(f), 'a\nX\nY\nz\n');
  });

  test('insert + position=after 插在锚点后', () async {
    final f = '${dir.path}/a.js';
    File(f).writeAsStringSync('a\nb\nc\n');

    final r = await runScript(
      f,
      action: 'insert',
      start: 0,
      end: 0,
      content: 'NEW',
      find: 'b',
      position: 'after',
    );

    expect(r.exitCode, 0);
    expect(read(f), 'a\nb\nNEW\nc\n');
  });

  test('delete 配 expect 只删指定行', () async {
    final f = '${dir.path}/a.js';
    File(f).writeAsStringSync('a\nb\nc\n');

    final r = await runScript(
      f,
      action: 'delete',
      start: 2,
      end: 2,
      expect: 'b',
    );

    expect(r.exitCode, 0);
    expect(read(f), 'a\nc\n');
  });

  test('find 找不到锚点时拒绝写入', () async {
    final f = '${dir.path}/a.js';
    File(f).writeAsStringSync('a\nb\nc\n');

    final r = await runScript(
      f,
      action: 'overwrite',
      start: 1,
      end: 1,
      content: 'X',
      find: 'not-exist-anchor',
    );

    expect(r.exitCode, 0);
    expect(r.stdout.toString(), contains('__MODIFY_MISMATCH__'));
    expect(read(f), 'a\nb\nc\n');
  });
}
