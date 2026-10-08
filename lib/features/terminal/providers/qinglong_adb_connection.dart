import 'package:flutter_adb/adb_connection.dart';
import 'package:flutter_adb/adb_protocol.dart';
import 'package:flutter_adb/adb_stream.dart';

/// 修复 flutter_adb 1.0.0 的本地流 ID 分配问题。
///
/// 原 `AdbConnection.open()` 用 `openStreams.length + 1` 作为 localId，
/// 流关闭/复用时会重复使用旧 ID。旧流的 CLSE 若晚到，就会把新流误关掉，
/// 表现就是第一次 `shell,raw:` 正常，第二个命令报
/// “Stream open failed or refused by remote peer”。
///
/// 这里改用单调递增的 localId，保证新开流永远拿到未用过的 ID。
class QinglongAdbConnection extends AdbConnection {
  QinglongAdbConnection(super.ip, super.port, super.crypto, {super.verbose});

  int _nextLocalId = 1;

  @override
  Future<AdbStream> open(String destination) async {
    final localId = _nextLocalId++;
    final stream = AdbStream(localId, this);
    openStreams[localId] = stream;
    await sendMessage(AdbProtocol.generateOpen(localId, destination));
    if (await stream.onWriteReady.first
        .timeout(const Duration(seconds: 10), onTimeout: () => false)) {
      return stream;
    }
    throw Exception('Stream open failed or refused by remote peer');
  }
}
