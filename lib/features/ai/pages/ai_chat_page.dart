import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/llm/llm_config_provider.dart';
import '../../../core/llm/llm_registry_provider.dart';
import '../../../core/local_shell/proot_bridge.dart';
import '../../../core/theme/glass.dart';
import '../../../core/theme/theme_effects_controller.dart';
import '../../../core/utils/formatter.dart';
import '../../../core/utils/error_text.dart';
import '../../browser/browser_engine.dart';
import '../models/agent_event.dart';
import '../models/ai_message.dart';
import '../models/ai_plan.dart';
import '../providers/chat_provider.dart';
import '../providers/audit_provider.dart';
import '../knowledge/knowledge_provider.dart';
import '../../../shared/file_kinds.dart';
import '../../../shared/glass_scaffold.dart';
import '../../../shared/local_file_picker.dart';
import '../floating/ai_dock_provider.dart';
import '../plugins/output_plugin.dart';
import '../mcp/mcp_provider.dart';
import '../modes/mode_models.dart';
import '../modes/mode_provider.dart';
import '../skills/skill_provider.dart';
import '../widgets/agent_process_card.dart';
import '../widgets/ai_canvas_sheet.dart';
import '../widgets/ai_composer.dart';
import '../widgets/agent_stream_card.dart';
import '../widgets/session_usage_chip.dart';
import '../widgets/ai_session_list.dart';
import '../widgets/ai_control_sheets.dart';
import '../widgets/ai_question_card.dart';
import '../widgets/particle_dissolve.dart';
import '../widgets/queue_strip.dart';
import 'mcp_server_page.dart';
import 'skill_list_page.dart';
import '../widgets/markdown_message.dart';
import '../widgets/pending_image_bar.dart';
import '../../../shared/mono_text.dart';
import '../../../shared/image_preview_overlay.dart';
import '../../terminal/pages/shell_files_page.dart';

class AiChatPage extends ConsumerStatefulWidget {
  const AiChatPage({super.key});

  @override
  ConsumerState<AiChatPage> createState() => _AiChatPageState();
}

class _AiChatPageState extends ConsumerState<AiChatPage> {
  final _controller = TextEditingController();
  final _scrollController = ScrollController();

  /// 当前正在“引用追问”的消息下标；null=没有引用。
  int? _followUpIndex;

  /// 被引用消息的文字内容，发送时拼进问题里作为引用。
  String? _followUpText;

  /// 长按菜单里点了“选取文字”后，这条气泡进入可选取模式；点其它位置关闭。
  int? _selectableIndex;

  /// 正在闪烁提示的追问目标下标。
  int? _followUpFlashIndex;
  Timer? _followUpFlashTimer;

  /// 修改模式：长按“修改”后进入，不立刻撤回，等用户发送修改或取消。
  bool _editMode = false;

  /// 被修改的用户消息下标。
  int? _editIndex;

  /// 进入修改前的输入框内容，取消修改时恢复原样。
  String _preEditInput = '';

  /// 是否跟着最新内容走。
  ///
  /// 默认跟随：回复一边流一边往下滚，用户不用一直手动拉到底。
  /// 但用户往上翻看历史时必须立刻停下——正在读旧消息却被拽回底部
  /// 比不自动滚更烦。判据是"离底部还有多远"，不是"有没有滑过"。
  bool _pinned = true;

  /// AI 页左侧半屏文件面板。
  bool _filePanelOpen = false;

  /// 输入框打 `/` 后正在选模式的关键字；空 = 不显示模式选择条。
  String _modePickerKeyword = '';

  static const _filePanelFractionKey = 'ai_file_panel_fraction_v1';

  /// 面板宽度占屏幕比例，默认 2/3；可拖动右侧小白条在 0.4~0.95 间调整。
  /// 调好后会记住，下次滑出来还是这个大小。
  double _filePanelFraction = 0.66;

  /// 开始滑动的位置：从屏幕最左边缘滑会留给系统返回手势，避免误触。
  double _fileDragStartDx = -1;

  void _openFilePanel() => setState(() => _filePanelOpen = true);
  void _closeFilePanel() => setState(() => _filePanelOpen = false);

  void _onInputChanged(String text) {
    final trimmed = text.trimLeft();
    // 只在输入框以 `/` 开头且还没打空格时弹模式选择条。
    if (trimmed.startsWith('/') && !trimmed.contains(RegExp(r'\s'))) {
      final key = trimmed.substring(1).trim();
      if (_modePickerKeyword != key) {
        setState(() => _modePickerKeyword = key);
      }
    } else if (_modePickerKeyword.isNotEmpty) {
      setState(() => _modePickerKeyword = '');
    }
  }

  void _selectMode(AiMode mode) {
    ref.read(chatProvider.notifier).addPendingMode(mode.id);
    _controller.clear();
    setState(() => _modePickerKeyword = '');
  }

  Future<void> _loadFilePanelFraction() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getDouble(_filePanelFractionKey);
      if (saved != null && saved >= 0.4 && saved <= 0.95 && mounted) {
        setState(() => _filePanelFraction = saved);
      }
    } catch (_) {
      // 记不住宽度不影响功能，用默认值继续。
    }
  }

  Future<void> _saveFilePanelFraction() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble(_filePanelFractionKey, _filePanelFraction);
    } catch (_) {
      // 忽略写入失败。
    }
  }

  /// 每条消息一个 RepaintBoundary key：撤回时按它抓图做消散。
  /// 用列表而不是 Map<int,GlobalKey>，因为索引就是消息在会话里的位置，
  /// 撤回只会从尾部截断，前面的 key 保持不变正好复用。
  final List<GlobalKey?> _bubbleKeys = [];

  final _listKey = GlobalKey();

  GlobalKey _bubbleKeyAt(int index) {
    while (_bubbleKeys.length <= index) {
      _bubbleKeys.add(null);
    }
    return _bubbleKeys[index] ??= GlobalKey();
  }

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _loadFilePanelFraction();
    Future.microtask(() async {
      await ref.read(chatProvider.notifier).loadSessions();
      // 会话读完再看有没有被打断的运行：恢复要切到原会话，顺序反了会切错。
      await ref.read(chatProvider.notifier).loadInterruptedRun();
      // 只读缓存，不发请求：模型列表在设置页手动获取一次就够了。
      ref.read(chatProvider.notifier).loadCachedModels();
    });
  }

  @override
  void dispose() {
    _followUpFlashTimer?.cancel();
    _controller.dispose();
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final pos = _scrollController.position;
    // 160 逻辑像素的容差：手指刚好停在最后一条上也算"在底部"。
    final atBottom = pos.maxScrollExtent - pos.pixels <= 160;
    if (atBottom != _pinned) setState(() => _pinned = atBottom);
  }

  /// 内容变了就跟到底。用 jumpTo 而不是动画：流式回复每秒改好几次
  /// state，动画会互相打断，看起来一顿一顿的。
  void _followTail() {
    if (!_pinned) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      final max = _scrollController.position.maxScrollExtent;
      if ((max - _scrollController.position.pixels).abs() < 1) return;
      _scrollController.jumpTo(max);
    });
  }

  /// 撤回：把被删掉的那几条"炸"掉，再把原话放回输入框。
  ///
  /// 顺序很讲究——必须先抓图，再改数据。数据一改，ListView 立刻把那些条目
  /// 卸载掉，RenderObject 没了就什么都抓不到，只能看到一次生硬的跳变。
  Future<void> _rollbackTo(int index) async {
    final notifier = ref.read(chatProvider.notifier);
    final keys = <GlobalKey>[];
    for (var i = index; i < _bubbleKeys.length; i++) {
      final key = _bubbleKeys[i];
      if (key != null) keys.add(key);
    }
    final pieces = await captureDissolvePieces(keys);
    // 粒子关在列表区里：飘到标题栏或输入框上面就露馅了。
    final listBox = _listKey.currentContext?.findRenderObject();
    Rect? clip;
    if (listBox is RenderBox && listBox.hasSize) {
      clip = listBox.localToGlobal(Offset.zero) & listBox.size;
    }
    if (!mounted) {
      for (final piece in pieces) {
        piece.image.dispose();
      }
      return;
    }
    playDissolve(context, pieces, clip: clip);
    final text = notifier.rollbackTo(index);
    // 撤回的本意基本都是"这句我想重新说"，所以原话直接回到输入框，
    // 用户改两个字就能再发，不用自己复制粘贴。
    if (text.trim().isNotEmpty) {
      _controller.text = text;
      _controller.selection = TextSelection.collapsed(offset: text.length);
    }
    _pinned = true;
    _followTail();
  }

  void _send() {
    // 修改模式下发送 = 应用修改并重新生成；不能再当作普通新消息发。
    if (_editMode) {
      _applyEditAndSend();
      return;
    }
    final dock = ref.read(aiDockProvider.notifier);
    // 附件（本地文件、页面自动带上来的日志）要拼进提问里，
    // 和悬浮窗走同一个 composePrompt，两边行为一致。
    final quoted = _followUpText ?? '';
    final raw = quoted.trim().isNotEmpty && _controller.text.trim().isNotEmpty
        ? '引用追问：$quoted\n\n${_controller.text}'
        : _controller.text;
    final prompt = dock.composePrompt(raw);
    // 只带图片/附件、没有文字也可以直接发。
    if (prompt.trim().isEmpty && ref.read(chatProvider).pendingImages.isEmpty) {
      return;
    }
    _controller.clear();
    dock.consumeChips();
    if (_followUpIndex != null) _closeFollowUp();
    // 自己发的消息一定要看到，所以先强制恢复跟随。
    _pinned = true;
    ref.read(chatProvider.notifier).send(prompt);
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
  }

  void _openFollowUp(int index, AiChatMessage message) {
    if (_editMode) _cancelEdit();
    final text = message.displayContent.isNotEmpty
        ? message.displayContent
        : message.content;
    _followUpIndex = index;
    _followUpText = text;
    setState(() {});
    _pinned = false;
    _flashFollowUpTarget(index);
  }

  void _closeFollowUp() {
    _followUpFlashTimer?.cancel();
    setState(() {
      _followUpIndex = null;
      _followUpText = null;
      _followUpFlashIndex = null;
    });
  }

  void _jumpToFollowUpTarget() {
    final index = _followUpIndex;
    if (index == null) return;
    _pinned = false;
    _flashFollowUpTarget(index);
  }

  void _sendQuoteSuggestion(String text) {
    _controller.text = text;
    _controller.selection = TextSelection.collapsed(offset: text.length);
    _send();
  }

  void _flashFollowUpTarget(int index) {
    _followUpFlashTimer?.cancel();
    setState(() => _followUpFlashIndex = index);
    _scrollToIndex(index);
    _followUpFlashTimer = Timer(const Duration(milliseconds: 1600), () {
      if (mounted) setState(() => _followUpFlashIndex = null);
    });
  }

  void _startEdit(int index, AiChatMessage message) {
    if (_followUpIndex != null) _closeFollowUp();
    final text = message.displayContent.isNotEmpty
        ? message.displayContent
        : message.content;
    _preEditInput = _controller.text;
    _editIndex = index;
    _editMode = true;
    _controller.text = text;
    _controller.selection = TextSelection.collapsed(offset: text.length);
    setState(() {});
    _pinned = true;
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToIndex(index));
  }

  void _cancelEdit() {
    if (!_editMode) return;
    _editMode = false;
    _editIndex = null;
    _controller.text = _preEditInput;
    _controller.selection =
        TextSelection.collapsed(offset: _preEditInput.length);
    _preEditInput = '';
    setState(() {});
  }

  /// 修改模式下点发送/应用：撤回到被修改消息之前，再把改好的内容作为新消息发出。
  Future<void> _applyEditAndSend() async {
    final idx = _editIndex;
    if (!_editMode || idx == null) {
      _send();
      return;
    }
    final newText = _controller.text;
    final notifier = ref.read(chatProvider.notifier);
    notifier.rollbackTo(idx);
    _editMode = false;
    _editIndex = null;
    _preEditInput = '';
    if (newText.trim().isEmpty &&
        ref.read(chatProvider).pendingImages.isEmpty) {
      setState(() {});
      return;
    }
    await notifier.send(newText);
    _controller.clear();
    setState(() {});
    _pinned = true;
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
  }

  /// 打开大屏输入编辑器（普通输入和修改模式都能用）。
  void _openExpandedEditor() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) => Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(sheetContext).viewInsets.bottom,
        ),
        child: SafeArea(
          child: Container(
            height: MediaQuery.sizeOf(sheetContext).height * 0.72,
            margin: const EdgeInsets.fromLTRB(8, 40, 8, 8),
            decoration: BoxDecoration(
              color: Theme.of(sheetContext).colorScheme.surface,
              borderRadius: BorderRadius.circular(20),
            ),
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
                  child: Row(
                    children: [
                      Text(
                        _editMode ? '修改消息 · 大屏编辑' : '大屏输入',
                        style: const TextStyle(
                            fontSize: 15, fontWeight: FontWeight.w700),
                      ),
                      const Spacer(),
                      TextButton(
                        onPressed: () => Navigator.of(sheetContext).pop(),
                        child: const Text('取消'),
                      ),
                      FilledButton(
                        onPressed: () => Navigator.of(sheetContext).pop(),
                        child: const Text('完成'),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                    child: TextField(
                      controller: _controller,
                      maxLines: null,
                      expands: true,
                      textAlignVertical: TextAlignVertical.top,
                      autofocus: true,
                      decoration: InputDecoration(
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        hintText: '在这里编辑…',
                      ),
                    ),
                  ),
                ),
                if (_editMode)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        FilledButton.icon(
                          onPressed: () {
                            Navigator.of(sheetContext).pop();
                            _send();
                          },
                          icon: const Icon(Icons.send_rounded, size: 16),
                          label: const Text('应用修改并发送'),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _scrollToIndex(int index) {
    if (!mounted || !_scrollController.hasClients) return;
    final list = _scrollController.position;
    // 粗略估算：每条消息高度不一，这里直接把目标滚到可视区中央偏上。
    final rough = index * 96.0;
    final target = (rough - list.viewportDimension * 0.35).clamp(
      0.0,
      list.maxScrollExtent,
    );
    _scrollController.animateTo(
      target,
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOut,
    );
  }

  /// 长按消息弹出的底部操作面板。
  void _showMessageActions(int index, AiChatMessage message) {
    final notifier = ref.read(chatProvider.notifier);
    final text = message.displayContent.isNotEmpty
        ? message.displayContent
        : message.content;
    final List<Widget> actions = [];
    void copy() {
      Clipboard.setData(ClipboardData(text: text));
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('已复制'),
          duration: Duration(milliseconds: 900),
        ),
      );
    }

    if (message.isUser) {
      actions.addAll([
        ListTile(
          leading: const Icon(Icons.copy_rounded),
          title: const Text('复制'),
          onTap: () {
            Navigator.of(context).pop();
            copy();
          },
        ),
        ListTile(
          leading: const Icon(Icons.text_fields_rounded),
          title: const Text('选取文字'),
          subtitle: const Text('仅这条气泡可选取，点其它位置关闭'),
          onTap: () {
            Navigator.of(context).pop();
            setState(() => _selectableIndex = index);
          },
        ),
        ListTile(
          leading: const Icon(Icons.edit_rounded),
          title: const Text('修改'),
          subtitle: const Text('把这条消息放进输入框，发送后生效'),
          onTap: () {
            Navigator.of(context).pop();
            _startEdit(index, message);
          },
        ),
        ListTile(
          leading: const Icon(Icons.reply_rounded),
          title: const Text('追问'),
          subtitle: const Text('以引用方式追问，在输入框发送'),
          onTap: () {
            Navigator.of(context).pop();
            _openFollowUp(index, message);
          },
        ),
        ListTile(
          leading: const Icon(Icons.add_comment_rounded),
          title: const Text('创建新会话'),
          subtitle: const Text('把这句话作为新对话的第一条'),
          onTap: () {
            Navigator.of(context).pop();
            notifier.createSession();
            if (text.trim().isNotEmpty) notifier.send(text);
          },
        ),
        ListTile(
          leading: const Icon(Icons.undo_rounded),
          title: const Text('撤回'),
          subtitle: const Text('删除这条消息及其之后的内容'),
          onTap: () {
            Navigator.of(context).pop();
            _rollbackTo(index);
          },
        ),
      ]);
    } else {
      actions.addAll([
        ListTile(
          leading: const Icon(Icons.copy_rounded),
          title: const Text('复制'),
          onTap: () {
            Navigator.of(context).pop();
            copy();
          },
        ),
        ListTile(
          leading: const Icon(Icons.text_fields_rounded),
          title: const Text('选取文字'),
          subtitle: const Text('仅这条气泡可选取，点其它位置关闭'),
          onTap: () {
            Navigator.of(context).pop();
            setState(() => _selectableIndex = index);
          },
        ),
        ListTile(
          leading: const Icon(Icons.reply_rounded),
          title: const Text('追问'),
          subtitle: const Text('以引用方式追问，在输入框发送'),
          onTap: () {
            Navigator.of(context).pop();
            _openFollowUp(index, message);
          },
        ),
        ListTile(
          leading: const Icon(Icons.description_rounded),
          title: const Text('保存为文档到本地'),
          onTap: () async {
            Navigator.of(context).pop();
            await _saveMessageAsDocument(message, text);
          },
        ),
        ListTile(
          leading: const Icon(Icons.menu_book_rounded),
          title: const Text('保存到知识库'),
          onTap: () async {
            Navigator.of(context).pop();
            await _saveMessageToKnowledge(message, text);
          },
        ),
        ListTile(
          leading: const Icon(Icons.refresh_rounded),
          title: const Text('重新生成'),
          onTap: () {
            Navigator.of(context).pop();
            notifier.resendAt(index);
          },
        ),
      ]);
    }

    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) => SafeArea(
        child: ClipRRect(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
          child: Material(
            color: Theme.of(sheetContext).colorScheme.surface,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
                  child: Text(
                    message.isUser ? '我的消息操作' : 'AI 回复操作',
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                Flexible(
                  child: ListView(
                    shrinkWrap: true,
                    children: actions,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _saveMessageAsDocument(
      AiChatMessage message, String text) async {
    if (text.trim().isEmpty) {
      _toast('这条消息没有可保存的文字');
      return;
    }
    try {
      final stamp = DateTime.now().millisecondsSinceEpoch;
      final title = 'AI回复_$stamp';
      final path = '/workspace/.ai/$title.md';
      final body = '# $title\n\n$text\n';
      final bridge = ProotBridge();
      await bridge.makeDirectory('/workspace/.ai');
      await bridge.writeFile(path: path, content: body);
      if (!mounted) return;
      _toast('已保存到本地：$path');
    } catch (e) {
      _toast('保存文档失败：$e');
    }
  }

  Future<void> _saveMessageToKnowledge(
      AiChatMessage message, String text) async {
    if (text.trim().isEmpty) {
      _toast('这条消息没有可保存的文字');
      return;
    }
    final firstLine = text.trim().split('\n').first.trim();
    final title = firstLine.length > 30
        ? firstLine.substring(0, 30)
        : (firstLine.isEmpty ? 'AI回复' : firstLine);
    final doc = await ref
        .read(knowledgeProvider.notifier)
        .save(title: title, content: text.trim(), tags: const ['AI回复']);
    if (!mounted) return;
    _toast(doc != null ? '已保存到知识库：${doc.name}' : '保存到知识库失败');
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 1)),
    );
  }

  /// 挑一个本地文件当附件。图片走独立图片通道，需要提供商配好图片识别模型。
  Future<void> _pickFile() async {
    final picked = await LocalFilePicker.pick(context);
    if (picked == null || !mounted) return;
    if (picked.mime.toLowerCase().startsWith('image/')) {
      final registry = ref.read(llmRegistryProvider);
      final activeProvider = registry.active;
      final currentModel = ref.read(chatProvider).selectedModel.isNotEmpty
          ? ref.read(chatProvider).selectedModel
          : activeProvider.defaultModel;
      final mainSupportsImage =
          activeProvider.capabilitiesFor(currentModel).supportsImage;
      if (!mainSupportsImage &&
          (registry.visionModel.trim().isEmpty ||
              registry.visionProviderId.isEmpty)) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
                '当前主模型不支持图片，且没有设置图片识别模型。去「设置 → AI → 图片识别模型」配置，或在模型能力里给主模型勾选“支持图片”。'),
            duration: Duration(seconds: 3),
          ),
        );
        return;
      }
      final image = await readPickedImage(picked);
      if (image == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('图片读取失败：${picked.path}')),
        );
        return;
      }
      ref.read(chatProvider.notifier).addPendingImage(image);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('已附上图片 ${picked.name}'),
          duration: const Duration(seconds: 1),
        ),
      );
      return;
    }
    final label = ref.read(aiDockProvider.notifier).pushFile(
          path: picked.path,
          name: picked.name,
          content: picked.content,
          language: picked.language,
          truncated: picked.truncated,
          // 这里已经在聊天界面了，别再把悬浮窗弹出来盖住它。
          open: false,
        );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('已附上 $label'),
        duration: const Duration(seconds: 1),
      ),
    );
  }

  /// 已经挂载的模式标签 chips，点 x 取消。
  Widget _buildPendingModeChips(ChatState state) {
    final scheme = Theme.of(context).colorScheme;
    final modes = ref.watch(modeProvider);
    final modeById = {for (final m in modes.items) m.id: m};
    final picked = [
      for (final id in state.pendingModeIds)
        if (modeById[id] != null) modeById[id]!,
    ];
    if (picked.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 0, 14, 4),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final m in picked)
              InputChip(
                visualDensity: VisualDensity.compact,
                avatar: Icon(Icons.tune, size: 14, color: scheme.primary),
                label:
                    Text('#${m.name}', style: const TextStyle(fontSize: 11.5)),
                onDeleted: () =>
                    ref.read(chatProvider.notifier).removePendingMode(m.id),
              ),
          ],
        ),
      ),
    );
  }

  /// 输入框打 `/` 后弹出的模式选择条：点标签直接挂载并清空输入框。
  Widget _buildModePicker() {
    final scheme = Theme.of(context).colorScheme;
    final notifier = ref.read(modeProvider.notifier);
    final modes = notifier.search(_modePickerKeyword);
    if (modes.isEmpty) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(14, 0, 14, 4),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Text(
            _modePickerKeyword.isEmpty
                ? '没有模式，去「管理 → 模式库」新建一个'
                : '没有匹配「$_modePickerKeyword」的模式',
            style: TextStyle(
              fontSize: 11.5,
              color: scheme.onSurfaceVariant,
            ),
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 0, 14, 4),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final m in modes)
              ActionChip(
                visualDensity: VisualDensity.compact,
                avatar: Icon(Icons.tune, size: 14, color: scheme.primary),
                label:
                    Text('#${m.name}', style: const TextStyle(fontSize: 11.5)),
                onPressed: () => _selectMode(m),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildTail(BuildContext context, ChatState state) {
    // 提问优先于计划确认：模型问了话，先把话答上，别让两张卡片抢地方。
    final question = state.pendingQuestion;
    if (question != null) {
      return AiQuestionCard(
        // key 跟着提问号走：同一句话问第二遍时也会重建，不会继承"已回答"。
        key: ValueKey('q${question.id}'),
        question: question,
        onAnswer: (answer) {
          ref.read(chatProvider.notifier).send(answer);
          WidgetsBinding.instance
              .addPostFrameCallback((_) => _scrollToBottom());
        },
      );
    }
    if (state.pendingPlan.isNotEmpty) {
      final notifier = ref.read(chatProvider.notifier);
      return _PlanConfirmCard(
        plan: state.pendingPlan,
        onConfirm: notifier.confirmPlan,
        onReject: notifier.rejectPlan,
      );
    }
    return const SizedBox.shrink();
  }

  void _scrollToBottom() {
    if (!_scrollController.hasClients) return;
    _scrollController.animateTo(
      _scrollController.position.maxScrollExtent,
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
    );
  }

  void _showSessionManager() => AiSessionList.showSheet(context);

  /// 输出插件状态底表：配置了哪些插件、顺序、本轮每个 hook 的调用反馈。
  /// 记录列表采用「下滑到底加载更多」，避免一次性构建太多行。
  void _showPluginFeedback() {
    final registry = ref.read(llmRegistryProvider);
    final paths = registry.active.effectiveOutputPlugins;
    final service = OutputPluginService.instance;
    final loadedPaths = service.loadedPaths;
    final records = service.runRecords.reversed.toList(growable: false);
    final scheme = Theme.of(context).colorScheme;
    final visible = ValueNotifier<int>(50);

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.72,
        maxChildSize: 0.92,
        minChildSize: 0.4,
        builder: (context, scrollController) => ValueListenableBuilder<int>(
          valueListenable: visible,
          builder: (context, count, _) {
            final shown = records.take(count).toList(growable: false);
            return NotificationListener<ScrollNotification>(
              onNotification: (notification) {
                if (notification.metrics.extentAfter < 300 &&
                    count < records.length) {
                  visible.value = count + 50;
                }
                return false;
              },
              child: Container(
                decoration: BoxDecoration(
                  color: scheme.surface,
                  borderRadius:
                      const BorderRadius.vertical(top: Radius.circular(24)),
                ),
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                child: ListView(
                  controller: scrollController,
                  children: [
                    Row(
                      children: [
                        const Expanded(
                          child: Text(
                            '输出插件状态',
                            style: TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        IconButton(
                          onPressed: () => Navigator.pop(sheetContext),
                          icon: const Icon(Icons.close),
                        ),
                      ],
                    ),
                    Text(
                      '已配置 ${paths.length} 个插件 · 按顺序执行',
                      style: TextStyle(
                        fontSize: 12.5,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 10),
                    if (paths.isEmpty)
                      const Text('未配置输出整理插件')
                    else
                      for (var i = 0; i < paths.length; i++) ...[
                        ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          leading: Container(
                            width: 26,
                            height: 26,
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              color: scheme.primary.withValues(alpha: 0.12),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Text(
                              '${i + 1}',
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                                color: scheme.primary,
                              ),
                            ),
                          ),
                          title: Text(
                            _pluginTitleFor(paths[i]),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            paths[i],
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing: Icon(
                            loadedPaths.contains(paths[i])
                                ? Icons.check_circle
                                : Icons.error_outline,
                            size: 18,
                            color: loadedPaths.contains(paths[i])
                                ? scheme.primary
                                : scheme.error,
                          ),
                        ),
                      ],
                    const Divider(height: 24),
                    Text(
                      '本轮调用反馈（${records.length} 条）',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: scheme.primary,
                      ),
                    ),
                    const SizedBox(height: 6),
                    if (records.isEmpty)
                      Text(
                        '本轮还没有插件调用记录（插件只在 LLM 请求/响应链路里触发）。',
                        style: TextStyle(
                          fontSize: 12.5,
                          color: scheme.onSurfaceVariant,
                        ),
                      )
                    else ...[
                      for (final r in shown) _recordTile(r, scheme),
                      if (count < records.length)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          child: Center(
                            child: Text(
                              '继续下滑加载更多…',
                              style: TextStyle(
                                fontSize: 12,
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                        ),
                    ],
                    if (service.lastError != null) ...[
                      const SizedBox(height: 8),
                      Text(
                        '加载错误：${service.lastError}',
                        style: TextStyle(fontSize: 12, color: scheme.error),
                      ),
                    ],
                  ],
                ),
              ),
            );
          },
        ),
      ),
    ).whenComplete(visible.dispose);
  }

  Widget _recordTile(OutputPluginRunRecord r, ColorScheme scheme) {
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      onTap: () => _showPluginRecordDetail(r),
      leading: Icon(
        switch (r.status) {
          'ran' => Icons.play_circle_fill,
          'skipped' => Icons.skip_next,
          'error' => Icons.error_outline,
          _ => Icons.info_outline,
        },
        size: 18,
        color: switch (r.status) {
          'ran' => scheme.primary,
          'skipped' => scheme.onSurfaceVariant,
          'error' => scheme.error,
          _ => scheme.onSurfaceVariant,
        },
      ),
      title: Text(
        '${r.name} · ${r.hook}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        '${r.status}：${r.detail}',
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: const Icon(Icons.chevron_right, size: 18),
    );
  }

  /// 单条记录详情：原始内容 + 插件输出（skipped/error 只展示原始内容）。
  void _showPluginRecordDetail(OutputPluginRunRecord r) {
    final scheme = Theme.of(context).colorScheme;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.8,
        maxChildSize: 0.95,
        minChildSize: 0.45,
        builder: (context, scrollController) => Container(
          decoration: BoxDecoration(
            color: scheme.surface,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          ),
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          child: ListView(
            controller: scrollController,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '${r.name} · ${r.hook}',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: scheme.onSurface,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.pop(sheetContext),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  _statusChip(r.status, scheme),
                  Chip(
                    label: Text(r.hook, style: const TextStyle(fontSize: 11)),
                    visualDensity: VisualDensity.compact,
                  ),
                ],
              ),
              const SizedBox(height: 10),
              _pluginResponseView('原始内容（插件看到的内容）', r.original, scheme),
              if (r.result != null) ...[
                const SizedBox(height: 12),
                _pluginResponseView('插件输出 / 工具调用结果', r.result!, scheme),
              ] else ...[
                const SizedBox(height: 10),
                Text(
                  r.status == 'skipped'
                      ? '该插件没有定义这个 hook，已跳过。上面是原始内容。'
                      : '该 hook 执行失败，上面是原始内容。',
                  style: TextStyle(
                    fontSize: 12.5,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
              const SizedBox(height: 8),
              SelectableText(
                '路径：${r.path}\n时间：${r.at.toLocal()}',
                style: TextStyle(
                  fontSize: 11.5,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 插件 processResponse 记录详情：把 content / reasoning / toolCalls 分开显示，
  /// 避免“正文是空的、只有思考内容”时看不出插件到底处理了什么。
  Widget _pluginResponseView(String title, String text, ColorScheme scheme) {
    Object? decoded;
    try {
      decoded = jsonDecode(text);
    } catch (_) {}
    if (decoded is! Map<String, dynamic>) {
      return _rawSection(title, text, scheme);
    }
    final map = decoded;
    final content = map['content']?.toString() ?? '';
    final reasoning = map['reasoning']?.toString() ?? '';
    final tools = map['toolCalls'];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w700,
            color: scheme.onSurface,
          ),
        ),
        const SizedBox(height: 6),
        _kvSection('正文 content', content, scheme),
        const SizedBox(height: 8),
        _kvSection('思考 reasoning', reasoning, scheme),
        const SizedBox(height: 8),
        _kvSection(
          '工具调用 toolCalls',
          tools == null
              ? '（无）'
              : const JsonEncoder.withIndent('  ').convert(tools),
          scheme,
        ),
      ],
    );
  }

  Widget _kvSection(String label, String text, ColorScheme scheme) {
    final display = text.trim().isEmpty ? '（空）' : text;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 4),
          SelectableText(
            display,
            style: TextStyle(
              fontFamily: 'monospace',
              fontSize: 11.5,
              height: 1.35,
              color: scheme.onSurface,
            ),
          ),
        ],
      ),
    );
  }

  Widget _statusChip(String status, ColorScheme scheme) {
    final (label, color, icon) = switch (status) {
      'ran' => ('执行成功', scheme.primary, Icons.play_circle_fill),
      'skipped' => ('已跳过', scheme.onSurfaceVariant, Icons.skip_next),
      'error' => ('执行失败', scheme.error, Icons.error_outline),
      _ => ('信息', scheme.onSurfaceVariant, Icons.info_outline),
    };
    return Chip(
      avatar: Icon(icon, size: 15, color: color),
      label: Text(label, style: TextStyle(fontSize: 11, color: color)),
      visualDensity: VisualDensity.compact,
    );
  }

  Widget _rawSection(String title, String text, ColorScheme scheme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w700,
            color: scheme.onSurface,
          ),
        ),
        const SizedBox(height: 6),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest.withValues(alpha: 0.45),
            borderRadius: BorderRadius.circular(12),
          ),
          child: SelectableText(
            text,
            style: TextStyle(
              fontFamily: 'monospace',
              fontSize: 11.5,
              height: 1.35,
              color: scheme.onSurface,
            ),
          ),
        ),
      ],
    );
  }

  String _pluginTitleFor(String path) {
    for (final p in OutputPluginService.instance.plugins) {
      if (p.path == path && p.name.isNotEmpty) return p.name;
    }
    return path.split('/').last;
  }

  void _showAudit() {
    final sessionId = ref.read(chatProvider).currentSessionId;
    ref.read(auditProvider.notifier).load(sessionId);
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) {
        final audit = ref.watch(auditProvider);
        return DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.7,
          maxChildSize: 0.95,
          builder: (context, scrollController) {
            final logs = audit.logs;
            final scheme = Theme.of(context).colorScheme;
            return Column(
              children: [
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(
                    'AI / QL 操作审计',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: scheme.onSurface,
                    ),
                  ),
                ),
                Expanded(
                  child: logs.isEmpty
                      ? Center(
                          child: Text(
                            '暂无审计记录',
                            style: TextStyle(color: scheme.onSurfaceVariant),
                          ),
                        )
                      : ListView.builder(
                          controller: scrollController,
                          itemCount: logs.length,
                          padding: const EdgeInsets.fromLTRB(12, 0, 12, 24),
                          itemBuilder: (context, index) {
                            final log = logs[index];
                            return Card(
                              child: ListTile(
                                title: Text(
                                  '${log.action} · ${log.result}',
                                  style: TextStyle(color: scheme.onSurface),
                                ),
                                subtitle: Text(
                                  '${log.module}｜${log.detail}',
                                  style:
                                      TextStyle(color: scheme.onSurfaceVariant),
                                ),
                                trailing: Text(
                                  '${log.time.hour.toString().padLeft(2, '0')}:${log.time.minute.toString().padLeft(2, '0')}',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: scheme.onSurfaceVariant,
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    // 消息新增、流式回复变长、工具时间线增加，都要跟到底。
    ref.listen<ChatState>(chatProvider, (previous, next) {
      if (previous == null) return;
      final changed = previous.messages.length != next.messages.length ||
          previous.liveAgentEvents.length != next.liveAgentEvents.length ||
          previous.messages.lastOrNull?.content.length !=
              next.messages.lastOrNull?.content.length ||
          previous.pendingQuestion != next.pendingQuestion ||
          previous.pendingPlan.length != next.pendingPlan.length;
      // 流式文字每 80ms 长一截。它只让最后那张卡内部变高，
      // 卡自己会贴着底显示最新一行，这里只需要把列表跟到底。
      final streaming =
          previous.liveReasoningChars != next.liveReasoningChars ||
              previous.liveContentChars != next.liveContentChars ||
              previous.liveTool != next.liveTool;
      if (changed || streaming) _followTail();
    });
    final state = ref.watch(chatProvider);
    final notifier = ref.read(chatProvider.notifier);
    final scheme = Theme.of(context).colorScheme;
    // 附件与悬浮窗共用一份：composePrompt 也只认这一份。
    // 只订阅 chips：整份 dock state 里还有悬浮球坐标，拖球时会每帧变，
    // 照它重建的话整个 AI 页跟着一帧一次重绘。
    final chips = ref.watch(aiDockProvider.select((s) => s.chips));

    final mcpCount = ref.watch(mcpProvider).tools.length;
    final skillCount = ref.watch(skillProvider).enabled.length;

    return Stack(
      children: [
        GestureDetector(
          // 半屏文件面板：右滑打开，再左滑收起；面板打开时不挡右侧聊天区。
          behavior: HitTestBehavior.translucent,
          onHorizontalDragStart: (details) {
            _fileDragStartDx = details.globalPosition.dx;
          },
          onHorizontalDragEnd: (details) {
            final velocity = details.primaryVelocity ?? 0;
            // 从屏幕最左边沿开始的手势让给系统返回；离边稍远再右滑才开面板。
            if (!_filePanelOpen && velocity > 300 && _fileDragStartDx > 60) {
              _openFilePanel();
            }
            if (_filePanelOpen && velocity < -300) _closeFilePanel();
          },
          child: GlassScaffold(
            title: 'AI 助手',
            subtitle: [
              state.selectedModel.isEmpty ? '未选择模型' : state.selectedModel,
              if (skillCount > 0) '$skillCount 技能',
              if (mcpCount > 0) '$mcpCount MCP 工具',
            ].join(' · '),
            actions: [
              // 会话用量：贴着浏览器按钮左边，半透明、不抢戏，但一直在动。
              const Padding(
                padding: EdgeInsets.only(right: 2),
                child: SessionUsageChip(),
              ),
              // 浏览器入口：常驻内核，点开就是个正常浏览器（悬浮窗，可拖可缩放）。
              // 登录、Cloudflare 人机验证都在这里手动点掉——AI 用的是同一个内核，
              // 所以你验证过一次，它后面调接口就一直带着票。
              ValueListenableBuilder<bool>(
                valueListenable: BrowserEngine.instance.visible,
                builder: (context, visible, _) => IconButton(
                  tooltip: visible ? '浏览器已打开' : '打开浏览器（登录 / 过人机验证）',
                  onPressed: () => visible
                      ? BrowserEngine.instance.hide()
                      : BrowserEngine.instance.show(),
                  icon: Icon(
                    visible ? Icons.public : Icons.public_outlined,
                    color: visible ? scheme.primary : null,
                  ),
                ),
              ),
              IconButton(
                tooltip: '会话列表',
                onPressed: _showSessionManager,
                icon: const Icon(Icons.forum_outlined),
              ),
              IconButton(
                tooltip: OutputPluginService.instance.lastError == null
                    ? '输出插件状态'
                    : '输出插件加载失败，点开看详情',
                onPressed: _showPluginFeedback,
                icon: Icon(
                  Icons.auto_fix_high_outlined,
                  color: OutputPluginService.instance.lastError == null
                      ? null
                      : Theme.of(context).colorScheme.error,
                ),
              ),
              IconButton(
                tooltip: '审计记录',
                onPressed: _showAudit,
                icon: const Icon(Icons.receipt_long_outlined),
              ),
              PopupMenuButton<String>(
                tooltip: '更多',
                icon: const Icon(Icons.more_vert),
                onSelected: (value) {
                  switch (value) {
                    case 'approval':
                      AiControlSheets.showApproval(context);
                    case 'context':
                      AiControlSheets.showContext(context, ref);
                    case 'skills':
                      Navigator.of(context).push(
                        MaterialPageRoute(
                            builder: (_) => const SkillListPage()),
                      );
                    case 'mcp':
                      Navigator.of(context).push(
                        MaterialPageRoute(
                            builder: (_) => const McpServerPage()),
                      );
                    case 'new':
                      if (_editMode) _cancelEdit();
                      notifier.createSession();
                    case 'clear':
                      if (_editMode) _cancelEdit();
                      notifier.clear();
                  }
                },
                itemBuilder: (context) => [
                  PopupMenuItem(
                    value: 'approval',
                    child: ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.verified_user_outlined),
                      title: const Text('确认策略'),
                      subtitle: Text(state.approvalMode.label),
                    ),
                  ),
                  const PopupMenuItem(
                    value: 'context',
                    child: ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(Icons.data_usage_outlined),
                      title: Text('上下文与压缩'),
                    ),
                  ),
                  PopupMenuItem(
                    value: 'skills',
                    child: ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.auto_stories_outlined),
                      title: const Text('技能库'),
                      subtitle: Text('$skillCount 个已启用'),
                    ),
                  ),
                  PopupMenuItem(
                    value: 'mcp',
                    child: ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.extension_outlined),
                      title: const Text('MCP 扩展'),
                      subtitle: Text(mcpCount == 0 ? '未接入' : '$mcpCount 个工具'),
                    ),
                  ),
                  const PopupMenuItem(
                    value: 'new',
                    child: ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(Icons.add_comment_outlined),
                      title: Text('新建会话'),
                    ),
                  ),
                  const PopupMenuItem(
                    value: 'clear',
                    child: ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(Icons.delete_sweep_outlined),
                      title: Text('清空当前会话'),
                    ),
                  ),
                ],
              ),
            ],
            body: DragTarget<ShellFileDragData>(
              onAcceptWithDetails: (details) =>
                  _attachDraggedFile(details.data),
              builder: (context, candidate, rejected) => Column(
                children: [
                  Expanded(
                    child: state.messages.isEmpty
                        ? _WelcomeView(
                            onTap: (text) {
                              // 走 _send 而不是直接 send：不然示例问句会把已挂的附件丢掉。
                              _controller.text = text;
                              _send();
                            },
                          )
                        : Builder(
                            builder: (context) {
                              final hasLive = state.liveAgentEvents.isNotEmpty;
                              final hasLivePlan = state.livePlan.isNotEmpty;
                              // 请求已发出但一个字都还没回来时也占一格：那正是最需要
                              // "它在动"这个信号的几秒钟。
                              final hasStream = state.isLoading;
                              final extraCount = (hasLivePlan ? 1 : 0) +
                                  (hasLive ? 1 : 0) +
                                  (hasStream ? 1 : 0) +
                                  1;
                              return TapRegionSurface(
                                  child: ListView.builder(
                                key: _listKey,
                                controller: _scrollController,
                                padding:
                                    const EdgeInsets.fromLTRB(12, 12, 12, 4),
                                itemCount: state.messages.length + extraCount,
                                itemBuilder: (context, index) {
                                  if (index < state.messages.length) {
                                    final message = state.messages[index];
                                    final frozenBelow = _editMode &&
                                        _editIndex != null &&
                                        index > _editIndex!;
                                    final isQuoteTarget =
                                        _followUpIndex == index;
                                    final isQuoteFlash =
                                        _followUpFlashIndex == index;
                                    final bubbleChild = GestureDetector(
                                      behavior: HitTestBehavior.opaque,
                                      onLongPress: state.isLoading
                                          ? null
                                          : () => _showMessageActions(
                                              index, message),
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          _MessageBubble(
                                            message: message,
                                            anchorIndex: index,
                                            selectable:
                                                _selectableIndex == index,
                                            onResend: state.isLoading
                                                ? null
                                                : () =>
                                                    notifier.resendAt(index),
                                            onRollback: state.isLoading
                                                ? null
                                                : () => _rollbackTo(index),
                                            onSuggestionTap: (text) {
                                              _controller.text = text;
                                              _send();
                                            },
                                          ),
                                        ],
                                      ),
                                    );
                                    final highlightedChild = AnimatedContainer(
                                      duration:
                                          const Duration(milliseconds: 320),
                                      curve: Curves.easeOut,
                                      decoration: BoxDecoration(
                                        color: isQuoteFlash
                                            ? scheme.primary
                                                .withValues(alpha: 0.28)
                                            : isQuoteTarget
                                                ? scheme.primary
                                                    .withValues(alpha: 0.12)
                                                : Colors.transparent,
                                        borderRadius: BorderRadius.circular(18),
                                        border: Border.all(
                                          color: isQuoteFlash
                                              ? scheme.primary
                                              : isQuoteTarget
                                                  ? scheme.primary
                                                      .withValues(alpha: 0.55)
                                                  : Colors.transparent,
                                          width: isQuoteFlash ? 2 : 1.2,
                                        ),
                                      ),
                                      child: bubbleChild,
                                    );
                                    final messageItem = RepaintBoundary(
                                      key: _bubbleKeyAt(index),
                                      child: frozenBelow
                                          ? IgnorePointer(
                                              child: Opacity(
                                                opacity: 0.38,
                                                child: highlightedChild,
                                              ),
                                            )
                                          : highlightedChild,
                                    );
                                    if (_selectableIndex != index) {
                                      return messageItem;
                                    }
                                    return TapRegion(
                                      groupId:
                                          const ValueKey('ai_text_selection'),
                                      onTapOutside: (_) {
                                        if (!mounted) return;
                                        if (_selectableIndex == index) {
                                          setState(
                                              () => _selectableIndex = null);
                                        }
                                      },
                                      child: messageItem,
                                    );
                                  }
                                  var slot = index - state.messages.length;
                                  if (hasLivePlan) {
                                    if (slot == 0) {
                                      // 下面紧跟过程卡（它只有 bottom margin），
                                      // 所以这里必须自己留下边距，否则两张卡贴在一起。
                                      return RepaintBoundary(
                                        child: _editMode
                                            ? IgnorePointer(
                                                child: Opacity(
                                                  opacity: 0.38,
                                                  child: TaskPlanCard(
                                                    plan: state.livePlan,
                                                    margin:
                                                        const EdgeInsets.only(
                                                      bottom: 8,
                                                    ),
                                                  ),
                                                ),
                                              )
                                            : TaskPlanCard(
                                                plan: state.livePlan,
                                                margin: const EdgeInsets.only(
                                                  bottom: 8,
                                                ),
                                              ),
                                      );
                                    }
                                    slot -= 1;
                                  }
                                  if (hasLive) {
                                    if (slot == 0) {
                                      return RepaintBoundary(
                                        child: _editMode
                                            ? IgnorePointer(
                                                child: Opacity(
                                                  opacity: 0.38,
                                                  child: AgentProcessCard(
                                                    events:
                                                        state.liveAgentEvents,
                                                    running: state.isLoading,
                                                    modeLabels:
                                                        state.liveModeLabels,
                                                    initiallyExpanded: state
                                                            .isLoading ||
                                                        state.liveAgentEvents
                                                            .any(
                                                          (e) =>
                                                              e.kind ==
                                                                  AgentEventKind
                                                                      .toolImage &&
                                                              e.imageDataUri !=
                                                                  null,
                                                        ),
                                                    totalTokens:
                                                        state.lastTokens,
                                                    liveSubagentReasoning: state
                                                        .liveSubagentReasoning,
                                                    liveSubagentContent: state
                                                        .liveSubagentContent,
                                                    liveSubagentTool:
                                                        state.liveSubagentTool,
                                                    liveSubagentReasoningChars:
                                                        state
                                                            .liveSubagentReasoningChars,
                                                    liveSubagentContentChars: state
                                                        .liveSubagentContentChars,
                                                  ),
                                                ),
                                              )
                                            : AgentProcessCard(
                                                events: state.liveAgentEvents,
                                                running: state.isLoading,
                                                modeLabels:
                                                    state.liveModeLabels,
                                                initiallyExpanded: state
                                                        .isLoading ||
                                                    state.liveAgentEvents.any(
                                                      (e) =>
                                                          e.kind ==
                                                              AgentEventKind
                                                                  .toolImage &&
                                                          e.imageDataUri !=
                                                              null,
                                                    ),
                                                totalTokens: state.lastTokens,
                                                liveSubagentReasoning:
                                                    state.liveSubagentReasoning,
                                                liveSubagentContent:
                                                    state.liveSubagentContent,
                                                liveSubagentTool:
                                                    state.liveSubagentTool,
                                                liveSubagentReasoningChars: state
                                                    .liveSubagentReasoningChars,
                                                liveSubagentContentChars: state
                                                    .liveSubagentContentChars,
                                              ),
                                      );
                                    }
                                    slot -= 1;
                                  }
                                  if (hasStream && slot == 0) {
                                    final streamCard = AgentStreamCard(
                                      reasoning: state.liveReasoning,
                                      content: state.liveContent,
                                      reasoningChars: state.liveReasoningChars,
                                      contentChars: state.liveContentChars,
                                      tool: state.liveTool,
                                    );
                                    return RepaintBoundary(
                                      child: _editMode
                                          ? IgnorePointer(
                                              child: Opacity(
                                                opacity: 0.38,
                                                child: streamCard,
                                              ),
                                            )
                                          : streamCard,
                                    );
                                  }
                                  return RepaintBoundary(
                                    child: _editMode
                                        ? IgnorePointer(
                                            child: Opacity(
                                              opacity: 0.38,
                                              child: _buildTail(context, state),
                                            ),
                                          )
                                        : _buildTail(context, state),
                                  );
                                },
                              ));
                            },
                          ),
                  ),
                  // 往上翻过就出现这个按钮：不用一路滑回去。
                  if (!_pinned && state.messages.isNotEmpty)
                    Align(
                      alignment: Alignment.centerRight,
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(0, 0, 14, 6),
                        child: GlassPill(
                          icon: Icons.arrow_downward_rounded,
                          label: state.isLoading ? '跟随最新' : '回到最新',
                          color: scheme.primary,
                          dense: true,
                          onTap: () {
                            setState(() => _pinned = true);
                            _scrollToBottom();
                          },
                        ),
                      ),
                    ),
                  // 错误条只在"错误没能挂到某条消息上"时才出现（比如拉模型列表失败）。
                  // 发送失败已经在那条用户消息下面标红了，两处都画等于报两次错。
                  if (state.error != null &&
                      !(state.currentSession?.messages
                              .any((m) => m.failedToSend) ??
                          false))
                    Container(
                      width: double.infinity,
                      margin: const EdgeInsets.fromLTRB(12, 0, 12, 6),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 8),
                      decoration: BoxDecoration(
                        color: scheme.errorContainer,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.error_outline,
                              size: 17, color: scheme.onErrorContainer),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              errorText(state.error!),
                              style: TextStyle(
                                fontSize: 12.5,
                                color: scheme.onErrorContainer,
                              ),
                              maxLines: 3,
                            ),
                          ),
                        ],
                      ),
                    ),
                  // "AI 在等你回答"常驻条：提问卡在列表末尾，用户往上翻就看不见了，
                  // 而这时候不答任务就一直挂着。点一下跳到那张卡。
                  if (state.pendingQuestion != null && !_pinned)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(10),
                        onTap: () {
                          setState(() => _pinned = true);
                          _scrollToBottom();
                        },
                        child: Container(
                          width: double.infinity,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 8,
                          ),
                          decoration: BoxDecoration(
                            color: scheme.primary.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(
                              color: scheme.primary.withValues(alpha: 0.45),
                            ),
                          ),
                          child: Row(
                            children: [
                              Icon(Icons.help_outline,
                                  size: 16, color: scheme.primary),
                              const SizedBox(width: 6),
                              Expanded(
                                child: Text(
                                  'AI 在等你回答：${state.pendingQuestion!.question}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                    color: scheme.primary,
                                  ),
                                ),
                              ),
                              Icon(Icons.arrow_downward_rounded,
                                  size: 15, color: scheme.primary),
                            ],
                          ),
                        ),
                      ),
                    ),
                  // 清单常驻在输入框上方：跑长任务时不用往上翻就知道到第几步。
                  if (state.livePlan.isNotEmpty)
                    TaskPlanStrip(
                        plan: state.livePlan, running: state.isLoading),
                  if (state.interruptedRun != null)
                    ResumeStrip(
                      run: state.interruptedRun!,
                      onResume: notifier.resumeInterruptedRun,
                      onDiscard: notifier.discardInterruptedRun,
                    ),
                  QueueStrip(
                    queue: [
                      for (final q in state.queue)
                        if (q.sessionId == state.currentSessionId) q,
                    ],
                    onReorder: notifier.reorderQueue,
                    onRemove: notifier.dequeue,
                    onInterruptSend: notifier.interruptAndSend,
                  ),
                  // 待发送图片条。
                  PendingImageBar(
                    images: state.pendingImages,
                    onRemove: notifier.removePendingImage,
                  ),
                  // 模式库标签条：发送时这些模式内容会注入本次提示词。
                  if (state.pendingModeIds.isNotEmpty)
                    _buildPendingModeChips(state),
                  // 输入框打 / 后弹出的模式选择条。
                  if (_modePickerKeyword.isNotEmpty) _buildModePicker(),
                  // 附件条。用的是悬浮窗那份 chips：两边共享同一个会话，
                  // 附件当然也得是同一份，否则在这里加的附件发出去不带上。
                  if (chips.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(14, 0, 14, 4),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          children: [
                            for (var i = 0; i < chips.length; i++)
                              InputChip(
                                visualDensity: VisualDensity.compact,
                                avatar: Icon(
                                  chips[i].readOnly
                                      ? Icons.visibility_outlined
                                      : Icons.attachment,
                                  size: 14,
                                ),
                                label: Text(
                                  chips[i].label,
                                  style: const TextStyle(fontSize: 11.5),
                                ),
                                onDeleted: () => ref
                                    .read(aiDockProvider.notifier)
                                    .removeChip(i),
                              ),
                          ],
                        ),
                      ),
                    ),
                  // 不用 SafeArea：它会照系统小白条的完整高度（这台机 ~48px）
                  // 往上垫一整条，输入框下面就空出一条谁也用不上的带子。
                  // 手势条本身是半透明浮层，压在它上面并不影响操作，
                  // 所以只留它的 1/4 作为呼吸位。
                  Padding(
                    padding: EdgeInsets.only(
                      bottom: MediaQuery.paddingOf(context).bottom * 0.25,
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (_followUpIndex != null && !_editMode)
                          _QuoteFollowUpBar(
                            text: _followUpText ?? '',
                            suggestions: _followUpIndex! < state.messages.length
                                ? state.messages[_followUpIndex!].suggestions
                                : const [],
                            onJump: _jumpToFollowUpTarget,
                            onClose: _closeFollowUp,
                            onSuggestionSend: _sendQuoteSuggestion,
                          ),
                        if (_editMode)
                          _EditModeStatusBar(onCancel: _cancelEdit),
                        AiComposer(
                          state: state,
                          controller: _controller,
                          onChanged: _onInputChanged,
                          onSend: _send,
                          onStop: notifier.stopAgent,
                          onModelTap: () =>
                              AiControlSheets.showModelPicker(context),
                          onStrengthTap: () =>
                              AiControlSheets.showStrength(context),
                          onContextTap: () =>
                              AiControlSheets.showContext(context, ref),
                          onApprovalTap: () =>
                              AiControlSheets.showApproval(context),
                          onAttach: _pickFile,
                          onExpand: _openExpandedEditor,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        _buildFilePanel(),
      ],
    );
  }

  /// 从左侧文件管理面板拖进来的文件/文件夹，按附件处理。
  Future<void> _attachDraggedFile(ShellFileDragData data) async {
    final entry = data.entry;
    final scope = data.scope;
    try {
      if (entry.isDirectory) {
        ref.read(aiDockProvider.notifier).pushFile(
              path: entry.path,
              name: entry.name,
              content: '文件夹路径：${entry.path}\n',
              language: null,
              truncated: false,
              open: false,
            );
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('已附上文件夹引用 ${entry.name}'),
            duration: const Duration(seconds: 1),
          ),
        );
        return;
      }
      final kind = FileKinds.of(entry.name);
      if (kind.category == FileCategory.image) {
        final bridge = ProotBridge();
        final host = await bridge.hostPath(path: entry.path, scope: scope);
        final bytes = await File(host).readAsBytes();
        if (bytes.isEmpty) {
          throw Exception('图片内容为空');
        }
        final image = AiImageAttachment(
          name: entry.name,
          mime: FileKinds.mimeOf(entry.name),
          dataUri:
              'data:${FileKinds.mimeOf(entry.name)};base64,${base64Encode(bytes)}',
          path: entry.path,
          scope: scope,
        );
        ref.read(chatProvider.notifier).addPendingImage(image);
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('已附上图片 ${entry.name}'),
            duration: const Duration(seconds: 1),
          ),
        );
        return;
      }
      if (!kind.isTextLike) {
        // 二进制文件（ZIP/APK/可执行等）不能当正文喂给 AI，附路径引用。
        ref.read(aiDockProvider.notifier).pushFile(
              path: entry.path,
              name: entry.name,
              content: '文件路径：${entry.path}\n'
                  '（二进制文件，未读取内容）',
              language: null,
              truncated: false,
              open: false,
            );
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('已附上文件引用 ${entry.name}'),
            duration: const Duration(seconds: 1),
          ),
        );
        return;
      }
      final bridge = ProotBridge();
      final raw = await bridge.readFile(path: entry.path, scope: scope);
      final truncated = raw.length > 20000;
      ref.read(aiDockProvider.notifier).pushFile(
            path: entry.path,
            name: entry.name,
            content: truncated ? raw.substring(0, 20000) : raw,
            language: kind.language,
            truncated: truncated,
            open: false,
          );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('已附上 ${entry.name}'),
          duration: const Duration(seconds: 1),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('附件添加失败：$e')),
      );
    }
  }

  /// 左侧半屏文件管理面板：右滑出来、左滑/右上角收起。
  /// 点击文本/代码文件时用悬浮编辑器打开，不离开 AI 页面。
  Widget _buildFilePanel() {
    final size = MediaQuery.sizeOf(context);
    final scheme = Theme.of(context).colorScheme;
    final panelWidth = size.width * _filePanelFraction;
    return AnimatedPositioned(
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
      left: _filePanelOpen ? 0 : -panelWidth - 12,
      top: 0,
      bottom: 0,
      width: panelWidth,
      child: Material(
        color: Colors.transparent,
        child: ClipRRect(
          borderRadius: const BorderRadius.horizontal(
            right: Radius.circular(20),
          ),
          child: BackdropFilter(
            filter: ImageFilter.blur(
                sigmaX: Glass.blurStrong, sigmaY: Glass.blurStrong),
            child: Container(
              color: scheme.surface.withValues(alpha: 0.96),
              child: Stack(
                children: [
                  // 左滑收回的范围包含整个已经展开的半屏，不只在右边缝上触发。
                  GestureDetector(
                    behavior: HitTestBehavior.translucent,
                    onHorizontalDragEnd: (details) {
                      if ((details.primaryVelocity ?? 0) < -300) {
                        _closeFilePanel();
                      }
                    },
                    child: ShellFilesPage(
                      asSheet: true,
                      floatingEditor: true,
                      dragToAttachEnabled: true,
                      onClose: _closeFilePanel,
                      closeIcon: Icons.arrow_back_ios_new_rounded,
                    ),
                  ),
                  // 右缘中间的小白条：按住左右拉可改面板宽度，松开固定。
                  Positioned(
                    right: 0,
                    top: 0,
                    bottom: 0,
                    child: Align(
                      alignment: Alignment.center,
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onHorizontalDragStart: (_) {
                          HapticFeedback.lightImpact();
                        },
                        onHorizontalDragUpdate: (details) {
                          final delta = details.delta.dx / size.width;
                          setState(() {
                            _filePanelFraction =
                                (_filePanelFraction + delta).clamp(0.4, 0.95);
                          });
                        },
                        onHorizontalDragEnd: (_) {
                          HapticFeedback.selectionClick();
                          _saveFilePanelFraction();
                        },
                        child: Container(
                          width: 5,
                          height: 76,
                          decoration: BoxDecoration(
                            color: Theme.of(context)
                                .colorScheme
                                .onSurfaceVariant
                                .withValues(alpha: 0.5),
                            borderRadius: BorderRadius.circular(3),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _WelcomeView extends StatelessWidget {
  const _WelcomeView({required this.onTap});

  final ValueChanged<String> onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    const examples = <(IconData, String, String)>[
      (Icons.list_alt_outlined, '看看现在有哪些任务', '现在有哪些任务？分别多久跑一次'),
      (Icons.bug_report_outlined, '排查某个任务为什么失败', '帮我看看最近失败的任务，读日志分析原因'),
      (Icons.code_outlined, '写个签到脚本并建任务', '帮我写个脚本每天 8 点签到，并创建对应定时任务'),
      (
        Icons.terminal_outlined,
        '在本机 Debian 里跑命令',
        '在本机 Debian 里看看 python 版本和 /workspace 有什么'
      ),
    ];
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 32, 20, 12),
      children: [
        Center(
          child: Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              color: scheme.primaryContainer.withValues(alpha: 0.85),
              shape: BoxShape.circle,
            ),
            child: ClipOval(
              child: Image.asset(
                'assets/images/app_icon.png',
                width: 64,
                height: 64,
                fit: BoxFit.cover,
              ),
            ),
          ),
        ),
        const SizedBox(height: 10),
        const Center(
          child: Text(
            '青龙专用 AI 助手',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
          ),
        ),
        const SizedBox(height: 4),
        Center(
          child: Text(
            '会自己查证再回答，改东西之前按策略征求你的同意',
            style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant),
            textAlign: TextAlign.center,
          ),
        ),
        const SizedBox(height: 16),
        for (final (icon, title, prompt) in examples)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Material(
              // 半透：背景那三团流动的光斑要能透过示例卡。
              color: scheme.surfaceContainerLow.withValues(alpha: 0.55),
              borderRadius: BorderRadius.circular(12),
              child: InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: () => onTap(prompt),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 9,
                  ),
                  child: Row(
                    children: [
                      Icon(icon, size: 19, color: scheme.primary),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              title,
                              style: const TextStyle(
                                fontSize: 13.5,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              prompt,
                              style: TextStyle(
                                fontSize: 11.5,
                                color: scheme.onSurfaceVariant,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                      Icon(
                        Icons.north_west,
                        size: 15,
                        color: scheme.onSurfaceVariant,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// 修改模式顶在输入框上方的状态条：只提示“修改中”，右侧 X 取消修改。
class _EditModeStatusBar extends StatelessWidget {
  const _EditModeStatusBar({required this.onCancel});

  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final tint = scheme.tertiaryContainer;
    final fg = scheme.onTertiaryContainer;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(10, 0, 10, 6),
      padding: const EdgeInsets.only(left: 12, right: 2, top: 2, bottom: 2),
      decoration: BoxDecoration(
        color: tint.withValues(alpha: 0.9),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: scheme.tertiary.withValues(alpha: 0.6)),
      ),
      child: Row(
        children: [
          Icon(Icons.edit_rounded, size: 16, color: fg),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              '当前正在修改中',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: fg,
              ),
            ),
          ),
          IconButton(
            tooltip: '取消修改',
            visualDensity: VisualDensity.compact,
            icon: Icon(Icons.close_rounded, size: 18, color: fg),
            onPressed: onCancel,
          ),
        ],
      ),
    );
  }
}

/// 引用追问条：显示在主输入框上方，点击左侧图标可跳到被追问消息并闪烁提示。
class _QuoteFollowUpBar extends StatelessWidget {
  const _QuoteFollowUpBar({
    required this.text,
    required this.suggestions,
    required this.onJump,
    required this.onClose,
    required this.onSuggestionSend,
  });

  final String text;
  final List<String> suggestions;
  final VoidCallback onJump;
  final VoidCallback onClose;
  final ValueChanged<String> onSuggestionSend;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(10, 0, 10, 6),
      padding: const EdgeInsets.fromLTRB(4, 6, 8, 6),
      decoration: BoxDecoration(
        color: scheme.primaryContainer.withValues(alpha: 0.85),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: scheme.primary.withValues(alpha: 0.45)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              IconButton(
                tooltip: '跳到追问消息',
                visualDensity: VisualDensity.compact,
                icon: Icon(Icons.near_me_rounded,
                    size: 16, color: scheme.primary),
                onPressed: onJump,
              ),
              const SizedBox(width: 2),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '引用追问',
                      style: TextStyle(
                        fontSize: 10.5,
                        fontWeight: FontWeight.w700,
                        color: scheme.primary,
                      ),
                    ),
                    const SizedBox(height: 1),
                    Text(
                      text,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11.5,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: '取消追问',
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.close_rounded, size: 17),
                onPressed: onClose,
              ),
            ],
          ),
          if (suggestions.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 2, 0, 0),
              child: Wrap(
                spacing: 6,
                runSpacing: 4,
                children: [
                  for (final s in suggestions)
                    ActionChip(
                      visualDensity: VisualDensity.compact,
                      label: Text(s),
                      onPressed: () => onSuggestionSend(s),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// 整轮完成后 AI 给出的“下一步”快捷建议，点一下就把这句话发出去。
class _SuggestionChips extends StatelessWidget {
  const _SuggestionChips({
    required this.suggestions,
    required this.onTap,
  });

  final List<String> suggestions;
  final ValueChanged<String> onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 6, bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 2, bottom: 4),
            child: Text(
              '下一步建议 · 最终由你决定',
              style: TextStyle(
                fontSize: 11.5,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              for (final s in suggestions)
                ActionChip(
                  avatar: Icon(
                    Icons.arrow_forward_rounded,
                    size: 15,
                    color: scheme.primary,
                  ),
                  label: Text(s),
                  onPressed: () => onTap(s),
                  visualDensity: VisualDensity.compact,
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({
    required this.message,
    this.onResend,
    this.onRollback,
    this.onSuggestionTap,
    this.anchorIndex,
    this.selectable = false,
  });

  final AiChatMessage message;
  final int? anchorIndex;

  /// 是否开启文本选取。默认关闭，避免长按选取抢占长按菜单。
  final bool selectable;

  /// 重发这条（撤回到它之前再重新问一次）。
  final VoidCallback? onResend;

  /// 只撤回，不重发。
  final VoidCallback? onRollback;

  /// 点击“下一步快捷建议”后，把建议文本发送出去。
  final ValueChanged<String>? onSuggestionTap;

  @override
  Widget build(BuildContext context) {
    final isUser = message.isUser;
    final scheme = Theme.of(context).colorScheme;
    final footer = _footer();

    final bubble = ListenableBuilder(
      listenable: ThemeEffectsController.instance,
      builder: (context, _) {
        final page = ModalRoute.of(context)?.settings.name ?? 'default';
        final bubbleStyle = ThemeEffectsController.instance
            .componentStyleFor(page, 'bubble', anchorIndex ?? 0);
        final baseColor =
            isUser ? scheme.primaryContainer : scheme.surfaceContainerLow;
        final br = bubbleStyle?.radius != null
            ? BorderRadius.circular(bubbleStyle!.radius!)
            : BorderRadius.only(
                topLeft: const Radius.circular(16),
                topRight: const Radius.circular(16),
                bottomLeft: Radius.circular(isUser ? 16 : 4),
                bottomRight: Radius.circular(isUser ? 4 : 16),
              );
        final gradientColors = bubbleStyle?.gradientColors ?? [];
        final hasGradient = gradientColors.length >= 2;
        final glow = bubbleStyle?.glowColor != null
            ? [
                BoxShadow(
                  color: (bubbleStyle!.glowColor ?? Colors.transparent)
                      .withValues(alpha: bubbleStyle.glowOpacity ?? 0.6),
                  blurRadius: bubbleStyle.glowRadius ?? 12,
                  spreadRadius: 0,
                ),
              ]
            : const <BoxShadow>[];
        final borderColor = bubbleStyle?.borderColor;
        final borderWidth = bubbleStyle?.borderWidth ?? 1;
        return Align(
          alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
          child: ComponentAnchorTracker(
            type: 'bubble',
            index: anchorIndex ?? 0,
            child: Container(
              margin: const EdgeInsets.only(bottom: 6),
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
              constraints: BoxConstraints(
                maxWidth:
                    MediaQuery.sizeOf(context).width * (isUser ? 0.82 : 0.92),
              ),
              decoration: BoxDecoration(
                color: hasGradient ? null : baseColor,
                gradient: hasGradient
                    ? LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: gradientColors,
                      )
                    : null,
                borderRadius: br,
                border: borderColor != null
                    ? Border.all(
                        color: borderColor,
                        width: borderWidth,
                      )
                    : isUser
                        ? null
                        : Border.all(
                            color: scheme.outlineVariant.withValues(alpha: 0.5),
                          ),
                boxShadow: glow.isEmpty ? null : glow,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (message.images.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final image in message.images)
                            GestureDetector(
                              onTap: () =>
                                  ImagePreviewOverlay.show(context, image),
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(10),
                                child: SizedBox(
                                  width: 112,
                                  height: 112,
                                  child: _MessageImage(image: image),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  if (isUser)
                    if (selectable)
                      SelectableText(
                        message.displayContent.isNotEmpty
                            ? message.displayContent
                            : message.content,
                        style: TextStyle(
                          height: 1.4,
                          color: scheme.onPrimaryContainer,
                        ),
                      )
                    else
                      Text(
                        message.displayContent.isNotEmpty
                            ? message.displayContent
                            : message.content,
                        style: TextStyle(
                          height: 1.4,
                          color: scheme.onPrimaryContainer,
                        ),
                      )
                  else
                    MarkdownMessage(
                      text: message.content.isEmpty
                          ? '_（无文字回复）_'
                          : message.content,
                      selectable: selectable,
                    ),
                  if (!isUser && footer.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Row(
                        children: [
                          Icon(
                            _footerIcon(),
                            size: 12.5,
                            color: _failed()
                                ? scheme.error
                                : scheme.onSurfaceVariant,
                          ),
                          const SizedBox(width: 4),
                          Expanded(
                            child: Text(
                              footer,
                              style: TextStyle(
                                fontSize: 11,
                                color: _failed()
                                    ? scheme.error
                                    : scheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );

    final interactive = bubble;

    if (isUser) {
      // 没发出去的那条：气泡下面一行红字，说清"这句没送到"和为什么。
      // 它不是 AI 的回复，所以不做成气泡；也不进上下文（见 sendError 注释）。
      if (!message.failedToSend) return interactive;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          interactive,
          _SendErrorLine(
            error: message.sendError,
            onRetry: onResend,
          ),
          // 断线前已经跑过的工具留在这里：多轮任务中途失败时，
          // 用户要能看到"断在哪一步"。
          if (message.agentEvents.isNotEmpty)
            AgentProcessCard(
              events: message.agentEvents,
              turns: message.turns,
              totalTokens: message.totalTokens,
              modeLabels: message.modeLabels,
            ),
        ],
      );
    }
    final hasExtras = message.agentEvents.isNotEmpty ||
        message.taskPlan.isNotEmpty ||
        message.canvases.isNotEmpty;
    if (!hasExtras) {
      if (message.suggestions.isEmpty || onSuggestionTap == null) {
        return interactive;
      }
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          interactive,
          _SuggestionChips(
            suggestions: message.suggestions,
            onTap: onSuggestionTap!,
          ),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (message.agentEvents.isNotEmpty)
          AgentProcessCard(
            events: message.agentEvents,
            turns: message.turns,
            totalTokens: message.totalTokens,
            modeLabels: message.modeLabels,
          ),
        if (message.taskPlan.isNotEmpty)
          TaskPlanCard(
            plan: message.taskPlan,
            // 清单卡默认 top:8，但它上面是过程卡（自带 bottom:8）或直接是
            // 列表边缘，两边一起算就成了 16 的空档。这里只留下边距。
            margin: const EdgeInsets.only(bottom: 8),
          ),
        interactive,
        if (message.suggestions.isNotEmpty && onSuggestionTap != null)
          _SuggestionChips(
            suggestions: message.suggestions,
            onTap: onSuggestionTap!,
          ),
        // 弹窗关了内容不会丢：这些卡片一直在，点一下重新打开。
        //
        // margin 必须显式给：默认的 top:8 是"卡在气泡上方"时的间距，
        // 而这里卡在气泡**下方**——气泡自己的 bottom:10 已经把位置占了，
        // 再叠 top:8 反而让卡片贴着下一条用户消息（就是"重叠/贴边"的来源）。
        for (final canvas in message.canvases)
          AiCanvasCard(
            canvas: canvas,
            margin: const EdgeInsets.only(bottom: 10),
          ),
      ],
    );
  }

  bool _failed() =>
      message.outcome == 'failed' || message.outcome == 'cancelled';

  IconData _footerIcon() => switch (message.outcome) {
        'failed' => Icons.error_outline,
        'cancelled' => Icons.stop_circle_outlined,
        'exhausted' => Icons.hourglass_empty,
        'awaitingConfirm' => Icons.pan_tool_outlined,
        'awaitingInput' => Icons.help_outline,
        _ => Icons.check_circle_outline,
      };

  static String _kilo(int value) => Formatter.tokens(value);

  String _footer() {
    final parts = <String>[];
    switch (message.outcome) {
      case 'failed':
        parts.add('任务失败');
      case 'cancelled':
        parts.add('已中断');
      case 'exhausted':
        parts.add('未确认完成');
      case 'awaitingConfirm':
        parts.add('等待确认');
      case 'completed':
        // 普通一问一答不写"已完成"：那是给多步任务看的状态，
        // 贴在每句闲聊下面像流水线打卡。
        if (message.toolCalls.isNotEmpty) parts.add('已完成');
    }
    if (message.turns > 1) parts.add('${message.turns} 轮');
    // 两个数字含义不同，必须分开写清楚，否则"十几万 token"看着莫名其妙：
    // 计费 = 每轮重发历史的累计量；上下文 = 最后一轮真实占用。
    if (message.totalTokens > 0) parts.add('计费 ${_kilo(message.totalTokens)}');
    final contextTokens = Formatter.serverContextTokens(
        message.promptTokens, message.cachedTokens);
    if (contextTokens > 0) {
      parts.add('上下文 ${_kilo(contextTokens)}');
    }
    if (message.cachedTokens > 0 && contextTokens > 0) {
      final rate =
          (message.cachedTokens / contextTokens * 100).round().clamp(0, 100);
      parts.add('缓存命中 $rate%');
    }
    return parts.join(' · ');
  }
}

class _PlanConfirmCard extends StatelessWidget {
  const _PlanConfirmCard({
    required this.plan,
    required this.onConfirm,
    required this.onReject,
  });

  final List<AiPlanAction> plan;
  final VoidCallback onConfirm;
  final VoidCallback onReject;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final hasIrreversible = plan.any((a) => !a.reversible);
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow.withValues(alpha: 0.66),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: hasIrreversible ? scheme.error : scheme.primary,
          width: 1.2,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: double.infinity,
            color: (hasIrreversible ? scheme.error : scheme.primary)
                .withValues(alpha: 0.10),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            child: Row(
              children: [
                Icon(
                  hasIrreversible
                      ? Icons.warning_amber_rounded
                      : Icons.pan_tool_outlined,
                  size: 17,
                  color: hasIrreversible ? scheme.error : scheme.primary,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    hasIrreversible
                        ? '需要你确认（含不可逆操作）'
                        : '需要你确认这 ${plan.length} 个写操作',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.bold,
                      color: hasIrreversible ? scheme.error : scheme.primary,
                    ),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final action in plan)
                  Container(
                    width: double.infinity,
                    margin: const EdgeInsets.only(bottom: 8),
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color:
                          scheme.surfaceContainerHighest.withValues(alpha: 0.6),
                      borderRadius: BorderRadius.circular(9),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                action.type,
                                style: const TextStyle(
                                  fontSize: 13,
                                  fontFamily: kMonoFamily,
                                  fontFamilyFallback: kMonoFallback,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 7,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: action.reversible
                                    ? scheme.secondaryContainer
                                    : scheme.errorContainer,
                                borderRadius: BorderRadius.circular(20),
                              ),
                              child: Text(
                                action.reversible ? '可逆' : '不可逆',
                                style: TextStyle(
                                  fontSize: 10.5,
                                  fontWeight: FontWeight.bold,
                                  color: action.reversible
                                      ? scheme.onSecondaryContainer
                                      : scheme.onErrorContainer,
                                ),
                              ),
                            ),
                          ],
                        ),
                        if (action.target.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Text(
                              '对象：${action.target}',
                              style: const TextStyle(fontSize: 12),
                            ),
                          ),
                        if (action.impact.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Text(
                              '影响：${action.impact}',
                              style: TextStyle(
                                fontSize: 12,
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: onReject,
                        icon: const Icon(Icons.close, size: 17),
                        label: const Text('拒绝'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: onConfirm,
                        style: hasIrreversible
                            ? FilledButton.styleFrom(
                                backgroundColor: scheme.error,
                                foregroundColor: scheme.onError,
                              )
                            : null,
                        icon: const Icon(Icons.check, size: 17),
                        label: const Text('确认执行'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 气泡里的一颗小操作按钮（图标 + 文字）。
/// "这条没发出去"的红字行。
///
/// 刻意做成裸文字而不是气泡：气泡意味着"有人说了话"，而这里恰恰是**没人说话**
/// ——请求连模型都没到。旁边给一个重发入口，点了就按原文重问一次。
class _SendErrorLine extends StatelessWidget {
  const _SendErrorLine({required this.error, this.onRetry});

  final String error;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(left: 40, right: 2, bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          Icon(Icons.error_outline_rounded, size: 14, color: scheme.error),
          const SizedBox(width: 5),
          Flexible(
            child: SelectableText(
              '未发送成功：$error',
              textAlign: TextAlign.right,
              style: TextStyle(
                fontSize: 11.5,
                height: 1.35,
                color: scheme.error,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          if (onRetry != null) ...[
            const SizedBox(width: 8),
            InkWell(
              borderRadius: BorderRadius.circular(6),
              onTap: onRetry,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                child: Row(
                  children: [
                    Icon(Icons.refresh_rounded, size: 13, color: scheme.error),
                    const SizedBox(width: 2),
                    Text(
                      '重试',
                      style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w700,
                        color: scheme.error,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _MessageImage extends StatefulWidget {
  const _MessageImage({required this.image});

  final AiImageAttachment image;

  @override
  State<_MessageImage> createState() => _MessageImageState();
}

class _MessageImageState extends State<_MessageImage> {
  Uint8List? _bytes;

  @override
  void initState() {
    super.initState();
    _decode();
  }

  @override
  void didUpdateWidget(covariant _MessageImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.image.dataUri != widget.image.dataUri) _decode();
  }

  void _decode() {
    try {
      final comma = widget.image.dataUri.indexOf(',');
      final raw = comma >= 0
          ? widget.image.dataUri.substring(comma + 1)
          : widget.image.dataUri;
      _bytes = base64Decode(raw);
    } catch (_) {
      _bytes = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final bytes = _bytes;
    if (bytes == null) return const Icon(Icons.broken_image_outlined);
    return RepaintBoundary(
      child: Image.memory(
        bytes,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => const Icon(Icons.broken_image_outlined),
      ),
    );
  }
}
