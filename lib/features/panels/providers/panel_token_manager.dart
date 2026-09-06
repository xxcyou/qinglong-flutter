import 'dart:async';

import '../../../core/storage/secure_storage.dart';
import '../../../core/utils/logger.dart';
import '../api/auth_api.dart';
import '../models/panel_info.dart';

/// 面板令牌管家：主动续期 + 并发合流。
///
/// 之前"青龙登录超时"是这么来的：令牌只在请求收到 401 之后才补救，于是每次
/// 过期都要先牺牲一个请求；AI 那边一个批量任务里好几个工具同时撞上 401，
/// 又各自去登录，面板侧看到一串登录风暴。更糟的是 OpenAPI 令牌有效期本来
/// 就写在响应的 expiration 里，我们却没存。
///
/// 现在：每次取令牌前先看到期时间，快到了（默认剩余 < 5 分钟）就先换票再发
/// 请求；同一面板的并发换票共享一个 Future。401 兜底仍然保留，因为面板可能
/// 在服务端被清了会话。
class PanelTokenManager {
  PanelTokenManager._();

  /// 提前多久换票。青龙令牌通常 30 天，这个余量足够覆盖时钟偏差。
  static const _renewAhead = Duration(minutes: 5);

  static final Map<String, Future<String?>> _inflight = {};

  /// 取一个可用令牌：必要时先续期。
  static Future<String?> token(PanelInfo panel) async {
    final existing = await SecureStorage.readToken(panel.id);
    final expiry = await SecureStorage.readTokenExpiry(panel.id);
    final stale =
        expiry != null && expiry.difference(DateTime.now()) < _renewAhead;
    if (existing != null && existing.isNotEmpty && !stale) return existing;
    final renewed = await renew(panel);
    // 续期失败也别把手上这张票扔掉：它可能只是"到期时间存错了"，
    // 拿去试一次总比直接报错好。
    return renewed ?? existing;
  }

  /// 强制换票（401 兜底也走这里）。同一面板并发只发一次请求。
  static Future<String?> renew(PanelInfo panel) {
    final pending = _inflight[panel.id];
    if (pending != null) return pending;
    final future = _renew(panel).whenComplete(() => _inflight.remove(panel.id));
    _inflight[panel.id] = future;
    return future;
  }

  static Future<String?> _renew(PanelInfo panel) async {
    try {
      final result = panel.loginType == LoginType.account
          ? await _loginAccount(panel)
          : await _loginOpenApi(panel);
      if (result == null) return null;
      await SecureStorage.saveToken(
        panelId: panel.id,
        token: result.token,
        tokenType: result.tokenType,
        expiresAt: result.expiresAt,
      );
      return result.token;
    } catch (e) {
      // 凭据本身不进日志，只记类型。
      Logger.e('panel-token', '续期失败（${panel.loginType.label}）', e);
      return null;
    }
  }

  static Future<PanelConnectionResult?> _loginAccount(PanelInfo panel) async {
    final username = panel.username;
    final password =
        panel.password ?? await SecureStorage.readPassword(panel.id);
    if (username == null || username.isEmpty || password == null) return null;
    return AuthApi.loginWithPassword(
      baseUrl: panel.baseUrl,
      username: username,
      password: password,
    );
  }

  static Future<PanelConnectionResult?> _loginOpenApi(PanelInfo panel) async {
    final clientId = panel.clientId;
    final secret =
        panel.clientSecret ?? await SecureStorage.readClientSecret(panel.id);
    if (clientId == null ||
        clientId.isEmpty ||
        secret == null ||
        secret.isEmpty) {
      return null;
    }
    return AuthApi.loginWithOpenApi(
      baseUrl: panel.baseUrl,
      clientId: clientId,
      clientSecret: secret,
    );
  }
}
