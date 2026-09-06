import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/error_handler.dart';
import '../../../core/storage/secure_storage.dart';
import '../../../shared/glass_scaffold.dart';
import '../api/auth_api.dart';
import '../models/panel_info.dart';

class PanelEditPage extends ConsumerStatefulWidget {
  const PanelEditPage({super.key, this.panel});

  final PanelInfo? panel;

  @override
  ConsumerState<PanelEditPage> createState() => _PanelEditPageState();
}

class _PanelEditPageState extends ConsumerState<PanelEditPage> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _nameController;
  late final TextEditingController _baseUrlController;
  late final TextEditingController _usernameController;
  late final TextEditingController _passwordController;
  late final TextEditingController _clientIdController;
  late final TextEditingController _clientSecretController;
  late LoginType _loginType;
  bool _testing = false;
  bool _saving = false;
  String? _connectionHint;

  bool get _isEdit => widget.panel != null;

  @override
  void initState() {
    super.initState();
    final p = widget.panel;
    _nameController = TextEditingController(text: p?.name ?? '');
    _baseUrlController = TextEditingController(text: p?.baseUrl ?? '');
    _usernameController = TextEditingController(text: p?.username ?? '');
    _passwordController = TextEditingController();
    _clientIdController = TextEditingController(text: p?.clientId ?? '');
    _clientSecretController =
        TextEditingController(text: p?.clientSecret ?? '');
    _loginType = p?.loginType ?? LoginType.account;
  }

  @override
  void dispose() {
    _nameController.dispose();
    _baseUrlController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    _clientIdController.dispose();
    _clientSecretController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GlassScaffold(
      title: _isEdit ? '编辑面板' : '添加面板',
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 44),
          children: [
            TextFormField(
              controller: _nameController,
              decoration: const InputDecoration(labelText: '名称 *'),
              validator: (v) =>
                  (v == null || v.trim().isEmpty) ? '请输入面板名称' : null,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _baseUrlController,
              decoration: const InputDecoration(
                labelText: 'BaseURL *',
                hintText: 'http://192.168.1.10:5700',
                helperText: '支持 http/https，不要带尾斜杠',
              ),
              keyboardType: TextInputType.url,
              validator: (v) {
                final value = v?.trim() ?? '';
                if (value.isEmpty) return '请输入面板地址';
                if (!value.startsWith('http://') &&
                    !value.startsWith('https://')) {
                  return '地址必须以 http:// 或 https:// 开头';
                }
                return null;
              },
            ),
            const SizedBox(height: 12),
            SegmentedButton<LoginType>(
              segments: LoginType.values
                  .map((t) => ButtonSegment(value: t, label: Text(t.label)))
                  .toList(),
              selected: {_loginType},
              onSelectionChanged: (set) {
                setState(() => _loginType = set.first);
              },
            ),
            const SizedBox(height: 12),
            if (_loginType == LoginType.account) ...[
              TextFormField(
                controller: _usernameController,
                decoration: const InputDecoration(labelText: '用户名 *'),
                validator: _loginType == LoginType.account
                    ? (v) => (v == null || v.trim().isEmpty) ? '请输入用户名' : null
                    : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _passwordController,
                obscureText: true,
                decoration: InputDecoration(
                  labelText: '密码 *',
                  helperText: _isEdit ? '留空表示不修改已保存的密码' : null,
                ),
                validator: (!_isEdit && _loginType == LoginType.account)
                    ? (v) => (v == null || v.isEmpty) ? '请输入密码' : null
                    : null,
              ),
            ] else ...[
              TextFormField(
                controller: _clientIdController,
                decoration: const InputDecoration(labelText: 'Client ID *'),
                validator: _loginType == LoginType.openapi
                    ? (v) =>
                        (v == null || v.trim().isEmpty) ? '请输入 Client ID' : null
                    : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _clientSecretController,
                obscureText: true,
                decoration: InputDecoration(
                  labelText: 'Client Secret *',
                  helperText: _isEdit ? '留空表示不修改已保存的 Secret' : null,
                ),
                validator: (!_isEdit && _loginType == LoginType.openapi)
                    ? (v) =>
                        (v == null || v.isEmpty) ? '请输入 Client Secret' : null
                    : null,
              ),
            ],
            if (_connectionHint != null) ...[
              const SizedBox(height: 12),
              Text(
                _connectionHint!,
                style: TextStyle(
                  color: _connectionHint!.startsWith('✓')
                      ? Colors.green
                      : Theme.of(context).colorScheme.error,
                ),
              ),
            ],
            const SizedBox(height: 20),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _testing ? null : _testConnection,
                    icon: _testing
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.wifi_tethering),
                    label: Text(_testing ? '连接测试中…' : '连接测试'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _saving ? null : _save,
                    icon: const Icon(Icons.save_outlined),
                    label: Text(_saving ? '保存中…' : '保存'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _testConnection() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _testing = true;
      _connectionHint = null;
    });
    try {
      final baseUrl = _baseUrlController.text.trim();
      final result = await _loginWithCurrentCredential(baseUrl);
      final info = await AuthApi.fetchSystemInfo(
        baseUrl: baseUrl,
        token: result.token,
        loginType: _loginType,
      );
      final version = info['version'];
      setState(() {
        _connectionHint = '✓ 连接成功'
            '${version == null ? '' : '，青龙版本 $version'}';
      });
    } catch (e) {
      setState(() {
        _connectionHint = '连接失败：${readableError(e)}';
      });
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  Future<PanelConnectionResult> _loginWithCurrentCredential(
    String baseUrl,
  ) async {
    if (_loginType == LoginType.account) {
      return AuthApi.loginWithPassword(
        baseUrl: baseUrl,
        username: _usernameController.text.trim(),
        password: _passwordController.text,
      );
    }
    return AuthApi.loginWithOpenApi(
      baseUrl: baseUrl,
      clientId: _clientIdController.text.trim(),
      clientSecret: _clientSecretController.text,
    );
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);
    try {
      final baseUrl = _baseUrlController.text.trim();
      final old = widget.panel;
      final changedCredential = old == null ||
          old.baseUrl != baseUrl ||
          old.loginType != _loginType ||
          (old.username != null &&
              _loginType == LoginType.account &&
              old.username != _usernameController.text.trim()) ||
          (_loginType == LoginType.account &&
              _passwordController.text.isNotEmpty) ||
          (old.clientId != null &&
              _loginType == LoginType.openapi &&
              old.clientId != _clientIdController.text.trim()) ||
          (_loginType == LoginType.openapi &&
              _clientSecretController.text.isNotEmpty);

      String token = '';
      String tokenType = 'Bearer';
      DateTime? expiresAt;
      if (old != null) {
        token = await SecureStorage.readToken(old.id) ?? '';
        tokenType = await SecureStorage.readTokenType(old.id) ?? 'Bearer';
        expiresAt = await SecureStorage.readTokenExpiry(old.id);
      }

      if (changedCredential) {
        final result = await _loginWithCurrentCredential(baseUrl);
        token = result.token;
        tokenType = result.tokenType;
        expiresAt = result.expiresAt;
      }

      final id = old?.id ??
          '${DateTime.now().millisecondsSinceEpoch}_${baseUrl.hashCode}';
      final panel = PanelInfo(
        id: id,
        name: _nameController.text.trim(),
        baseUrl: baseUrl,
        loginType: _loginType,
        username: _loginType == LoginType.account
            ? _usernameController.text.trim()
            : null,
        password: _loginType == LoginType.account
            ? _passwordController.text.isEmpty
                ? old?.password
                : _passwordController.text
            : null,
        clientId: _loginType == LoginType.openapi
            ? _clientIdController.text.trim()
            : null,
        clientSecret: _loginType == LoginType.openapi
            ? _clientSecretController.text.isEmpty
                ? old?.clientSecret
                : _clientSecretController.text
            : null,
        isDefault: old?.isDefault ?? false,
        createTime: old?.createTime ?? DateTime.now(),
      );

      await SecureStorage.saveToken(
        panelId: id,
        token: token,
        tokenType: tokenType,
        expiresAt: expiresAt,
      );
      if (panel.loginType == LoginType.account && panel.password != null) {
        await SecureStorage.savePassword(id, panel.password!);
      } else {
        await SecureStorage.deletePassword(id);
      }
      // client_secret 也是凭据，跟密码一样只进安全存储。
      if (panel.loginType == LoginType.openapi &&
          (panel.clientSecret?.isNotEmpty ?? false)) {
        await SecureStorage.saveClientSecret(id, panel.clientSecret!);
      } else {
        await SecureStorage.deleteClientSecret(id);
      }

      if (mounted) {
        Navigator.of(context).pop(panel);
      }
    } catch (e) {
      if (mounted) {
        setState(() => _connectionHint = '保存失败：${readableError(e)}');
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }
}
