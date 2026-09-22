import 'package:flutter/material.dart';

import '../providers/ssh_session_provider.dart';

class SshConnectDialog extends StatefulWidget {
  const SshConnectDialog({super.key});

  static Future<SshSessionDraft?> show(BuildContext context) {
    return showDialog<SshSessionDraft>(
      context: context,
      builder: (_) => const SshConnectDialog(),
    );
  }

  @override
  State<SshConnectDialog> createState() => _SshConnectDialogState();
}

class _SshConnectDialogState extends State<SshConnectDialog> {
  final _name = TextEditingController(text: 'SSH 服务器');
  final _host = TextEditingController();
  final _port = TextEditingController(text: '22');
  final _username = TextEditingController();
  final _password = TextEditingController();
  final _privateKey = TextEditingController();
  final _passphrase = TextEditingController();
  SshAuthType _authType = SshAuthType.password;

  @override
  void dispose() {
    _name.dispose();
    _host.dispose();
    _port.dispose();
    _username.dispose();
    _password.dispose();
    _privateKey.dispose();
    _passphrase.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('新建 SSH 终端'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _name,
              decoration: const InputDecoration(labelText: '显示名称'),
            ),
            TextField(
              controller: _host,
              decoration: const InputDecoration(labelText: '主机 Host'),
            ),
            TextField(
              controller: _port,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: '端口 Port'),
            ),
            TextField(
              controller: _username,
              decoration: const InputDecoration(labelText: '用户名'),
            ),
            const SizedBox(height: 8),
            SegmentedButton<SshAuthType>(
              segments: const [
                ButtonSegment(
                  value: SshAuthType.password,
                  label: Text('密码登录'),
                  icon: Icon(Icons.password),
                ),
                ButtonSegment(
                  value: SshAuthType.key,
                  label: Text('密钥登录'),
                  icon: Icon(Icons.key),
                ),
              ],
              selected: {_authType},
              onSelectionChanged: (v) => setState(() => _authType = v.first),
            ),
            const SizedBox(height: 8),
            if (_authType == SshAuthType.password)
              TextField(
                controller: _password,
                obscureText: true,
                decoration: const InputDecoration(labelText: '密码'),
              )
            else ...[
              TextField(
                controller: _privateKey,
                maxLines: 5,
                decoration: const InputDecoration(
                  labelText: '私钥（PEM 格式）',
                  alignLabelWithHint: true,
                ),
              ),
              TextField(
                controller: _passphrase,
                obscureText: true,
                decoration: const InputDecoration(labelText: '密钥口令（可选）'),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _submit,
          child: const Text('连接'),
        ),
      ],
    );
  }

  void _submit() {
    final host = _host.text.trim();
    final username = _username.text.trim();
    final port = int.tryParse(_port.text.trim()) ?? 22;
    if (host.isEmpty || username.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请填写主机和用户名')),
      );
      return;
    }
    Navigator.pop(
      context,
      SshSessionDraft(
        name: _name.text.trim().isEmpty ? host : _name.text.trim(),
        host: host,
        port: port,
        username: username,
        authType: _authType,
        password: _authType == SshAuthType.password ? _password.text : null,
        privateKey: _authType == SshAuthType.key ? _privateKey.text : null,
        keyPassphrase: _authType == SshAuthType.key ? _passphrase.text : null,
      ),
    );
  }
}
