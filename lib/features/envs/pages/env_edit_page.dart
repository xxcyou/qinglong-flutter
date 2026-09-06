import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/utils/error_text.dart';
import '../../../shared/glass_scaffold.dart';
import '../models/env_var.dart';
import '../providers/env_list_provider.dart';

class EnvEditPage extends ConsumerStatefulWidget {
  const EnvEditPage({super.key, this.env});

  final EnvVar? env;

  @override
  ConsumerState<EnvEditPage> createState() => _EnvEditPageState();
}

class _EnvEditPageState extends ConsumerState<EnvEditPage> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _nameController;
  late final TextEditingController _valueController;
  late final TextEditingController _remarksController;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final env = widget.env;
    _nameController = TextEditingController(text: env?.name ?? '');
    _valueController = TextEditingController(text: env?.value ?? '');
    _remarksController = TextEditingController(text: env?.remarks ?? '');
  }

  @override
  void dispose() {
    _nameController.dispose();
    _valueController.dispose();
    _remarksController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);
    final env = EnvVar(
      id: widget.env?.id,
      name: _nameController.text.trim(),
      value: _valueController.text,
      remarks: _remarksController.text.trim().isEmpty
          ? null
          : _remarksController.text.trim(),
      status: widget.env?.status ?? 1,
    );
    try {
      final notifier = ref.read(envListProvider.notifier);
      if (widget.env == null) {
        await notifier.create(env);
      } else {
        await notifier.update(env);
      }
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('保存失败：${errorText(e)}')),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return GlassScaffold(
      title: widget.env == null ? '新增环境变量' : '编辑环境变量',
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 44),
          children: [
            TextFormField(
              controller: _nameController,
              decoration: const InputDecoration(labelText: '名称 *'),
              validator: (v) {
                final value = v?.trim() ?? '';
                if (value.isEmpty) return '请输入名称';
                if (!RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$').hasMatch(value)) {
                  return '字母/下划线开头，仅字母数字下划线';
                }
                return null;
              },
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _valueController,
              decoration: const InputDecoration(labelText: '值 *'),
              maxLines: 3,
              validator: (v) => (v == null || v.isEmpty) ? '请输入值' : null,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _remarksController,
              decoration: const InputDecoration(labelText: '备注'),
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: _saving ? null : _save,
              icon: const Icon(Icons.save_outlined),
              label: Text(_saving ? '保存中…' : '保存'),
            ),
          ],
        ),
      ),
    );
  }
}
