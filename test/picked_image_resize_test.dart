import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qinglong_flutter/shared/local_file_picker.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('coomi/proot');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  test('图片附件读取时先经原生解码缩图，再以 PNG data URI 返回', () async {
    final dir = await Directory.systemTemp.createTemp('picked_image_test');
    final file = File('${dir.path}/fake.jpg');
    await file.writeAsBytes(Uint8List.fromList([1, 2, 3, 4, 5]));

    final decoded = Uint8List.fromList(
        [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 9, 8, 7]);

    messenger.setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'hostPath':
          return <String, Object>{'hostPath': file.path, 'size': 5};
        case 'decodeImage':
          final maxDimension =
              (call.arguments as Map?)?['maxDimension'] as int? ?? 0;
          expect(maxDimension, 1280);
          return decoded;
        default:
          return null;
      }
    });

    addTearDown(() async {
      messenger.setMockMethodCallHandler(channel, null);
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    final attachment = await readPickedImage(PickedLocalFile(
      path: '/workspace/fake.jpg',
      name: 'fake.jpg',
      content: '',
      size: 5,
      truncated: false,
      scope: 'shell',
      mime: 'image/jpeg',
    ));

    expect(attachment, isNotNull);
    expect(attachment!.mime, 'image/png');
    expect(attachment.dataUri, startsWith('data:image/png;base64,'));
    final encoded = attachment.dataUri.split(',').last;
    expect(base64Decode(encoded), decoded);
  });
}
