import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// 凭据安全存储。QL_TOKEN / LLM API Key 只允许放这里，不打日志。
class SecureStorage {
  SecureStorage._();

  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  static String _tokenKey(String panelId) => 'ql_token_$panelId';
  static String _tokenTypeKey(String panelId) => 'ql_token_type_$panelId';
  static String _passwordKey(String panelId) => 'ql_password_$panelId';
  static String _tokenExpiryKey(String panelId) => 'ql_token_exp_$panelId';
  static String _secretKey(String panelId) => 'ql_client_secret_$panelId';
  /// LLM API Key 的键。
  ///
  /// 空 providerId 指向老的全局键——多提供商之前只有一份配置，
  /// 迁移时要把它读出来复制到新槽位，所以这个键得留着能读。
  static String _llmKey([String providerId = '']) =>
      providerId.trim().isEmpty ? 'llm_api_key' : 'llm_api_key_$providerId';

  static Future<void> saveToken({
    required String panelId,
    required String token,
    required String tokenType,
    DateTime? expiresAt,
  }) async {
    await _storage.write(key: _tokenKey(panelId), value: token);
    await _storage.write(key: _tokenTypeKey(panelId), value: tokenType);
    if (expiresAt == null) {
      await _storage.delete(key: _tokenExpiryKey(panelId));
    } else {
      await _storage.write(
        key: _tokenExpiryKey(panelId),
        value: expiresAt.toIso8601String(),
      );
    }
  }

  /// 令牌到期时间。未知时返回 null（老数据没记过）。
  static Future<DateTime?> readTokenExpiry(String panelId) async {
    final raw = await _storage.read(key: _tokenExpiryKey(panelId));
    return raw == null ? null : DateTime.tryParse(raw);
  }

  static Future<String?> readToken(String panelId) async {
    return _storage.read(key: _tokenKey(panelId));
  }

  static Future<String?> readTokenType(String panelId) async {
    return _storage.read(key: _tokenTypeKey(panelId));
  }

  static Future<void> deleteToken(String panelId) async {
    await _storage.delete(key: _tokenKey(panelId));
    await _storage.delete(key: _tokenTypeKey(panelId));
    await _storage.delete(key: _tokenExpiryKey(panelId));
  }

  /// OpenAPI client_secret。跟密码同级，绝不能落在明文 prefs 里。
  static Future<String?> readClientSecret(String panelId) =>
      _storage.read(key: _secretKey(panelId));

  static Future<void> saveClientSecret(String panelId, String secret) =>
      _storage.write(key: _secretKey(panelId), value: secret);

  static Future<void> deleteClientSecret(String panelId) =>
      _storage.delete(key: _secretKey(panelId));

  static Future<String?> readPassword(String panelId) async {
    return _storage.read(key: _passwordKey(panelId));
  }

  static Future<void> savePassword(String panelId, String password) async {
    await _storage.write(key: _passwordKey(panelId), value: password);
  }

  static Future<void> deletePassword(String panelId) async {
    await _storage.delete(key: _passwordKey(panelId));
  }

  /// 抓包改写脚本表。脚本里经常写死签名密钥、token，所以整张表进安全存储。
  static Future<String?> readBrowserScripts() =>
      _storage.read(key: 'browser_intercept_scripts');

  static Future<void> saveBrowserScripts(String json) =>
      _storage.write(key: 'browser_intercept_scripts', value: json);

  static Future<void> saveLlmApiKey(
    String key, {
    String providerId = '',
  }) async {
    await _storage.write(key: _llmKey(providerId), value: key);
  }

  static Future<String?> readLlmApiKey({String providerId = ''}) async {
    return _storage.read(key: _llmKey(providerId));
  }

  static Future<void> deleteLlmApiKey({String providerId = ''}) async {
    await _storage.delete(key: _llmKey(providerId));
  }
}
