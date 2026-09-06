import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qinglong_flutter/core/network/dio_client.dart';
import 'package:qinglong_flutter/core/network/error_handler.dart';

/// "允许自签名 HTTPS" 那个开关以前是死的：值存进了 shared_preferences，
/// 但全项目没人读它——Dio 用默认 HttpClient，badCertificateCallback 从没设过。
/// 于是内网自签 HTTPS 的 LLM 网关（https://127.0.0.1:8766/v1，证书
/// CN=Deekseep Local API、自己签自己）打开开关也照样"获取不到模型 / 测试连通失败"。
void main() {
  test('开关默认关，且 Dio 装了自定义 adapter（不再是默认 HttpClient）', () {
    expect(DioClient.allowSelfSigned, isFalse);
    // 拿一次 dio 触发初始化。
    final dio = DioClient.dio;
    expect(
        dio.httpClientAdapter,
        isNot(isA<HttpClientAdapter>().having(
          (a) => a.runtimeType.toString(),
          'runtimeType',
          'HttpClientAdapter',
        )));
  });

  group('证书错误识别', () {
    test('Dart 的自签名握手失败要认出来', () {
      final e = DioException(
        requestOptions: RequestOptions(path: '/v1/models'),
        error: 'HandshakeException: Handshake error in client '
            '(OS Error: CERTIFICATE_VERIFY_FAILED: self signed certificate)',
        type: DioExceptionType.unknown,
      );
      expect(isCertError(e), isTrue);
      // 关键：不能再报成"网络异常"，那会让人去查网络和端口。
      expect(readableError(e), certHint);
      expect(readableError(e), contains('允许自签名 HTTPS'));
    });

    test('badCertificate 类型也给同一句提示', () {
      final e = DioException(
        requestOptions: RequestOptions(path: '/v1/models'),
        type: DioExceptionType.badCertificate,
      );
      expect(readableError(e), certHint);
    });

    test('普通网络错误不误判成证书问题', () {
      final e = DioException(
        requestOptions: RequestOptions(path: '/v1/models'),
        error: 'SocketException: Connection refused',
        type: DioExceptionType.unknown,
      );
      expect(isCertError(e), isFalse);
      expect(readableError(e), contains('网络异常'));
    });

    test('明文打在 TLS 端口上 → 提示改 https，而不是"网络异常：unknown"', () {
      // 现场：Base URL 填 http://127.0.0.1:8766/v1，而 8766 只说 TLS。
      // 服务端直接关连接，界面上只有一句"AI 请求失败：unknown"。
      final e = DioException(
        requestOptions: RequestOptions(
          path: 'http://127.0.0.1:8766/v1/chat/completions',
        ),
        error: 'HttpException: Connection closed before full header '
            'was received',
        type: DioExceptionType.unknown,
      );
      expect(isPlaintextToTlsError(e), isTrue);
      expect(readableError(e), schemeHint);
      expect(readableError(e), contains('https'));
    });

    test('https 上出同样的错不给这个提示（原因不同）', () {
      final e = DioException(
        requestOptions: RequestOptions(
          path: 'https://example.com/v1/chat/completions',
        ),
        error: 'HttpException: Connection closed before full header '
            'was received',
        type: DioExceptionType.unknown,
      );
      expect(isPlaintextToTlsError(e), isFalse);
    });

    test('超时不误判', () {
      final e = DioException(
        requestOptions: RequestOptions(path: '/v1/models'),
        type: DioExceptionType.receiveTimeout,
      );
      expect(isCertError(e), isFalse);
    });
  });
}
