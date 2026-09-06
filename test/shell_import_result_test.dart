import 'package:flutter_test/flutter_test.dart';
import 'package:qinglong_flutter/core/local_shell/proot_bridge.dart';

/// 导入结果的解析约定：取消不是错误，部分失败要能分别报出来。
void main() {
  test('取消：canceled=true 且没有文件', () {
    final r = ShellImportResult.fromMap({'canceled': true, 'files': []});
    expect(r.canceled, isTrue);
    expect(r.files, isEmpty);
    expect(r.failed, isEmpty);
    expect(r.isEmpty, isTrue);
  });

  test('全部成功：文件条目正常解析', () {
    final r = ShellImportResult.fromMap({
      'canceled': false,
      'files': [
        {
          'name': 'a.js',
          'path': '/workspace/a.js',
          'isDirectory': false,
          'size': 12,
          'modified': 1700000000000,
        },
      ],
    });
    expect(r.canceled, isFalse);
    expect(r.files.single.name, 'a.js');
    expect(r.files.single.path, '/workspace/a.js');
    expect(r.files.single.size, 12);
    expect(r.failed, isEmpty);
  });

  test('部分失败：成功的留着，失败的单独带原因', () {
    final r = ShellImportResult.fromMap({
      'canceled': false,
      'files': [
        {
          'name': 'ok.txt',
          'path': '/workspace/ok.txt',
          'isDirectory': false,
          'size': 3,
          'modified': 0,
        },
      ],
      'failed': [
        {'name': 'bad.bin', 'error': '无法读取所选文件'},
      ],
    });
    expect(r.files.length, 1);
    expect(r.failed.single.name, 'bad.bin');
    expect(r.failed.single.error, '无法读取所选文件');
  });

  test('原生少给字段也不炸（failed 缺 error 时给兜底文案）', () {
    final r = ShellImportResult.fromMap({
      'files': null,
      'failed': [
        {'name': 'x'},
      ],
    });
    expect(r.canceled, isFalse);
    expect(r.files, isEmpty);
    expect(r.failed.single.error, '未知错误');
  });
}
