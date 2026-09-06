import 'package:flutter_test/flutter_test.dart';
import 'package:qinglong_flutter/features/ai/agent/tool_registry.dart';

void main() {
  group('QlToolRegistry confirm guard', () {
    test('write tool without confirm is rejected', () async {
      final registry = QlToolRegistry(panelGetter: () => null);
      expect(
        () => registry.execute(
          toolName: 'cron_create',
          args: const {
            'name': 'test',
            'command': 'task x.py now',
            'schedule': '30 8 * * *',
          },
          confirm: false,
        ),
        throwsA(isA<ConfirmRequiredException>()),
      );
    });

    test('read tool without confirm does not throw confirm error', () async {
      final registry = QlToolRegistry(panelGetter: () => null);
      // read 工具会继续走到“未选择面板”，但不应抛出 ConfirmRequiredException。
      expect(
        () => registry.execute(
          toolName: 'system_info',
          args: const {},
          confirm: false,
        ),
        throwsA(isA<StateError>()),
      );
    });
  });
}