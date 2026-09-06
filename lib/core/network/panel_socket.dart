import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// 青龙面板实时消息通道。
///
/// 面板后端用 SockJS（prefix `/api/ws`）向所有已认证客户端广播消息，
/// 手动运行脚本的输出走 `{"type":"manuallyRunScript","message":"..."}`。
/// SockJS 的 `/websocket` 子路径是「裸 WebSocket」：没有 `o`/`a[...]` 帧封装，
/// 收到的就是一条条 JSON 字符串，所以直接用 dart:io 的 WebSocket 即可，
/// 不需要引入额外依赖。
///
/// 认证方式：`?token=<面板 token>`（服务端比对 authConfigFile 里的
/// token 或 tokens[platform]），失败会先回一条
/// `{"type":"ping","message":"whyour"}` 然后立刻断开。
class PanelSocket {
  PanelSocket._(this._socket, this.messages);

  final WebSocket _socket;

  /// 面板推送的消息流（已解析成 Map）。
  final Stream<Map<String, dynamic>> messages;

  static String wsUrl(String baseUrl, String token) {
    var base = baseUrl.trim().replaceAll(RegExp(r'/+$'), '');
    if (base.startsWith('https://')) {
      base = 'wss://${base.substring('https://'.length)}';
    } else if (base.startsWith('http://')) {
      base = 'ws://${base.substring('http://'.length)}';
    }
    return '$base/api/ws/websocket?token=${Uri.encodeQueryComponent(token)}';
  }

  /// 建立连接。失败抛异常，调用方负责降级到「拉日志文件」方案。
  static Future<PanelSocket> connect({
    required String baseUrl,
    required String token,
    Duration timeout = const Duration(seconds: 8),
  }) async {
    final socket =
        await WebSocket.connect(wsUrl(baseUrl, token)).timeout(timeout);
    final controller = StreamController<Map<String, dynamic>>.broadcast();
    socket.listen(
      (dynamic raw) {
        final text = raw is List<int>
            ? utf8.decode(raw, allowMalformed: true)
            : raw.toString();
        if (text.isEmpty) return;
        try {
          final decoded = jsonDecode(text);
          if (decoded is Map<String, dynamic>) {
            controller.add(decoded);
          }
        } catch (_) {
          // 非 JSON 的心跳/杂讯直接忽略。
        }
      },
      onError: (Object _) {
        if (!controller.isClosed) controller.close();
      },
      onDone: () {
        if (!controller.isClosed) controller.close();
      },
      cancelOnError: true,
    );
    return PanelSocket._(socket, controller.stream);
  }

  Future<void> close() async {
    try {
      await _socket.close();
    } catch (_) {
      // 关闭失败无需处理。
    }
  }
}
