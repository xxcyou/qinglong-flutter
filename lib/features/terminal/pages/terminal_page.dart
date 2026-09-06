import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:xterm/xterm.dart';

import '../../../core/local_shell/proot_bridge.dart';
import '../../../shared/confirm_dialog.dart';
import '../../../shared/glass_scaffold.dart';
import '../../settings/providers/settings_provider.dart';
import '../providers/terminal_session_provider.dart';
import '../terminal_palettes.dart';
import '../widgets/package_install_sheet.dart';
import '../widgets/terminal_key_bar.dart';
import '../widgets/terminal_selection_bar.dart';
import '../widgets/terminal_theme_sheet.dart';
import 'shell_files_page.dart';
import '../../../shared/mono_text.dart';

class TerminalPage extends ConsumerStatefulWidget {
  const TerminalPage({super.key});

  @override
  ConsumerState<TerminalPage> createState() => _TerminalPageState();
}

class _TerminalPageState extends ConsumerState<TerminalPage> {
  final _terminal = Terminal(maxLines: 2000);
  final _terminalController = TerminalController();
  final _focusNode = FocusNode();
  late final ProotBridge _bridge = ProotBridge();
  StreamSubscription<Map<String, dynamic>>? _eventsSubscription;

  /// 当前高亮关键字，以及它当下铺出去的那批高亮对象。
  /// 终端一直在滚，所以每次有新输出都要重算一遍。
  String _highlight = '';
  final _highlights = <TerminalHighlight>[];
  Timer? _highlightDebounce;

  @override
  void initState() {
    super.initState();
    _terminal.onOutput = _writeTerminal;
    // 终端控件自己知道当前多少行列，把它同步给 pty。
    // 不同步 guest 就认为终端是 0x0：ls 不分列、top 画不出来、换行位置全错。
    _terminal.onResize = (w, h, pw, ph) {
      unawaited(_bridge.resizeTerminal(w, h));
    };
    _eventsSubscription = _bridge.terminalEvents().listen(_onTerminalEvent);
    Future.microtask(() => ref.read(terminalSessionProvider.notifier).load());
  }

  @override
  void dispose() {
    _highlightDebounce?.cancel();
    _clearHighlights();
    _focusNode.dispose();
    _eventsSubscription?.cancel();
    _bridge.stopTerminal();
    super.dispose();
  }

  void _clearHighlights() {
    for (final h in _highlights) {
      h.dispose();
    }
    _highlights.clear();
  }

  void _setHighlight(String keyword) {
    setState(() => _highlight = keyword);
    _scheduleHighlight();
  }

  /// 输出流很密（apt 装包一秒能刷几百行），每来一段就全量重算高亮会卡。
  /// 攒 220ms 再算一次，肉眼看不出延迟。
  void _scheduleHighlight() {
    if (_highlight.isEmpty) {
      _highlightDebounce?.cancel();
      if (_highlights.isNotEmpty) _clearHighlights();
      return;
    }
    _highlightDebounce?.cancel();
    _highlightDebounce =
        Timer(const Duration(milliseconds: 220), _applyHighlight);
  }

  void _applyHighlight() {
    _clearHighlights();
    final keyword = _highlight;
    if (keyword.isEmpty) return;
    final needle = keyword.toLowerCase();
    final buffer = _terminal.buffer;
    final color = Theme.of(context).colorScheme.primary.withValues(alpha: 0.34);
    // 只扫可见区往上一屏多一点：整个 2000 行回滚全扫没必要，也扫不动。
    final end = buffer.height;
    final start = (end - _terminal.viewHeight * 3).clamp(0, end);
    var made = 0;
    for (var y = start; y < end && made < 200; y++) {
      final line = buffer.lines[y].getText().toLowerCase();
      var from = line.indexOf(needle);
      while (from >= 0 && made < 200) {
        _highlights.add(
          _terminalController.highlight(
            p1: buffer.createAnchor(from, y),
            p2: buffer.createAnchor(from + needle.length, y),
            color: color,
          ),
        );
        made++;
        from = line.indexOf(needle, from + needle.length);
      }
    }
  }

  void _writeTerminal(String data) {
    unawaited(_bridge.writeTerminal(data));
  }

  void _onTerminalEvent(Map<String, dynamic> event) {
    switch (event['type']) {
      case 'output':
        _terminal.write(event['data']?.toString() ?? '');
        _scheduleHighlight();
      case 'exit':
        ref.read(terminalSessionProvider.notifier).markExited();
    }
  }

  /// 把原始序列写进 pty。快捷键条与装包面板都走这里。
  void _send(String data) => unawaited(_bridge.writeTerminal(data));

  void _toggleKeyboard() {
    if (_focusNode.hasFocus) {
      _focusNode.unfocus();
    } else {
      _focusNode.requestFocus();
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(terminalSessionProvider);
    final notifier = ref.read(terminalSessionProvider.notifier);
    final settings = ref.watch(settingsProvider);
    final palette = TerminalPalette.byId(settings.terminalPalette);
    return GlassScaffold(
      title: 'Debian 终端',
      subtitle: state.running ? '会话进行中' : null,
      bodyTopPadding: 0,
      actions: [
        IconButton(
          tooltip: '文件管理',
          onPressed: () => ShellFilesPage.showSheet(context),
          icon: const Icon(Icons.folder_outlined),
        ),
        IconButton(
          tooltip: '外观',
          onPressed: () => TerminalThemeSheet.show(context),
          icon: const Icon(Icons.palette_outlined),
        ),
        if (state.running)
          IconButton(
            tooltip: '安装软件包',
            onPressed: () => PackageInstallSheet.show(context, _send),
            icon: const Icon(Icons.inventory_2_outlined),
          ),
        if (state.running)
          IconButton(
            tooltip: '停止',
            onPressed: notifier.stop,
            icon: const Icon(Icons.stop_circle_outlined),
          ),
        IconButton(
          tooltip: '检查状态',
          onPressed: notifier.load,
          icon: const Icon(Icons.refresh),
        ),
        if (state.status?.installed == true && !state.installing)
          PopupMenuButton<String>(
            tooltip: '维护',
            icon: const Icon(Icons.build_outlined),
            onSelected: (value) async {
              final clean = value == 'clean';
              final ok = await showConfirmDialog(
                context,
                title: clean ? '彻底重装 Runtime' : '重装 Runtime',
                message: clean
                    ? '会删掉已下载的安装包并重新下载约 150MB，然后重新解压。'
                        '适合怀疑安装包损坏时用。\n'
                        '/workspace、/home/coomi 里的文件不会动。'
                    : '用已下载的安装包重新解压一遍系统目录，通常一两分钟。\n'
                        '/workspace、/home/coomi 里的文件不会动。',
                confirmText: clean ? '下载并重装' : '重装',
                destructive: true,
              );
              if (!ok) return;
              await notifier.install(clean: clean);
            },
            itemBuilder: (context) => const [
              PopupMenuItem(
                value: 'repair',
                child: ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.autorenew),
                  title: Text('重装（用已下载的包）'),
                  subtitle: Text('只重新解压，快'),
                ),
              ),
              PopupMenuItem(
                value: 'clean',
                child: ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.cloud_download_outlined),
                  title: Text('彻底重装（重新下载）'),
                  subtitle: Text('约 150MB'),
                ),
              ),
            ],
          ),
      ],
      body: Column(
        children: [
          Expanded(child: _buildBody(state, notifier, settings, palette)),
          // 选择/复制条同理：没会话时没有内容可复制。
          if (state.running)
            TerminalSelectionBar(
              terminal: _terminal,
              controller: _terminalController,
              highlight: _highlight,
              onHighlightChanged: _setHighlight,
            ),
          // 快捷键条只在会话真的跑起来后出现，没会话时按了也没人收。
          if (state.running)
            TerminalKeyBar(
              onSend: _send,
              onToggleKeyboard: _toggleKeyboard,
              onInstallPackage: () => PackageInstallSheet.show(context, _send),
              highlightCommands: settings.terminalCommandHighlight,
              fontSize: settings.terminalFontSize,
            ),
          // 贴边：只补系统手势条的一小截，剩下的高度还给终端。
          if (state.running)
            SizedBox(height: MediaQuery.paddingOf(context).bottom * 0.2)
          else
            // 没会话时给底部留出上拉把手的空间即可（菜单是浮层，默认收起）。
            SizedBox(height: 12 + MediaQuery.paddingOf(context).bottom * 0.2),
        ],
      ),
    );
  }

  Widget _buildBody(
    TerminalSessionState state,
    TerminalSessionNotifier notifier,
    AppSettings settings,
    TerminalPalette palette,
  ) {
    if (!state.isAndroidSupported) {
      return const Center(child: Text('PRoot Debian 仅支持 Android'));
    }
    if (state.status == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (state.status!.installed) {
      return Column(
        children: [
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: Container(
                margin: const EdgeInsets.fromLTRB(6, 0, 6, 6),
                color: palette.background,
                child: state.running
                    ? TerminalView(
                        _terminal,
                        controller: _terminalController,
                        focusNode: _focusNode,
                        autofocus: true,
                        keyboardType: TextInputType.multiline,
                        backgroundOpacity: 1,
                        theme: palette.theme,
                        // 等宽字体 + 行高：Android 自带 monospace 字形窄、
                        // 中英混排基线乱跳，换成 JetBrains Mono 才像正经终端。
                        textStyle: TerminalStyle(
                          fontSize: settings.terminalFontSize,
                          height: settings.terminalLineHeight,
                          fontFamily: kMonoFamily,
                          fontFamilyFallback: kMonoFallback,
                        ),
                        padding: const EdgeInsets.fromLTRB(10, 8, 6, 8),
                        cursorType: TerminalCursorType.block,
                      )
                    : _LaunchView(onTap: notifier.spawn, palette: palette),
              ),
            ),
          ),
          if (state.error != null)
            Padding(
              padding: const EdgeInsets.all(8),
              child: Text(
                state.error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
        ],
      );
    }
    if (state.installing) {
      final p = state.progress;
      final fraction = p?.fraction;
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 进度未知（服务器没给 Content-Length）时退化为不确定条，
              // 但阶段文字始终在动，用户能确认没卡死。
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: LinearProgressIndicator(
                  value: fraction,
                  minHeight: 8,
                ),
              ),
              const SizedBox(height: 14),
              Text(
                p?.stage.isNotEmpty == true
                    ? p!.stage
                    : '正在安装 Debian Runtime V2',
                style:
                    const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 6),
              Text(
                [
                  if (fraction != null)
                    '${(fraction * 100).toStringAsFixed(1)}%',
                  if (p != null && p.sizeText.isNotEmpty) p.sizeText,
                ].join(' · '),
                style: const TextStyle(fontSize: 12.5),
              ),
              const SizedBox(height: 10),
              const Text(
                '总大小约 150MB，首次安装需要几分钟；\n下载完还要解压根文件系统，请保持前台。',
                style: TextStyle(fontSize: 11.5),
                textAlign: TextAlign.center,
              ),
              if (state.error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(
                    state.error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                      fontSize: 12,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ),
            ],
          ),
        ),
      );
    }
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.terminal_outlined, size: 64),
            const SizedBox(height: 12),
            const Text('PRoot Debian 尚未安装', style: TextStyle(fontSize: 16)),
            const SizedBox(height: 8),
            const Text(
                '来自 Coomi Runtime V2 的 Debian Bookworm + Python/Node/Git',
                textAlign: TextAlign.center),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: notifier.install,
              icon: const Icon(Icons.download),
              label: const Text('下载并安装 Runtime V2'),
            ),
            if (state.error != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  state.error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                  textAlign: TextAlign.center,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _LaunchView extends StatelessWidget {
  const _LaunchView({required this.onTap, required this.palette});

  final VoidCallback onTap;
  final TerminalPalette palette;

  @override
  Widget build(BuildContext context) {
    final fg = palette.theme.foreground;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.arrow_circle_down_outlined,
            size: 48,
            color: fg.withValues(alpha: 0.7),
          ),
          const SizedBox(height: 12),
          Text('已安装 Runtime V2', style: TextStyle(color: fg)),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: onTap,
            icon: const Icon(Icons.play_arrow),
            label: const Text('启动 Debian Shell'),
          ),
        ],
      ),
    );
  }
}
