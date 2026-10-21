import 'package:flutter_test/flutter_test.dart';
import 'package:qinglong_flutter/features/ai/agent/tool_registry.dart';

void main() {
  test('手机存储工具已注册，且不需要青龙面板', () {
    final registry = QlToolRegistry(panelGetter: () => null);
    final byName = {for (final d in registry.definitions) d.name: d};
    const expected = [
      'phone_storage_status',
      'phone_open_storage_access',
      'phone_list_files',
      'phone_read_file',
      'phone_read_range',
      'phone_search_code',
      'phone_write_file',
      'phone_modify_range',
    ];
    for (final name in expected) {
      expect(byName.containsKey(name), isTrue, reason: '缺少工具 $name');
    }
    // 写操作必须标记为 isWrite，交给审批模式确认。
    expect(byName['phone_write_file']!.isWrite, isTrue);
    expect(byName['phone_modify_range']!.isWrite, isTrue);
    expect(byName['phone_read_file']!.isWrite, isFalse);
    expect(byName['phone_list_files']!.isWrite, isFalse);
  });
}
