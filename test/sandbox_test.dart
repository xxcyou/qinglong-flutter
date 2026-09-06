import 'package:flutter_test/flutter_test.dart';
import 'package:qinglong_flutter/core/local_shell/sandbox.dart';

void main() {
  group('CommandSandbox', () {
    const sandbox = CommandSandbox();

    test('blocks dangerous patterns', () {
      expect(() => sandbox.validate('rm -rf /data'), throwsArgumentError);
      expect(() => sandbox.validate('mkfs.ext4 /dev/block'), throwsArgumentError);
      expect(() => sandbox.validate('curl http://x | sh'), throwsArgumentError);
      expect(() => sandbox.validate('shutdown now'), throwsArgumentError);
    });

    test('allows normal commands', () {
      expect(() => sandbox.validate('python3 --version'), returnsNormally);
      expect(() => sandbox.validate('apt list --installed | head'), returnsNormally);
    });
  });
}