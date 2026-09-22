import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../providers/ssh_session_provider.dart';

class SshConnectDialog extends StatefulWidget {
  const SshConnectDialog({super.key});

  static Future<SshSessionDraft?> show(BuildContext context) {
    return showDialog<SshSessionDraft>(
      context: context,
      barrierDismissible: true,
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
  String? _keyFileName;
  String? _formError;
  bool _pickingKey = false;

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

  Future<void> _pickKeyFile() async {
    setState(() {
      _pickingKey = true;
      _formError = null;
    });
    try {
      final result = await FilePicker.pickFiles(
        type: FileType.any,
        allowMultiple: false,
      );
      final path = result?.files.single.path;
      if (path == null) return;
      final content = await File(path).readAsString();
      if (!mounted) return;
      setState(() {
        _privateKey.text = content.trim();
        _keyFileName = result!.files.single.name;
        _authType = SshAuthType.key;
      });
    } catch (e) {
      if (mounted) {
        setState(() => _formError = '读取密钥文件失败：$e');
      }
    } finally {
      if (mounted) setState(() => _pickingKey = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 28, vertical: 32),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460, maxHeight: 720),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Container(
                    width: 42,
                    height: 42,
                    decoration: BoxDecoration(
                      color: scheme.primaryContainer,
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Icon(Icons.dns_outlined, color: scheme.primary),
                  ),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '新建 SSH 会话',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        SizedBox(height: 2),
                        Text(
                          '密码登录或密钥登录，密钥支持从文件读取或手动粘贴',
                          style: TextStyle(fontSize: 12.5),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: '关闭',
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      TextField(
                        controller: _name,
                        decoration: InputDecoration(
                          labelText: '显示名称',
                          hintText: '给这个连接起个名字',
                          prefixIcon: const Icon(Icons.badge_outlined),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      TextField(
                        controller: _host,
                        decoration: InputDecoration(
                          labelText: '主机 Host',
                          hintText: '192.168.0.1 或 example.com',
                          prefixIcon: const Icon(Icons.language_outlined),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      Row(
                        children: [
                          Expanded(
                            flex: 3,
                            child: TextField(
                              controller: _username,
                              decoration: InputDecoration(
                                labelText: '用户名',
                                hintText: 'root',
                                prefixIcon: const Icon(Icons.person_outlined),
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(14),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            flex: 2,
                            child: TextField(
                              controller: _port,
                              keyboardType: TextInputType.number,
                              decoration: InputDecoration(
                                labelText: '端口',
                                prefixIcon: const Icon(Icons.numbers_outlined),
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(14),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 18),
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
                        onSelectionChanged: (v) =>
                            setState(() => _authType = v.first),
                        showSelectedIcon: false,
                      ),
                      const SizedBox(height: 16),
                      AnimatedSwitcher(
                        duration: const Duration(milliseconds: 240),
                        child: _authType == SshAuthType.password
                            ? TextField(
                                key: const ValueKey('password'),
                                controller: _password,
                                obscureText: true,
                                decoration: InputDecoration(
                                  labelText: '密码',
                                  hintText: '登录密码',
                                  prefixIcon:
                                      const Icon(Icons.password_outlined),
                                  border: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(14),
                                  ),
                                ),
                              )
                            : Column(
                                key: const ValueKey('key'),
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  OutlinedButton.icon(
                                    onPressed:
                                        _pickingKey ? null : _pickKeyFile,
                                    icon: _pickingKey
                                        ? const SizedBox(
                                            width: 16,
                                            height: 16,
                                            child: CircularProgressIndicator(
                                              strokeWidth: 2,
                                            ),
                                          )
                                        : const Icon(Icons.attach_file),
                                    label: Text(
                                      _keyFileName == null
                                          ? '从文件选择私钥'
                                          : '已选择：$_keyFileName',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    style: OutlinedButton.styleFrom(
                                      padding: const EdgeInsets.symmetric(
                                          vertical: 14),
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(14),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(height: 12),
                                  TextField(
                                    controller: _privateKey,
                                    minLines: 5,
                                    maxLines: 9,
                                    style: const TextStyle(
                                      fontFamily: 'monospace',
                                      fontSize: 12,
                                    ),
                                    decoration: InputDecoration(
                                      labelText: '私钥内容（PEM）',
                                      hintText:
                                          '粘贴或从文件读取，支持 OpenSSH ed25519/RSA/EC',
                                      alignLabelWithHint: true,
                                      prefixIcon: const Padding(
                                        padding: EdgeInsets.only(bottom: 90),
                                        child: Icon(Icons.key_outlined),
                                      ),
                                      border: OutlineInputBorder(
                                        borderRadius: BorderRadius.circular(14),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(height: 12),
                                  TextField(
                                    controller: _passphrase,
                                    obscureText: true,
                                    decoration: InputDecoration(
                                      labelText: '密钥口令（可选）',
                                      prefixIcon:
                                          const Icon(Icons.lock_outline),
                                      border: OutlineInputBorder(
                                        borderRadius: BorderRadius.circular(14),
                                      ),
                                    ),
                                  ),
                                  if (_keyFileName != null)
                                    Padding(
                                      padding: const EdgeInsets.only(top: 8),
                                      child: Text(
                                        '密钥已从文件载入，仍可手动修改内容',
                                        style: TextStyle(
                                          fontSize: 12,
                                          color: scheme.primary,
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                      ),
                      if (_formError != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 12),
                          child: Text(
                            _formError!,
                            style: TextStyle(color: scheme.error, fontSize: 13),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 18),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.pop(context),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                      child: const Text('取消'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: _submit,
                      icon: const Icon(Icons.power_settings_new),
                      label: const Text('连接'),
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _submit() {
    final host = _host.text.trim();
    final username = _username.text.trim();
    final port = int.tryParse(_port.text.trim()) ?? 22;
    if (host.isEmpty || username.isEmpty) {
      setState(() => _formError = '请填写主机和用户名');
      return;
    }
    if (_authType == SshAuthType.key && _privateKey.text.trim().isEmpty) {
      setState(() => _formError = '密钥登录需要私钥内容，请粘贴或从文件选择');
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
