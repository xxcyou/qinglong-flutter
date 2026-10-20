import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../providers/adb_session_provider.dart';

class AdbConnectDialog extends StatefulWidget {
  const AdbConnectDialog({super.key});

  static Future<AdbSessionDraft?> show(BuildContext context) {
    return showDialog<AdbSessionDraft>(
      context: context,
      barrierDismissible: true,
      builder: (_) => const AdbConnectDialog(),
    );
  }

  @override
  State<AdbConnectDialog> createState() => _AdbConnectDialogState();
}

class _AdbConnectDialogState extends State<AdbConnectDialog> {
  final _name = TextEditingController(text: 'ADB 设备');
  final _host = TextEditingController();
  final _port = TextEditingController(text: '5555');
  final _pairingPort = TextEditingController();
  final _pairingCode = TextEditingController();
  bool _android11 = true;
  String? _formError;

  @override
  void dispose() {
    _name.dispose();
    _host.dispose();
    _port.dispose();
    _pairingPort.dispose();
    _pairingCode.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final name = _name.text.trim();
    final host = _host.text.trim();
    final port = int.tryParse(_port.text.trim());
    if (name.isEmpty || host.isEmpty || port == null || port <= 0) {
      setState(() => _formError = '请填写名称、主机和有效的连接端口');
      return;
    }
    int? pairingPort;
    String? pairingCode;
    if (_android11) {
      pairingPort = int.tryParse(_pairingPort.text.trim());
      pairingCode = _pairingCode.text.trim();
      if (pairingPort == null || pairingCode.isEmpty) {
        setState(() => _formError = 'Android 11+ 无线调试需要配对端口和 6 位配对码');
        return;
      }
    }
    Navigator.of(context).pop(
      AdbSessionDraft(
        name: name,
        host: host,
        port: port,
        pairingPort: pairingPort,
        pairingCode: pairingCode,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 28, vertical: 32),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460, maxHeight: 680),
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
                    child: Icon(Icons.smartphone, color: scheme.primary),
                  ),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '新建 ADB 连接',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        SizedBox(height: 2),
                        Text(
                          '网络无线调试，Android 11+ 先配对再连接',
                          style: TextStyle(fontSize: 12.5),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
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
                          hintText: '给这个设备起个名字',
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
                          labelText: '设备 IP',
                          hintText: '192.168.1.100',
                          prefixIcon: const Icon(Icons.language_outlined),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      TextField(
                        controller: _port,
                        keyboardType: TextInputType.number,
                        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                        decoration: InputDecoration(
                          labelText: 'ADB 端口',
                          hintText: '5555',
                          prefixIcon: const Icon(Icons.numbers_outlined),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                        ),
                      ),
                      const SizedBox(height: 18),
                      SwitchListTile(
                        value: _android11,
                        onChanged: (v) => setState(() => _android11 = v),
                        title: const Text('Android 11+ 无线调试配对'),
                        subtitle: const Text('开启后需要配对端口和 6 位配对码'),
                      ),
                      if (_android11) ...[
                        const SizedBox(height: 8),
                        TextField(
                          controller: _pairingPort,
                          keyboardType: TextInputType.number,
                          inputFormatters: [
                            FilteringTextInputFormatter.digitsOnly,
                          ],
                          decoration: InputDecoration(
                            labelText: '配对端口',
                            hintText: '如 38943',
                            prefixIcon: const Icon(Icons.link),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(14),
                            ),
                          ),
                        ),
                        const SizedBox(height: 16),
                        TextField(
                          controller: _pairingCode,
                          keyboardType: TextInputType.number,
                          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                          decoration: InputDecoration(
                            labelText: '6 位配对码',
                            prefixIcon: const Icon(Icons.password),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(14),
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              if (_formError != null) ...[
                const SizedBox(height: 8),
                Text(
                  _formError!,
                  style: TextStyle(color: scheme.error, fontSize: 12.5),
                ),
              ],
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('取消'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    onPressed: _submit,
                    icon: const Icon(Icons.link),
                    label: const Text('连接'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
