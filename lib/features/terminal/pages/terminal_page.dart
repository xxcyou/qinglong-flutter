import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:xterm/xterm.dart';

import '../../../core/local_shell/proot_bridge.dart';
import '../../../shared/confirm_dialog.dart';
import '../../../shared/glass_scaffold.dart';
import '../../../shared/mono_text.dart';
import '../../settings/providers/settings_provider.dart';
import '../providers/adb_session_provider.dart';
import '../providers/ssh_session_provider.dart';
import '../providers/terminal_session_provider.dart';
import '../terminal_palettes.dart';
import '../widgets/package_install_sheet.dart';
import '../widgets/ssh_manager_sheet.dart';
import '../widgets/adb_manager_sheet.dart';
import '../widgets/adb_terminal_sheet.dart';
import '../widgets/ssh_terminal_view.dart';
import '../widgets/terminal_key_bar.dart';
import '../widgets/terminal_selection_bar.dart';
import '../widgets/terminal_theme_sheet.dart';
import 'shell_files_page.dart';

/// 一个独立的本地终端标签页：每个标签都有自己的 PTY / bash 会话。
class _LocalTab {
  _LocalTab(this.id, this.terminal, this.controller, this.focus);

  final int id;
  final Terminal terminal;
  final TerminalController controller;
  final FocusNode focus;
}

class TerminalPage extends ConsumerStatefulWidget {
  const TerminalPage({super.key});

  @override
  ConsumerState<TerminalPage> createState() => _TerminalPageState();
}

class _TerminalPageState extends ConsumerState<TerminalPage> {
  final _bridge = ProotBridge();
  final _localTabs = <_LocalTab>[];
  StreamSubscription<Map<String, dynamic>>? _eventsSubscription;
  int? _activeLocalIndex;

  /// 当前高亮关键字，以及它当下铺出去的那批高亮对象。
  String _highlight = '';
  final _highlights = <TerminalHighlight>[];
  Timer? _highlightDebounce;

  _LocalTab? get _activeLocalTab {
    final i = _activeLocalIndex;
    if (i == null || i < 0 || i >= _localTabs.length) return null;
    return _localTabs[i];
  }

  @override
  void initState() {
    super.initState();
    _eventsSubscription = _bridge.terminalEvents().listen(_onTerminalEvent);
    Future.microtask(() async {
      final notifier = ref.read(terminalSessionProvider.notifier);
      await notifier.load();
      final autoId = ref.read(terminalSessionProvider).spawnedId;
      if (autoId != null && mounted && _localTabs.isEmpty) {
        _adoptLocalTab(autoId);
      }
    });
  }

  @override
  void dispose() {
    _highlightDebounce?.cancel();
    _clearHighlights();
    _eventsSubscription?.cancel();
    for (final t in _localTabs) {
      t.focus.dispose();
      unawaited(_bridge.stopTerminal(t.id));
    }
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
    final tab = _activeLocalTab;
    if (tab == null) return;
    final needle = keyword.toLowerCase();
    final buffer = tab.terminal.buffer;
    final color = Theme.of(context).colorScheme.primary.withValues(alpha: 0.34);
    final end = buffer.height;
    final start = (end - tab.terminal.viewHeight * 3).clamp(0, end);
    var made = 0;
    for (var y = start; y < end && made < 200; y++) {
      final line = buffer.lines[y].getText().toLowerCase();
      var from = line.indexOf(needle);
      while (from >= 0 && made < 200) {
        _highlights.add(
          tab.controller.highlight(
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

  void _onTerminalEvent(Map<String, dynamic> event) {
    final type = event['type']?.toString();
    final id = (event['id'] is num) ? (event['id'] as num).toInt() : 0;
    final data = event['data']?.toString() ?? '';
    if (type == 'output') {
      for (final tab in _localTabs) {
        if (tab.id == id) {
          tab.terminal.write(data);
          _scheduleHighlight();
          break;
        }
      }
      return;
    }
    if (type == 'exit') {
      // 会话退出只留在原标签里，用户可看到退出状态然后手动关标签。
      ref.read(terminalSessionProvider.notifier).markExited();
    }
  }

  Future<void> _addLocalTab() async {
    final state = ref.read(terminalSessionProvider);
    if (state.status?.installed != true) {
      return;
    }
    final id = await _bridge.spawnTerminal();
    if (!mounted || id == 0) return;
    final tab = _LocalTab(
      id,
      Terminal(maxLines: 2000),
      TerminalController(),
      FocusNode(),
    );
    tab.terminal.onOutput = (data) => unawaited(_bridge.writeTerminal(id, data));
    tab.terminal.onResize = (w, h, pw, ph) {
      unawaited(_bridge.resizeTerminal(id, w, h));
    };
    setState(() {
      _localTabs.add(tab);
      _activeLocalIndex = _localTabs.length - 1;
    });
  }

  void _adoptLocalTab(int id) {
    final tab = _LocalTab(
      id,
      Terminal(maxLines: 2000),
      TerminalController(),
      FocusNode(),
    );
    tab.terminal.onOutput = (data) => unawaited(_bridge.writeTerminal(id, data));
    tab.terminal.onResize = (w, h, pw, ph) {
      unawaited(_bridge.resizeTerminal(id, w, h));
    };
    setState(() {
      _localTabs.add(tab);
      _activeLocalIndex = _localTabs.length - 1;
    });
  }

  Future<void> _closeLocalTab(int index) async {
    final tab = _localTabs[index];
    await _bridge.stopTerminal(tab.id);
    if (!mounted) return;
    setState(() {
      _localTabs.removeAt(index);
      _activeLocalIndex = _localTabs.isEmpty
          ? null
          : (index >= _localTabs.length ? _localTabs.length - 1 : index);
    });
  }

  void _send(String data) {
    final tab = _activeLocalTab;
    if (tab != null) unawaited(_bridge.writeTerminal(tab.id, data));
  }

  void _toggleKeyboard() {
    final tab = _activeLocalTab;
    if (tab == null) return;
    if (tab.focus.hasFocus) {
      tab.focus.unfocus();
    } else {
      tab.focus.requestFocus();
    }
  }

  Future<void> _openAdbTerminal() async {
    final sessions = ref
        .read(adbSessionsProvider)
        .sessions
        .where((s) => s.isConnected)
        .toList();
    if (sessions.isEmpty) return;
    if (sessions.length == 1) {
      await AdbTerminalSheet.show(
        context,
        sessionId: sessions.first.id,
        title: sessions.first.name,
      );
      return;
    }
    final picked = await showModalBottomSheet<AdbSession>(
      context: context,
      backgroundColor: Theme.of(context).colorScheme.surface,
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 14, 16, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '选择 ADB 终端',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
                ),
              ),
            ),
            for (final s in sessions)
              ListTile(
                leading: const Icon(Icons.smartphone),
                title: Text(s.name),
                subtitle: Text('${s.host}:${s.port}'),
                onTap: () => Navigator.pop(context, s),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (picked != null && mounted) {
      await AdbTerminalSheet.show(
        context,
        sessionId: picked.id,
        title: picked.name,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(terminalSessionProvider);
    final hasAdbConnected =
        ref.watch(adbSessionsProvider).sessions.any((s) => s.isConnected);
    final notifier = ref.read(terminalSessionProvider.notifier);
    final settings = ref.watch(settingsProvider);
    final palette = TerminalPalette.byId(settings.terminalPalette);
    final sshSessions = ref
        .watch(sshSessionsProvider)
        .sessions
        .where((s) => s.isConnected)
        .toList();
    final localCount = _localTabs.length;
    final tabCount = localCount + sshSessions.length + 1;

    return GlassScaffold(
      title: 'Linux 终端',
      subtitle: localCount > 0 ? '$localCount 个本地终端' : null,
      bodyTopPadding: 0,
      actions: [
        IconButton(
          tooltip: 'SSH 会话管理（新建/连接/删除都在这里）',
          onPressed: () => SshManagerSheet.show(context),
          icon: const Icon(Icons.dns_outlined),
        ),
        IconButton(
          tooltip: 'ADB 设备管理（无线调试/文件管理）',
          onPressed: () => AdbManagerSheet.show(context),
          icon: const Icon(Icons.smartphone_outlined),
        ),
        if (hasAdbConnected)
          IconButton(
            tooltip: 'ADB 终端',
            onPressed: _openAdbTerminal,
            icon: const Icon(Icons.terminal),
          ),
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
        if (localCount > 0)
          IconButton(
            tooltip: '安装软件包',
            onPressed: () => PackageInstallSheet.show(context, _send),
            icon: const Icon(Icons.inventory_2_outlined),
          ),
        if (localCount > 0)
          IconButton(
            tooltip: '停止当前终端',
            onPressed: () {
              final i = _activeLocalIndex;
              if (i != null && i < localCount) _closeLocalTab(i);
            },
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
                    ? '会删掉已下载的安装包并重新下载约 150MB，然后重新解压。\n'
                        '/workspace、/home/coomi 里的文件不会动。'
                    : '用已下载的安装包重新解压一遍系统目录，通常一两分钟。\n'
                        '/workspace、/home/coomi 里的文件不会动。',
                confirmText: clean ? '下载并重装' : '重装',
                destructive: true,
              );
              if (!ok) return;
              for (final t in _localTabs) {
                unawaited(_bridge.stopTerminal(t.id));
              }
              _localTabs.clear();
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
      body: DefaultTabController(
        length: tabCount,
        child: Column(
          children: [
            Material(
              color: Colors.transparent,
              child: TabBar(
                isScrollable: true,
                labelColor: Theme.of(context).colorScheme.primary,
                unselectedLabelColor:
                    Theme.of(context).colorScheme.onSurfaceVariant,
                dividerColor: Colors.transparent,
                indicatorColor: Theme.of(context).colorScheme.primary,
                onTap: (i) {
                  if (i >= localCount + sshSessions.length) {
                    _addLocalTab();
                    return;
                  }
                  if (i < localCount) {
                    setState(() => _activeLocalIndex = i);
                  }
                },
                tabs: [
                  for (var i = 0; i < localCount; i++)
                    Tab(
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text('终端 ${i + 1}'),
                          if (localCount > 1)
                            GestureDetector(
                              onTap: () => _closeLocalTab(i),
                              child: const Padding(
                                padding: EdgeInsets.only(left: 4),
                                child: Icon(Icons.close_rounded, size: 13),
                              ),
                            ),
                        ],
                      ),
                    ),
                  for (final s in sshSessions) Tab(text: s.name),
                  const Tab(
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.add_rounded, size: 16),
                        SizedBox(width: 2),
                        Text('新建'),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: TabBarView(
                children: [
                  if (localCount == 0)
                    _buildEmptyLocalBody(
                      state,
                      notifier,
                      settings,
                      palette,
                    )
                  else
                    for (final tab in _localTabs)
                      _buildLocalTabBody(
                        tab,
                        state,
                        notifier,
                        settings,
                        palette,
                      ),
                  for (final s in sshSessions) SshTerminalView(sessionId: s.id),
                  const SizedBox.shrink(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyLocalBody(
    TerminalSessionState state,
    TerminalSessionNotifier notifier,
    AppSettings settings,
    TerminalPalette palette,
  ) {
    if (!state.isAndroidSupported) {
      return const Center(child: Text('PRoot Linux 仅支持 Android'));
    }
    if (state.status == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (state.status!.installed) {
      return _LaunchView(onTap: _addLocalTab, palette: palette);
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
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: LinearProgressIndicator(
                  value: fraction,
                  minHeight: 8,
                ),
              ),
              const SizedBox(height: 14),
              Text(
                p?.stage.isNotEmpty == true ? p!.stage : '正在安装 Linux Runtime',
                style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
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
            const Text('Linux 尚未安装', style: TextStyle(fontSize: 16)),
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

  Widget _buildLocalTabBody(
    _LocalTab tab,
    TerminalSessionState state,
    TerminalSessionNotifier notifier,
    AppSettings settings,
    TerminalPalette palette,
  ) {
    return Column(
      children: [
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: Container(
              margin: const EdgeInsets.fromLTRB(10, 0, 10, 10),
              decoration: BoxDecoration(
                color: const Color(0xFF10141A),
                borderRadius: BorderRadius.circular(20),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(20),
                child: TerminalView(
                  tab.terminal,
                  controller: tab.controller,
                  focusNode: tab.focus,
                  autofocus: true,
                  keyboardType: TextInputType.multiline,
                  backgroundOpacity: 0.92,
                  theme: palette.theme,
                  textStyle: TerminalStyle(
                    fontSize: settings.terminalFontSize,
                    height: settings.terminalLineHeight,
                    fontFamily: kMonoFamily,
                    fontFamilyFallback: kMonoFallback,
                  ),
                  padding: const EdgeInsets.fromLTRB(10, 8, 6, 8),
                  cursorType: TerminalCursorType.block,
                ),
              ),
            ),
          ),
        ),
        TerminalSelectionBar(
          terminal: tab.terminal,
          controller: tab.controller,
          highlight: _highlight,
          onHighlightChanged: _setHighlight,
        ),
        TerminalKeyBar(
          onSend: _send,
          onToggleKeyboard: _toggleKeyboard,
          onInstallPackage: () => PackageInstallSheet.show(context, _send),
          highlightCommands: settings.terminalCommandHighlight,
          fontSize: settings.terminalFontSize,
        ),
        SizedBox(height: MediaQuery.paddingOf(context).bottom * 0.2),
      ],
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
          Text('已安装 Linux Runtime', style: TextStyle(color: fg)),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: onTap,
            icon: const Icon(Icons.play_arrow),
            label: const Text('新建终端标签'),
          ),
        ],
      ),
    );
  }
}
