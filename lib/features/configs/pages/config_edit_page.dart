import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/utils/error_text.dart';
import '../../../shared/ask_ai.dart';
import '../../../shared/code_editor.dart';
import '../../../shared/code_language.dart';
import '../../../shared/editor_bus.dart';
import '../../../shared/glass_scaffold.dart';
import '../../../shared/highlighting_code_controller.dart';
import '../../../shared/loading_view.dart';
import '../api/config_api.dart';
import '../providers/config_list_provider.dart';
import '../../panels/providers/panel_list_provider.dart';

class ConfigEditPage extends ConsumerStatefulWidget {
  const ConfigEditPage({super.key, required this.fileName});

  final String fileName;

  @override
  ConsumerState<ConfigEditPage> createState() => _ConfigEditPageState();
}

class _ConfigEditPageState extends ConsumerState<ConfigEditPage> {
  final _editorKey = GlobalKey<CodeEditorFieldState>();
  late final HighlightingCodeController _controller;
  bool _loading = true;
  bool _saving = false;
  Object? _error;

  /// 编辑器总线上的注册 id：AI 的 editor_* 工具靠它找到这个编辑框。
  int? _busId;

  @override
  void initState() {
    super.initState();
    _controller = HighlightingCodeController(
      language: languageForPath(widget.fileName),
      languageName: languageNameForPath(widget.fileName),
    );
    // 挂上编辑器总线：配置文件也要能被 AI 可视化编辑，
    // 否则用户在这一页问 AI 只能拿到"我给你代码你自己贴"。
    _busId = EditorBus.instance.register(
      kind: EditorKind.panelConfig,
      title: widget.fileName,
      path: widget.fileName,
      controller: _controller,
      editorKey: _editorKey,
      language: languageNameForPath(widget.fileName),
      save: () async {
        final ok = await _saveContent();
        return ok ? '已保存配置 ${widget.fileName}' : '保存失败（看编辑器上的报错）。';
      },
    );
    _load();
  }

  @override
  void dispose() {
    final id = _busId;
    if (id != null) EditorBus.instance.unregister(id);
    _controller.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final panel = ref.read(currentPanelProvider);
    if (panel == null) {
      setState(() {
        _loading = false;
        _error = '未选择面板';
      });
      return;
    }
    try {
      final content = await ConfigApi.read(
        apiBaseUrl: panel.apiBaseUrl,
        file: widget.fileName,
      );
      if (!mounted) return;
      setState(() {
        _controller.text = content;
        _loading = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e;
      });
    }
  }

  /// 真正落库。返回是否成功，供 UI 与 AI 的 editor_save 共用。
  Future<bool> _saveContent() async {
    try {
      await ref
          .read(configListProvider.notifier)
          .save(widget.fileName, _controller.text);
      return true;
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('保存失败：${errorText(e)}')),
        );
      }
      return false;
    }
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    final ok = await _saveContent();
    if (!mounted) return;
    setState(() => _saving = false);
    if (!ok) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('配置已保存')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final sensitive = widget.fileName == 'auth.json';
    return GlassScaffold(
      title: widget.fileName,
      actions: [
        IconButton(
          tooltip: '保存',
          onPressed: _saving ? null : _save,
          icon: const Icon(Icons.save_outlined),
        ),
        AskAiButton(
          label: '配置 · ${widget.fileName}',
          source: '配置管理',
          contentBuilder: () => _controller.text,
          draft: '这个配置有没有问题，帮我检查',
        ),
      ],
      body: _loading
          ? const LoadingView()
          : _error != null
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(errorText(_error!)),
                      const SizedBox(height: 12),
                      FilledButton.tonalIcon(
                        onPressed: _load,
                        icon: const Icon(Icons.refresh),
                        label: const Text('重试'),
                      ),
                    ],
                  ),
                )
              : Column(
                  children: [
                    if (sensitive)
                      Container(
                        width: double.infinity,
                        color: Theme.of(context).colorScheme.errorContainer,
                        padding: const EdgeInsets.all(12),
                        child: Text(
                          '正在编辑敏感文件，请谨慎修改',
                          style: TextStyle(
                            color:
                                Theme.of(context).colorScheme.onErrorContainer,
                          ),
                        ),
                      ),
                    Expanded(
                      child: GestureDetector(
                        // 戳一下就把它设成 AI 的默认改动目标：
                        // 同时开着几个编辑器时，"当前"必须跟着用户的手走。
                        behavior: HitTestBehavior.translucent,
                        onTapDown: (_) {
                          final id = _busId;
                          if (id != null) EditorBus.instance.touch(id);
                        },
                        child: CodeEditorField(
                          key: _editorKey,
                          controller: _controller,
                          path: widget.fileName,
                          padding: const EdgeInsets.all(12),
                        ),
                      ),
                    ),
                  ],
                ),
    );
  }
}
