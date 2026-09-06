enum LoginType {
  account,
  openapi,
}

extension LoginTypeLabel on LoginType {
  String get label => switch (this) {
        LoginType.account => '账号密码',
        LoginType.openapi => 'OpenAPI',
      };
}

class PanelInfo {
  const PanelInfo({
    required this.id,
    required this.name,
    required this.baseUrl,
    required this.loginType,
    this.username,
    this.password,
    this.clientId,
    this.clientSecret,
    this.isDefault = false,
    this.createTime,
  });

  final String id;
  final String name;
  final String baseUrl;
  final LoginType loginType;
  final String? username;
  final String? password;
  final String? clientId;
  final String? clientSecret;
  final bool isDefault;
  final DateTime? createTime;

  /// 去掉尾斜杠的站点根地址。
  String get siteUrl => baseUrl.trim().replaceAll(RegExp(r'/+$'), '');

  /// 规范化后的 API 根地址。
  ///
  /// 青龙有两套完全独立的鉴权：
  /// - `/api/*` 认 JWT，只有 `/api/user/login` 才发；
  /// - `/open/*` 认 OpenAPI 应用令牌（UUID 形状），只有
  ///   `/open/auth/token` 才发。
  ///
  /// 两者不能混用：拿 OpenAPI 的 UUID 去请求 `/api/crons` 会被回
  /// `jwt malformed`（因为它根本不是 JWT）。所以前缀必须跟着登录方式走。
  String get apiBaseUrl =>
      loginType == LoginType.openapi ? '$siteUrl/open' : '$siteUrl/api';

  PanelInfo copyWith({
    String? id,
    String? name,
    String? baseUrl,
    LoginType? loginType,
    String? Function()? username,
    String? Function()? password,
    String? Function()? clientId,
    String? Function()? clientSecret,
    bool? isDefault,
    DateTime? createTime,
  }) {
    return PanelInfo(
      id: id ?? this.id,
      name: name ?? this.name,
      baseUrl: baseUrl ?? this.baseUrl,
      loginType: loginType ?? this.loginType,
      username: username != null ? username() : this.username,
      password: password != null ? password() : this.password,
      clientId: clientId != null ? clientId() : this.clientId,
      clientSecret: clientSecret != null ? clientSecret() : this.clientSecret,
      isDefault: isDefault ?? this.isDefault,
      createTime: createTime ?? this.createTime,
    );
  }
}

class PanelConnectionResult {
  const PanelConnectionResult({
    required this.token,
    required this.tokenType,
    this.expiresAt,
  });

  final String token;
  final String tokenType;

  /// 令牌到期时间（面板返回 expiration 时才有）。
  ///
  /// 有了它就能在过期前主动换票，而不是等一个请求先失败再补救——
  /// 用户看到的"登录超时"基本都是这一步缺失造成的。
  final DateTime? expiresAt;
}
