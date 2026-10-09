import 'dart:convert';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/local_shell/proot_bridge.dart';
import 'ssh_session_provider.dart';
import 'adb_session_provider.dart';

/// 文件管理器当前目录。悬浮终端、悬浮球 AI 都要读它。
final ValueNotifier<String> fileManagerCwd = ValueNotifier('/workspace');

/// 文件管理的两套根：终端（PRoot guest 挂载点）与 APP 自身沙箱目录。
enum FileScope {
  /// 终端里看到的 /workspace、/home/coomi 等，与 shell 共享同一份文件。
  shell('终端文件'),

  /// APP 沙箱：filesDir / cacheDir / 外部 files 目录。
  app('APP 文件'),

  /// 已连接 SSH 会话的远程目录（SFTP）。
  ssh('SSH 文件'),

  /// 已连接 ADB 设备的远程目录（shell + base64 中转）。
  adb('ADB 文件');

  const FileScope(this.label);

  final String label;
}

/// 排序方式。
enum FileSort {
  name('名称'),
  size('大小'),
  modified('修改时间');

  const FileSort(this.label);

  final String label;
}

/// 文件管理显示样式：Windows 式列表/网格等。
enum FileViewMode {
  list('列表'),
  details('详细信息'),
  grid('网格');

  const FileViewMode(this.label);

  final String label;
}

class ShellFilesState {
  const ShellFilesState({
    this.scope = FileScope.shell,
    this.sshSessionId,
    this.adbSessionId,
    this.path = '/workspace',
    this.roots = const [
      '/workspace',
      '/home/coomi',
      '/opt/coomi-dev',
      '/cache',
      '/tmp'
    ],
    this.rootLabels = const [],
    this.entries = const [],
    this.loading = false,
    this.keyword = '',
    this.searching = false,
    this.searchResults,
    this.sort = FileSort.name,
    this.descending = false,
    this.showHidden = false,
    this.viewMode = FileViewMode.list,
    this.selected = const {},
    this.clipboardPath,
    this.clipboardIsCut = false,
    this.clipboardScope,
    this.clipboardSshId,
    this.clipboardAdbId,
    this.error,
  });

  final FileScope scope;

  /// 当前 SSH 会话 id（scope == ssh 时有效）。
  final String? sshSessionId;

  /// 当前 ADB 会话 id（scope == adb 时有效）。
  final String? adbSessionId;
  final String path;
  final List<String> roots;
  final List<String> rootLabels;
  final List<ShellFileEntry> entries;
  final bool loading;

  /// 名称过滤关键词（本地过滤，不递归）。
  final String keyword;

  /// 递归搜索中 / 递归搜索结果（非 null 时列表展示搜索结果）。
  final bool searching;
  final List<ShellFileEntry>? searchResults;

  final FileSort sort;
  final bool descending;
  final bool showHidden;
  final FileViewMode viewMode;

  /// 多选集合（路径）。
  final Set<String> selected;

  /// 剪贴板：待复制/移动的路径。
  final String? clipboardPath;
  final bool clipboardIsCut;

  /// 剪贴板来源作用域/SSH/ADB 会话。跨区粘贴（SSH ↔ 终端/APP ↔ ADB）要用。
  final String? clipboardScope;
  final String? clipboardSshId;
  final String? clipboardAdbId;

  final String? error;

  bool get atRoot => roots.contains(path);
  bool get isSearchMode => searchResults != null;
  bool get isSelecting => selected.isNotEmpty;

  String get parentPath {
    if (atRoot) return path;
    final index = path.lastIndexOf('/');
    if (index <= 0) return path;
    final parent = path.substring(0, index);
    return parent.isEmpty ? '/' : parent;
  }

  /// 当前应展示的条目：搜索结果优先，其次按关键词过滤 + 隐藏文件开关 + 排序。
  List<ShellFileEntry> get visibleEntries {
    final source = searchResults ?? entries;
    final filtered = [
      for (final e in source)
        if ((showHidden || !e.hidden) &&
            (isSearchMode ||
                keyword.isEmpty ||
                e.name.toLowerCase().contains(keyword.toLowerCase())))
          e,
    ];
    // 目录始终排在文件前面，再按选定字段排。
    filtered.sort((a, b) {
      if (a.isDirectory != b.isDirectory) return a.isDirectory ? -1 : 1;
      final cmp = switch (sort) {
        FileSort.name => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
        FileSort.size => a.size.compareTo(b.size),
        FileSort.modified => a.modified.compareTo(b.modified),
      };
      return descending ? -cmp : cmp;
    });
    return filtered;
  }

  ShellFilesState copyWith({
    FileScope? scope,
    String? sshSessionId,
    bool clearSshSession = false,
    String? adbSessionId,
    bool clearAdbSession = false,
    String? path,
    List<String>? roots,
    List<String>? rootLabels,
    List<ShellFileEntry>? entries,
    bool? loading,
    String? keyword,
    bool? searching,
    List<ShellFileEntry>? searchResults,
    bool clearSearch = false,
    FileSort? sort,
    bool? descending,
    bool? showHidden,
    FileViewMode? viewMode,
    Set<String>? selected,
    String? clipboardPath,
    bool? clipboardIsCut,
    String? clipboardScope,
    String? clipboardSshId,
    String? clipboardAdbId,
    bool clearClipboard = false,
    String? error,
    bool clearError = false,
  }) {
    return ShellFilesState(
      scope: scope ?? this.scope,
      sshSessionId: clearSshSession ? null : sshSessionId ?? this.sshSessionId,
      adbSessionId:
          clearAdbSession ? null : adbSessionId ?? this.adbSessionId,
      path: path ?? this.path,
      roots: roots ?? this.roots,
      rootLabels: rootLabels ?? this.rootLabels,
      entries: entries ?? this.entries,
      loading: loading ?? this.loading,
      keyword: keyword ?? this.keyword,
      searching: searching ?? this.searching,
      searchResults: clearSearch ? null : searchResults ?? this.searchResults,
      sort: sort ?? this.sort,
      descending: descending ?? this.descending,
      showHidden: showHidden ?? this.showHidden,
      viewMode: viewMode ?? this.viewMode,
      selected: selected ?? this.selected,
      clipboardPath:
          clearClipboard ? null : clipboardPath ?? this.clipboardPath,
      clipboardIsCut:
          clearClipboard ? false : clipboardIsCut ?? this.clipboardIsCut,
      clipboardScope:
          clearClipboard ? null : clipboardScope ?? this.clipboardScope,
      clipboardSshId:
          clearClipboard ? null : clipboardSshId ?? this.clipboardSshId,
      clipboardAdbId:
          clearClipboard ? null : clipboardAdbId ?? this.clipboardAdbId,
      error: clearError ? null : error ?? this.error,
    );
  }
}

class ShellFilesNotifier extends Notifier<ShellFilesState> {
  final _bridge = ProotBridge();
  final Map<String, SftpClient> _sftpClients = {};
  final Map<String, Uint8List> _imageCache = {};
  final Map<FileScope, String> _pathsByScope = {
    FileScope.shell: '/workspace',
    FileScope.app: '',
    FileScope.ssh: '/',
    FileScope.adb: '/storage/emulated/0',
  };
  final Map<String, String> _sshPaths = {};

  @override
  ShellFilesState build() {
    Future.microtask(_loadPrefs);
    return const ShellFilesState();
  }

  static const _showHiddenKey = 'fileShowHidden';
  static const _viewModeKey = 'fileViewMode';

  Future<void> _loadPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final hidden = prefs.getBool(_showHiddenKey) ?? false;
      final modeIndex = prefs.getInt(_viewModeKey) ?? 0;
      if (modeIndex < 0 || modeIndex >= FileViewMode.values.length) return;
      state = state.copyWith(
        showHidden: hidden,
        viewMode: FileViewMode.values[modeIndex],
      );
    } catch (_) {}
  }

  Future<void> _savePrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_showHiddenKey, state.showHidden);
      await prefs.setInt(_viewModeKey, state.viewMode.index);
    } catch (_) {}
  }

  Future<void> open([String? path]) async {
    final target = path ?? state.path;
    state = state.copyWith(
      loading: true,
      clearError: true,
      clearSearch: true,
      selected: const {},
    );
    try {
      final ShellDirectoryListing listing;
      if (state.scope == FileScope.shell) {
        listing = await _bridge.listFiles(path: target);
      } else if (state.scope == FileScope.app) {
        listing =
            await _bridge.listAppFiles(path: target.isEmpty ? null : target);
      } else if (state.scope == FileScope.adb) {
        listing = await _adbListing(target);
      } else {
        listing = await _sshListing(target);
      }
      _pathsByScope[state.scope] = listing.path;
      fileManagerCwd.value = listing.path;
      if (state.scope == FileScope.ssh && state.sshSessionId != null) {
        _sshPaths[state.sshSessionId!] = listing.path;
      }
      state = state.copyWith(
        path: listing.path,
        roots: listing.roots.isEmpty ? state.roots : listing.roots,
        rootLabels: listing.rootLabels,
        entries: listing.entries,
        loading: false,
        clearError: true,
      );
    } catch (e) {
      state = state.copyWith(loading: false, error: _message(e));
    }
  }

  /// 切换根（终端 ↔ APP ↔ SSH）。切换时让原生给默认根。
  Future<void> switchScope(FileScope scope) async {
    if (scope == state.scope) return;
    var sshId = state.sshSessionId;
    var adbId = state.adbSessionId;
    var path = _pathsByScope[scope] ??
        (scope == FileScope.shell
            ? '/workspace'
            : scope == FileScope.app
                ? ''
                : scope == FileScope.adb
                    ? '/storage/emulated/0'
                    : '/');
    if (scope == FileScope.adb) {
      if (adbId == null ||
          AdbSessionManager.instance.connectionOf(adbId) == null) {
        final saved = AdbSessionManager.instance.sessions;
        if (saved.isEmpty) {
          state = state.copyWith(
            scope: scope,
            adbSessionId: null,
            clearAdbSession: true,
            entries: const [],
            selected: const {},
            clearError: false,
            clearClipboard: true,
            error: '还没有 ADB 设备，请先在 ADB 设备管理里连接',
          );
          return;
        }
        adbId = saved.first.id;
        path = '/storage/emulated/0';
      } else {
        path = '/storage/emulated/0';
      }
    } else if (scope == FileScope.ssh) {
      if (sshId == null || SshSessionManager.instance.clientOf(sshId) == null) {
        final saved = SshSessionManager.instance.sessions;
        if (saved.isEmpty) {
          state = state.copyWith(
            scope: scope,
            sshSessionId: null,
            clearSshSession: true,
            entries: const [],
            selected: const {},
            clearError: false,
            clearClipboard: true,
            error: '还没有 SSH 会话，请先在 SSH 会话管理里新建',
          );
          return;
        }
        sshId = saved.first.id;
        path = _sshPaths[sshId] ?? '/';
      } else {
        path = _sshPaths[sshId] ?? '/';
      }
    } else if (scope == FileScope.ssh && sshId != null) {
      path = _sshPaths[sshId] ?? '/';
    }
    state = state.copyWith(
      scope: scope,
      sshSessionId: sshId,
      adbSessionId: adbId,
      entries: const [],
      keyword: '',
      clearSearch: true,
      selected: const {},
      clearError: true,
      path: path,
    );
    await open(path);
  }

  /// 切换当前 SSH 会话。未连接时自动用保存的账号连接。
  Future<void> setSshSession(String? id) async {
    if (id == null || state.scope != FileScope.ssh) return;
    final oldId = state.sshSessionId;
    if (oldId != null && oldId != id) {
      _sshPaths[oldId] = state.path;
    }
    final path = _sshPaths[id] ?? '/';
    state = state.copyWith(
      sshSessionId: id,
      entries: const [],
      keyword: '',
      clearSearch: true,
      selected: const {},
      clearError: true,
      loading: true,
      path: path,
    );
    try {
      final ok = await _ensureSshConnected(id);
      if (!ok) return;
      await open(path);
    } catch (e) {
      state = state.copyWith(
        error: _message(e),
        loading: false,
      );
    }
  }

  /// 切换当前 ADB 设备。
  Future<void> setAdbSession(String? id) async {
    if (id == null || state.scope != FileScope.adb) return;
    state = state.copyWith(
      adbSessionId: id,
      entries: const [],
      keyword: '',
      clearSearch: true,
      selected: const {},
      clearError: true,
      loading: true,
      path: '/sdcard',
    );
    try {
      if (AdbSessionManager.instance.connectionOf(id) == null) {
        final draft = AdbSessionManager.instance.draftOf(id);
        if (draft == null) throw StateError('ADB 设备不存在');
        final session =
            await AdbSessionManager.instance.connect(draft, id: id);
        if (!session.isConnected) {
          state = state.copyWith(error: session.status, loading: false);
          return;
        }
      }
      await open('/sdcard');
    } catch (e) {
      state = state.copyWith(error: _message(e), loading: false);
    }
  }

  /// 保证 SSH 已连接；未连接时自动拉活。
  Future<bool> _ensureSshConnected(String id) async {
    if (SshSessionManager.instance.clientOf(id) != null) return true;
    final draft = SshSessionManager.instance.draftOf(id);
    if (draft == null) throw StateError('SSH 会话不存在');
    final session = await SshSessionManager.instance.connect(draft, id: id);
    if (!session.isConnected) {
      state = state.copyWith(error: session.status);
      return false;
    }
    return true;
  }

  Future<SftpClient> _sftpFor(String id) async {
    final existing = _sftpClients[id];
    if (existing != null) return existing;

    var client = SshSessionManager.instance.clientOf(id);
    if (client == null) {
      final draft = SshSessionManager.instance.draftOf(id);
      if (draft == null) throw StateError('SSH 会话不存在');
      final session = await SshSessionManager.instance.connect(draft, id: id);
      if (!session.isConnected) throw StateError(session.status);
      client = SshSessionManager.instance.clientOf(id);
      if (client == null) throw StateError('SSH 连接失败');
    }

    final sftp = await client.sftp();
    _sftpClients[id] = sftp;
    return sftp;
  }

  String _sshJoin(String dir, String name) {
    final clean = name.trim();
    if (dir == '/') return '/$clean';
    if (dir.endsWith('/')) return '$dir$clean';
    return '$dir/$clean';
  }

  Future<ShellDirectoryListing> _sshListing(String path) async {
    final id = state.sshSessionId;
    if (id == null) throw StateError('没有选择 SSH 会话');
    final sftp = await _sftpFor(id);
    final items = await sftp.listdir(path);
    final entries = <ShellFileEntry>[];
    for (final item in items) {
      final name = item.filename;
      if (name.isEmpty || name == '.' || name == '..') continue;
      entries.add(ShellFileEntry(
        name: name,
        path: _sshJoin(path, name),
        isDirectory: item.attr.isDirectory,
        size: item.attr.size ?? 0,
        modified: DateTime.fromMillisecondsSinceEpoch(
          (item.attr.modifyTime ?? 0) * 1000,
        ),
        readable: true,
        writable: true,
        executable: item.attr.mode?.value != null &&
            (item.attr.mode!.value & 0x49) != 0,
        hidden: name.startsWith('.'),
      ));
    }
    return ShellDirectoryListing(
      path: path,
      roots: const ['/'],
      entries: entries,
      rootLabels: const ['SSH 根目录'],
    );
  }

  Future<void> refresh() => open(state.path);

  Future<void> goUp() async {
    if (state.atRoot) return;
    await open(state.parentPath);
  }

  void setKeyword(String value) =>
      state = state.copyWith(keyword: value, clearError: true);

  void setSort(FileSort sort) {
    // 再点同一列切升降序，符合桌面文件管理器的习惯。
    if (sort == state.sort) {
      state = state.copyWith(descending: !state.descending);
    } else {
      state = state.copyWith(sort: sort, descending: false);
    }
  }

  void toggleHidden() {
    state = state.copyWith(showHidden: !state.showHidden);
    _savePrefs();
  }

  void setViewMode(FileViewMode mode) {
    if (mode == state.viewMode) return;
    state = state.copyWith(viewMode: mode);
    _savePrefs();
  }

  void toggleSelect(String path) {
    final next = {...state.selected};
    if (!next.remove(path)) next.add(path);
    state = state.copyWith(selected: next);
  }

  void clearSelection() => state = state.copyWith(selected: const {});

  void selectAll() => state = state.copyWith(
        selected: {for (final e in state.visibleEntries) e.path},
      );

  /// 递归搜索当前目录。
  Future<void> search(String keyword, {bool matchContent = false}) async {
    final text = keyword.trim();
    if (text.isEmpty) {
      state = state.copyWith(clearSearch: true, searching: false);
      return;
    }
    if (state.scope == FileScope.app) {
      state = state.copyWith(error: 'APP 目录暂不支持递归搜索');
      return;
    }
    state = state.copyWith(searching: true, clearError: true);
    try {
      final hits = state.scope == FileScope.ssh
          ? await _sshSearch(text)
          : await _searchPython(text, matchContent: matchContent);
      state = state.copyWith(searchResults: hits, searching: false);
    } catch (e) {
      state = state.copyWith(searching: false, error: _message(e));
    }
  }

  /// SSH 远程目录递归搜索：只搜文件名（SFTP 不提供内容搜索）。
  Future<List<ShellFileEntry>> _sshSearch(String pattern,
      {int limit = 200}) async {
    final id = state.sshSessionId;
    if (id == null) throw StateError('没有选择 SSH 会话');
    final sftp = await _sftpFor(id);
    final rx = RegExp(pattern);
    final hits = <ShellFileEntry>[];
    Future<void> walk(String dir, int depth) async {
      if (depth > 12 || hits.length >= limit) return;
      final items = await sftp.listdir(dir);
      for (final item in items) {
        if (hits.length >= limit) return;
        final name = item.filename;
        if (name.isEmpty || name == '.' || name == '..') continue;
        final path = _sshJoin(dir, name);
        if (rx.hasMatch(name)) {
          hits.add(ShellFileEntry(
            name: name,
            path: path,
            isDirectory: item.attr.isDirectory,
            size: item.attr.size ?? 0,
            modified: DateTime.fromMillisecondsSinceEpoch(
              (item.attr.modifyTime ?? 0) * 1000,
            ),
            readable: true,
            writable: true,
            hidden: name.startsWith('.'),
          ));
        }
        if (item.attr.isDirectory && depth < 12) {
          try {
            await walk(path, depth + 1);
          } catch (_) {}
        }
      }
    }

    await walk(state.path, 0);
    return hits;
  }

  /// 用 PRoot 里的 Python 做正则递归搜索。
  ///
  /// 原生的 searchFiles 只能做普通关键字、且内容只解 UTF-8；这里换成
  /// Python re + 多编码解码，就能支持「正则 + 内容命中」，和 AI 的
  /// shell_search_code 同一套能力。
  Future<List<ShellFileEntry>> _searchPython(
    String pattern, {
    required bool matchContent,
    int limit = 200,
  }) async {
    const script = r'''
import os, re, sys, json, time
root, pattern_raw, limit_raw, match_content = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4] == '1'
limit = int(limit_raw)
try:
    rx = re.compile(pattern_raw)
except re.error:
    rx = re.compile(re.escape(pattern_raw))

def decode_text(data):
    if data.startswith(b'\xff\xfe') or data.startswith(b'\xfe\xff'):
        try:
            return data.decode('utf-16')
        except Exception:
            pass
    if data.count(0) > 0:
        for enc in ('utf-16-le', 'utf-16-be'):
            try:
                return data.decode(enc)
            except Exception:
                pass
    try:
        return data.decode('utf-8')
    except UnicodeDecodeError:
        try:
            return data.decode('gbk')
        except Exception:
            return data.decode('latin-1', errors='replace')

def entry(p, is_dir, matched=False):
    try:
        st = os.stat(p)
    except Exception:
        return None
    base = os.path.basename(p) if p != root else (root.rstrip('/').split('/')[-1] or root)
    return {
        'name': base,
        'path': p,
        'isDirectory': is_dir,
        'size': 0 if is_dir else st.st_size,
        'modified': int(st.st_mtime * 1000),
        'readable': True,
        'writable': True,
        'executable': os.access(p, os.X_OK),
        'hidden': base.startswith('.'),
        'matchedContent': matched,
    }

def file_content_hit(f):
    if not match_content:
        return False
    if os.path.getsize(f) > 4 * 1024 * 1024:
        return False
    try:
        with open(f, 'rb') as fh:
            data = fh.read()
        return bool(rx.search(decode_text(data)))
    except Exception:
        return False

if not os.path.exists(root):
    print(json.dumps({'error': '路径不存在', 'path': root}, ensure_ascii=False))
    sys.exit(0)

hits = []
if os.path.isdir(root):
    for dirpath, dirnames, filenames in os.walk(root, followlinks=True):
        dirnames[:] = [d for d in dirnames if d not in ('.git', '.dart_tool', 'build', 'node_modules')]
        for d in dirnames:
            if len(hits) >= limit:
                break
            p = os.path.join(dirpath, d)
            if rx.search(d):
                e = entry(p, True)
                if e is not None:
                    hits.append(e)
        for fn in filenames:
            if len(hits) >= limit:
                break
            p = os.path.join(dirpath, fn)
            matched = rx.search(fn) is not None
            if matched or file_content_hit(p):
                e = entry(p, False, matched)
                if e is not None:
                    hits.append(e)
        if len(hits) >= limit:
            break
else:
    base = os.path.basename(root)
    matched = rx.search(base) is not None
    if matched or file_content_hit(root):
        e = entry(root, False, matched)
        if e is not None:
            hits.append(e)

print(json.dumps({'path': root, 'pattern': pattern_raw, 'matches': hits[:limit]}, ensure_ascii=False))
''';
    final result = await _bridge.exec(
      command: 'python3',
      args: [
        '-c',
        script,
        state.path,
        pattern,
        '$limit',
        matchContent ? '1' : '0',
      ],
      timeoutSeconds: 120,
    );
    if (result.exitCode != 0) {
      final stderr = result.stderr.trim();
      if (stderr.isNotEmpty) throw Exception(stderr);
      throw Exception('搜索进程失败');
    }
    final output = result.stdout.trim();
    if (output.isEmpty) return const [];
    final decoded = jsonDecode(output);
    if (decoded is! Map) throw const FormatException('搜索结果格式异常');
    final rawMatches = decoded['matches'];
    if (rawMatches is! List) return const [];
    return [
      for (final m in rawMatches)
        if (m is Map) ShellFileEntry.fromMap(m),
    ];
  }

  void exitSearch() => state = state.copyWith(clearSearch: true);

  String _adbId() => state.adbSessionId!;

  String _shq(String p) => "'${p.replaceAll("'", "'\\''")}'";

  String _adbJoin(String dir, String name) {
    final clean = name.trim();
    if (dir.endsWith('/')) return '$dir$clean';
    return '$dir/$clean';
  }

  /// ADB 目录列表：用 `ls -la` 输出解析，兼容 Android toybox。
  ///
  /// 两个容易踩的坑：
  /// 1. Android toybox 的日期是 `YYYY-MM-DD HH:MM` 两列，文件名在第 7 列；
  ///    而 GNU coreutils 是 `Mon DD HH:MM` 三列，文件名在第 8 列。以前按
  ///    GNU 固定取第 8 列，结果小米/toybox 上普通文件全部解析不出来。
  /// 2. `/sdcard` 本身是软链接，直接 `ls -la /sdcard` 只会得到一行
  ///    `sdcard -> /storage/...`；先 readlink -f 解析到真实目录再列。
  Future<ShellDirectoryListing> _adbListing(String path) async {
    final id = _adbId();
    final manager = AdbSessionManager.instance;
    if (manager.connectionOf(id) == null) {
      final draft = manager.draftOf(id);
      if (draft == null) throw StateError('ADB 设备不存在');
      final session = await manager.connect(draft, id: id);
      if (!session.isConnected) throw StateError(session.status);
    }
    final realPath = await _adbRealPath(id, path);
    final raw = await manager.execute(id, 'ls -la ${_shq(realPath)}');
    final lines = raw.split('\n');
    final entries = <ShellFileEntry>[];
    String? errorLine;
    for (final line in lines) {
      final trimmed = line.trim();
      if (trimmed.startsWith('ls:')) {
        final lower = trimmed.toLowerCase();
        if (errorLine == null &&
            (lower.contains('permission denied') ||
                lower.contains('no such file') ||
                lower.contains('not a directory'))) {
          errorLine = trimmed;
        }
        continue;
      }
      final entry = _parseAdbLsLine(line, realPath);
      if (entry != null) entries.add(entry);
    }
    if (entries.isEmpty && errorLine != null) {
      throw StateError(
        errorLine.replaceFirst(RegExp(r'^ls:\s*'), '').trim(),
      );
    }
    return ShellDirectoryListing(
      path: realPath,
      roots: const ['/storage/emulated/0', '/data/local/tmp'],
      entries: entries,
    );
  }

  /// 把软链接解析到真实路径；Toybox readlink 不支持时会原样返回。
  Future<String> _adbRealPath(String id, String path) async {
    try {
      final out = await AdbSessionManager.instance
          .execute(id, 'readlink -f ${_shq(path)}');
      final resolved = out.trim();
      // Toybox readlink -f 正常输出绝对路径；命令不存在/报错时可能返回
      // `/system/bin/sh: readlink: not found`，不能把它当路径。
      if (resolved.startsWith('/') &&
          !resolved.contains('\n') &&
          !resolved.contains('not found') &&
          !resolved.startsWith('readlink:')) {
        return resolved;
      }
    } catch (_) {}
    return path;
  }

  ShellFileEntry? _parseAdbLsLine(String line, String dir) {
    final trimmed = line.trimRight();
    if (trimmed.isEmpty ||
        trimmed.startsWith('total ') ||
        trimmed.startsWith('ls: ')) {
      return null;
    }
    final parts = trimmed.split(RegExp(r'\s+'));
    // 有些目录（/、/data 等）元数据被 SELinux 遮住，行内会有
    // `-????????? ? ? ? ? ? init.environ.rc` 只有 7 列，不能按 8 列拒掉。
    if (parts.length < 7) return null;
    final perms = parts[0];
    if (!perms.startsWith('-') &&
        !perms.startsWith('d') &&
        !perms.startsWith('l')) {
      return null;
    }

    // 位 5 是日期列：
    // - Android toybox: 2025-09-07 01:07 name  → 名字从第 7 列开始
    // - GNU coreutils:  Sep  7 01:07 name       → 名字从第 8 列开始
    // - 元数据缺失:     ? ? ? ? ? name           → 名字紧跟在元数据后
    final f5 = parts.length > 5 ? parts[5] : '';
    final bool toyboxDate = RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(f5);
    final bool gnuMonth = RegExp(r'^[A-Za-z]{3}$').hasMatch(f5);
    final arrowIndex = parts.indexOf('->');
    final logicalEnd = arrowIndex >= 0 ? arrowIndex : parts.length;
    final int nameStart;
    if (toyboxDate) {
      nameStart = 7;
    } else if (gnuMonth) {
      nameStart = 8;
    } else {
      // 元数据缺失时至少取 `->` 前最后一个 token 作为文件名。
      nameStart = logicalEnd - 1;
    }
    if (nameStart < 1 || nameStart >= logicalEnd) return null;

    // 软链接行是 `name -> target`，展示名只留 name；路径解析交给 _adbRealPath。
    final name = parts.sublist(nameStart, logicalEnd).join(' ').trim();
    if (name.isEmpty || name == '.' || name == '..') return null;

    final size = int.tryParse(parts[4]) ?? 0;
    final isDir = perms.startsWith('d') || perms.startsWith('l');
    final hidden = name.startsWith('.');

    var modified = DateTime.now();
    if (toyboxDate) {
      final time = (parts.length > 6 && parts[6].contains(':'))
          ? parts[6]
          : '00:00';
      modified = DateTime.tryParse('$f5 $time') ?? modified;
    } else if (gnuMonth) {
      final month = _monthNumber(f5);
      final day = int.tryParse(parts[6]) ?? 1;
      final yearOrTime = parts.length > 7 ? parts[7] : '';
      if (yearOrTime.contains(':')) {
        modified = DateTime.tryParse(
              '${DateTime.now().year}-'
              '${month.toString().padLeft(2, '0')}-'
              '${day.toString().padLeft(2, '0')} $yearOrTime',
            ) ??
            modified;
      } else {
        final year = int.tryParse(yearOrTime) ?? DateTime.now().year;
        modified = DateTime(year, month, day);
      }
    }

    return ShellFileEntry(
      name: name,
      path: _adbJoin(dir, name),
      isDirectory: isDir,
      size: size,
      modified: modified,
      readable: perms.length > 1 && perms[1] == 'r',
      writable: perms.length > 2 && perms[2] == 'w',
      executable: perms.length > 3 && perms[3] == 'x',
      hidden: hidden,
    );
  }

  static int _monthNumber(String name) {
    const months = {
      'Jan': 1, 'Feb': 2, 'Mar': 3, 'Apr': 4, 'May': 5, 'Jun': 6,
      'Jul': 7, 'Aug': 8, 'Sep': 9, 'Oct': 10, 'Nov': 11, 'Dec': 12,
    };
    return months[name] ?? 1;
  }

  Future<String> _adbRead(String path) async {
    final id = _adbId();
    return AdbSessionManager.instance.execute(id, 'cat ${_shq(path)}');
  }

  Future<Uint8List?> _adbReadBytes(String path) async {
    final id = _adbId();
    final out =
        await AdbSessionManager.instance.execute(id, 'base64 ${_shq(path)}');
    final normalized = out.replaceAll(RegExp(r'\s'), '');
    if (normalized.isEmpty) return null;
    try {
      return base64Decode(normalized);
    } catch (e) {
      throw StateError('ADB 读取二进制失败：$e');
    }
  }

  Future<bool> _adbWriteBytes(String path, Uint8List bytes) async {
    final id = _adbId();
    final b64 = base64Encode(bytes);
    if (b64.isEmpty) {
      await AdbSessionManager.instance.execute(id, 'touch ${_shq(path)}');
      return true;
    }
    // 分 32KB 块写，避免单条 shell 命令过长。
    for (var offset = 0; offset < b64.length; offset += 32000) {
      final chunk = b64.substring(
          offset, offset + 32000 > b64.length ? b64.length : offset + 32000);
      final append = offset == 0 ? '>' : '>>';
      final quoted = chunk.replaceAll("'", "'\\''");
      await AdbSessionManager.instance.execute(
        id,
        "echo '$quoted' | base64 -d $append '${path.replaceAll("'", "'\\''")}'",
      );
    }
    return true;
  }

  Future<void> _adbDelete(String path) async {
    await AdbSessionManager.instance
        .execute(_adbId(), 'rm -rf ${_shq(path)}');
  }

  Future<void> _adbRename(String from, String to) async {
    await AdbSessionManager.instance
        .execute(_adbId(), 'mv ${_shq(from)} ${_shq(to)}');
  }

  Future<void> _adbMkdir(String path) async {
    await AdbSessionManager.instance
        .execute(_adbId(), 'mkdir -p ${_shq(path)}');
  }

  Future<ShellFileEntry> _adbStat(String path) async {
    final raw = await AdbSessionManager.instance
        .execute(_adbId(), 'ls -ld ${_shq(path)}');
    final entry = _parseAdbLsLine(raw.trim(), path.endsWith('/') ? path.substring(0, path.length - 1) : path) ??
        ShellFileEntry(
          name: path.split('/').last,
          path: path,
          isDirectory: false,
          size: 0,
          modified: DateTime.now(),
        );
    return entry;
  }

  Future<void> _adbCopy(String from, String to) async {
    final id = _adbId();
    // 先试 cp -rf；部分精简 ROM 没有 cp 时退化为 base64 字节中转。
    final cmd = 'cp -rf ${_shq(from)} ${_shq(to)}';
    final out = await AdbSessionManager.instance.execute(id, cmd);
    if (out.trim().isNotEmpty && !out.startsWith('usage')) {
      throw StateError(out.trim());
    }
  }

  Future<void> _adbMove(String from, String to) async {
    await _adbRename(from, to);
  }

  /// 当前作用域给原生侧的标记。两套目录树在磁盘上是嵌套的
  /// （guest 的 /workspace 就在 filesDir 下），路径字符串分不出来，必须带上。
  String get _scope => switch (state.scope) {
        FileScope.shell => 'shell',
        FileScope.app => 'app',
        FileScope.ssh => 'ssh',
        FileScope.adb => 'adb',
      };

  Future<String?> readFile(String path) async {
    try {
      if (state.scope == FileScope.ssh) {
        final sftp = await _sftpFor(state.sshSessionId!);
        final f = await sftp.open(path);
        final bytes = await f.readBytes();
        return utf8.decode(bytes, allowMalformed: true);
      }
      if (state.scope == FileScope.adb) {
        return await _adbRead(path);
      }
      return await _bridge.readFile(path: path, scope: _scope);
    } catch (e) {
      state = state.copyWith(error: _message(e));
      return null;
    }
  }

  /// 按原始字节读取当前作用域文件（跨区中转/容器粘贴等场景用）。
  Future<Uint8List?> readBytes(String path) async {
    try {
      if (state.scope == FileScope.ssh) {
        final sftp = await _sftpFor(state.sshSessionId!);
        final f = await sftp.open(path);
        final bytes = await f.readBytes();
        await f.close();
        return bytes;
      }
      if (state.scope == FileScope.adb) {
        return await _adbReadBytes(path);
      }
      final host = await _bridge.hostPath(path: path, scope: _scope);
      if (host.isEmpty) return null;
      return File(host).readAsBytes();
    } catch (e) {
      state = state.copyWith(error: _message(e));
      return null;
    }
  }

  /// 按原始字节读取指定作用域文件（跨区中转用，不依赖当前 state.scope）。
  Future<Uint8List?> readBytesAtScope(
    String path,
    FileScope scope,
    String? sshId, {
    String? adbId,
  }) async {
    try {
      if (scope == FileScope.adb) {
        return await AdbSessionManager.instance
            .runBase64Read(adbId!, path);
      }
      if (scope == FileScope.ssh) {
        final sftp = await _sftpFor(sshId!);
        final f = await sftp.open(path);
        final bytes = await f.readBytes();
        await f.close();
        return bytes;
      }
      final host = await _bridge.hostPath(path: path, scope: scope.name);
      if (host.isEmpty) return null;
      return File(host).readAsBytes();
    } catch (e) {
      state = state.copyWith(error: _message(e));
      return null;
    }
  }

  /// 按原始字节写入当前作用域文件（容器中转粘贴到本地/SSH 用）。
  Future<bool> writeBytes(String path, Uint8List bytes) async {
    try {
      if (state.scope == FileScope.ssh) {
        final sftp = await _sftpFor(state.sshSessionId!);
        final dst = await sftp.open(
          path,
          mode: SftpFileOpenMode.write |
              SftpFileOpenMode.create |
              SftpFileOpenMode.truncate,
        );
        await dst.writeBytes(bytes);
        await dst.close();
        await refresh();
        return true;
      }
      if (state.scope == FileScope.adb) {
        await _adbWriteBytes(path, bytes);
        await refresh();
        return true;
      }
      final host = await _bridge.hostPath(path: path, scope: _scope);
      if (host.isEmpty) return false;
      await File(host).writeAsBytes(bytes, flush: true);
      await refresh();
      return true;
    } catch (e) {
      state = state.copyWith(error: _message(e));
      return false;
    }
  }

  /// 删除指定作用域里的文件/目录（跨区剪切到容器后清理源文件用）。
  Future<bool> deleteAtScope(String path, FileScope scope, String? sshId,
      {String? adbId}) async {
    try {
      if (scope == FileScope.adb) {
        await AdbSessionManager.instance
            .execute(adbId!, 'rm -rf ${_shq(path)}');
        if (state.scope == scope && state.adbSessionId == adbId) await refresh();
        return true;
      }
      if (scope == FileScope.ssh) {
        final sftp = await _sftpFor(sshId!);
        await sftp.remove(path);
        if (state.scope == scope && state.sshSessionId == sshId) await refresh();
        return true;
      }
      await _bridge.deletePath(path, scope: scope.name);
      if (state.scope == scope) await refresh();
      return true;
    } catch (e) {
      state = state.copyWith(error: _message(e));
      return false;
    }
  }

  /// 取宿主真实路径（内置图片查看器要用）。
  Future<String?> hostPath(String path) async {
    if (state.scope == FileScope.ssh) return null;
    if (state.scope == FileScope.adb) return null;
    try {
      return await _bridge.hostPath(path: path, scope: _scope);
    } catch (e) {
      state = state.copyWith(error: _message(e));
      return null;
    }
  }

  /// 交给系统里别的 APP 打开 / 分享。
  Future<bool> openExternal(
    String path, {
    required String mime,
    bool share = false,
  }) async {
    try {
      return await _bridge.openExternal(
        path: path,
        mime: mime,
        scope: _scope,
        share: share,
      );
    } catch (e) {
      state = state.copyWith(error: _message(e));
      return false;
    }
  }

  Future<bool> saveFile(String path, String content) => _guard(
        () => state.scope == FileScope.ssh
            ? _sshWrite(path, content)
            : state.scope == FileScope.adb
                ? _adbWriteBytes(path, Uint8List.fromList(utf8.encode(content)))
                : _bridge.writeFile(path: path, content: content, scope: _scope),
      );

  Future<bool> createDirectory(String name) => _guard(
        () => state.scope == FileScope.ssh
            ? _sftpFor(state.sshSessionId!)
                .then((sftp) => sftp.mkdir(_sshJoin(state.path, name)))
            : state.scope == FileScope.adb
                ? _adbMkdir(_adbJoin(state.path, name))
                : _bridge.makeDirectory(_join(state.path, name), scope: _scope),
      );

  Future<bool> createFile(String name) => _guard(
        () => state.scope == FileScope.ssh
            ? _sshWrite(_sshJoin(state.path, name), '')
            : state.scope == FileScope.adb
                ? _adbWriteBytes(_adbJoin(state.path, name), Uint8List(0))
                : _bridge.writeFile(
                    path: _join(state.path, name),
                    content: '',
                    scope: _scope,
                  ),
      );

  Future<bool> delete(String path) => _guard(
        () => state.scope == FileScope.ssh
            ? _sshDelete(path)
            : state.scope == FileScope.adb
                ? _adbDelete(path)
                : _bridge.deletePath(path, scope: _scope),
      );

  Future<void> _sshWrite(String path, String content) async {
    final sftp = await _sftpFor(state.sshSessionId!);
    final f = await sftp.open(
      path,
      mode: SftpFileOpenMode.write |
          SftpFileOpenMode.create |
          SftpFileOpenMode.truncate,
    );
    await f.writeBytes(Uint8List.fromList(utf8.encode(content)));
    await f.close();
  }

  Future<void> _sshDelete(String path) async {
    final sftp = await _sftpFor(state.sshSessionId!);
    final info = await sftp.stat(path);
    if (info.isDirectory) {
      await sftp.rmdir(path);
    } else {
      await sftp.remove(path);
    }
  }

  /// 从别的 APP 导入文件到当前目录（系统文件选择器）。
  ///
  /// 不走 `_guard`：取消不是错误、部分失败也要照样把成功的那些刷出来，
  /// 这些区别 `_guard` 的"成功/失败"二元语义表达不了。
  Future<ShellImportResult?> importFiles() async {
    try {
      if (state.scope == FileScope.ssh) {
        final picked = await FilePicker.pickFiles(allowMultiple: true);
        if (picked == null) {
          return const ShellImportResult(
            canceled: true,
            files: [],
            failed: [],
          );
        }
        final sftp = await _sftpFor(state.sshSessionId!);
        final files = <ShellFileEntry>[];
        final failed = <({String name, String error})>[];
        for (final f in picked.files) {
          final local = f.path;
          if (local == null) continue;
          final remote = _sshJoin(state.path, f.name);
          try {
            final dst = await sftp.open(
              remote,
              mode: SftpFileOpenMode.write |
                  SftpFileOpenMode.create |
                  SftpFileOpenMode.truncate,
            );
            await dst.write(File(local).openRead().cast()).done;
            await dst.close();
            files.add(ShellFileEntry(
              name: f.name,
              path: remote,
              isDirectory: false,
              size: f.size,
              modified: DateTime.now(),
              readable: true,
              writable: true,
            ));
          } catch (e) {
            failed.add((name: f.name, error: _message(e)));
          }
        }
        await refresh();
        if (failed.isNotEmpty) {
          state = state.copyWith(
            error: '${failed.first.name}：${failed.first.error}',
          );
        }
        return ShellImportResult(canceled: false, files: files, failed: failed);
      }
      if (state.scope == FileScope.adb) {
        final picked = await FilePicker.pickFiles(allowMultiple: true);
        if (picked == null) {
          return const ShellImportResult(
            canceled: true,
            files: [],
            failed: [],
          );
        }
        final files = <ShellFileEntry>[];
        final failed = <({String name, String error})>[];
        for (final f in picked.files) {
          final local = f.path;
          if (local == null) continue;
          final remote = _adbJoin(state.path, f.name);
          try {
            final bytes = await File(local).readAsBytes();
            await _adbWriteBytes(remote, bytes);
            files.add(ShellFileEntry(
              name: f.name,
              path: remote,
              isDirectory: false,
              size: bytes.length,
              modified: DateTime.now(),
              readable: true,
              writable: true,
            ));
          } catch (e) {
            failed.add((name: f.name, error: _message(e)));
          }
        }
        await refresh();
        if (failed.isNotEmpty) {
          state = state.copyWith(
            error: '${failed.first.name}：${failed.first.error}',
          );
        }
        return ShellImportResult(canceled: false, files: files, failed: failed);
      }
      final result = await _bridge.importFiles(path: state.path, scope: _scope);
      // 有文件落地就刷新列表；一个都没成功就别白刷一次。
      if (result.files.isNotEmpty) await refresh();
      if (result.failed.isNotEmpty) {
        state = state.copyWith(
          error: '${result.failed.first.name}：${result.failed.first.error}',
        );
      }
      return result;
    } catch (e) {
      state = state.copyWith(error: _message(e));
      return null;
    }
  }

  /// 批量删除选中项。任何一项失败都记下来，其余继续删。
  Future<int> deleteSelected() async {
    final targets = state.selected.toList();
    var ok = 0;
    String? firstError;
    for (final path in targets) {
      try {
        if (state.scope == FileScope.ssh) {
          await _sshDelete(path);
        } else if (state.scope == FileScope.adb) {
          await _adbDelete(path);
        } else {
          await _bridge.deletePath(path, scope: _scope);
        }
        ok++;
      } catch (e) {
        firstError ??= _message(e);
      }
    }
    state = state.copyWith(selected: const {}, error: firstError);
    await refresh();
    return ok;
  }

  Future<bool> rename(ShellFileEntry entry, String newName) => _guard(
        () => state.scope == FileScope.ssh
            ? _sftpFor(state.sshSessionId!).then((sftp) =>
                sftp.rename(entry.path, _sshJoin(state.path, newName)))
            : state.scope == FileScope.adb
                ? _adbRename(entry.path, _adbJoin(state.path, newName))
                : _bridge.movePath(
                    from: entry.path,
                    to: _join(state.path, newName),
                    scope: _scope,
                  ),
      );

  /// 读取图片原始字节（本地走宿主文件，SSH 走 SFTP）。
  Future<Uint8List?> readImageRawBytes(String path) async {
    try {
      if (state.scope == FileScope.ssh) {
        final sftp = await _sftpFor(state.sshSessionId!);
        final f = await sftp.open(path);
        try {
          return await f.readBytes();
        } finally {
          await f.close();
        }
      }
      if (state.scope == FileScope.adb) {
        return await _adbReadBytes(path);
      }
      final host = await hostPath(path);
      if (host == null || host.isEmpty) return null;
      return await File(host).readAsBytes();
    } catch (e) {
      return null;
    }
  }

  /// 经过 Android 原生解码后的 PNG 字节，用来显示缩略图和图片查看器。
  /// [thumbnail] 为 true 时用较小尺寸并走缓存；查看器用更清晰的大图。
  Future<Uint8List?> readImageBytes(String path,
      {bool thumbnail = true}) async {
    final key = '${thumbnail ? 'thumb' : 'view'}:$path';
    final cached = _imageCache[key];
    if (cached != null) return cached;
    final raw = await readImageRawBytes(path);
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = await _bridge.decodeImage(
        raw,
        maxDimension: thumbnail ? 320 : 2048,
      );
      if (_imageCache.length > 400) _imageCache.clear();
      _imageCache[key] = decoded;
      return decoded;
    } catch (e) {
      // 原生解码失败（个别 ROM/特殊格式）时，收藏器（大图）退回 Flutter
      // 自带的 JPEG/PNG/WebP/GIF 解码；缩略图不退回原图，避免大图列表卡顿。
      if (!thumbnail) {
        if (_imageCache.length > 400) _imageCache.clear();
        _imageCache[key] = raw;
        return raw;
      }
      return null;
    }
  }

  Future<ShellFileStat?> stat(String path) async {
    try {
      if (state.scope == FileScope.ssh) {
        final sftp = await _sftpFor(state.sshSessionId!);
        final attrs = await sftp.stat(path);
        final name = path.split('/').last;
        final isDir = attrs.isDirectory;
        return ShellFileStat(
          entry: ShellFileEntry(
            name: name.isEmpty ? path : name,
            path: path,
            isDirectory: isDir,
            size: attrs.size ?? 0,
            modified: DateTime.fromMillisecondsSinceEpoch(
              (attrs.modifyTime ?? 0) * 1000,
            ),
            readable: true,
            writable: true,
            hidden: name.startsWith('.'),
          ),
          totalBytes: attrs.size ?? 0,
          fileCount: isDir ? 0 : 1,
          dirCount: isDir ? 1 : 0,
          hostPath: path,
        );
      }
      if (state.scope == FileScope.adb) {
        final entry = await _adbStat(path);
        final isDir = entry.isDirectory;
        return ShellFileStat(
          entry: entry,
          totalBytes: entry.size,
          fileCount: isDir ? 0 : 1,
          dirCount: isDir ? 1 : 0,
          hostPath: 'adb://${state.adbSessionId}$path',
        );
      }
      return await _bridge.stat(path, scope: _scope);
    } catch (e) {
      state = state.copyWith(error: _message(e));
      return null;
    }
  }

  Future<bool> setPermissions({
    required String path,
    bool? readable,
    bool? writable,
    bool? executable,
  }) =>
      _guard(() => _bridge.setPermissions(
            scope: _scope,
            path: path,
            readable: readable,
            writable: writable,
            executable: executable,
          ));

  void copyToClipboard(String path) => state = state.copyWith(
        clipboardPath: path,
        clipboardIsCut: false,
        clipboardScope: state.scope.name,
        clipboardSshId:
            state.scope == FileScope.ssh ? state.sshSessionId : null,
        clipboardAdbId:
            state.scope == FileScope.adb ? state.adbSessionId : null,
      );

  void cutToClipboard(String path) => state = state.copyWith(
        clipboardPath: path,
        clipboardIsCut: true,
        clipboardScope: state.scope.name,
        clipboardSshId:
            state.scope == FileScope.ssh ? state.sshSessionId : null,
        clipboardAdbId:
            state.scope == FileScope.adb ? state.adbSessionId : null,
      );

  /// 粘贴：剪切 = move，复制 = copy。同名自动加后缀，不覆盖已有文件。
  ///
  /// [targetDir] 给"长按某个文件夹 → 粘贴进去"用：不填就粘到当前目录。
  Future<bool> paste({String? targetDir}) async {
    final source = state.clipboardPath;
    if (source == null) return false;
    final dir = targetDir ?? state.path;
    final name = source.split('/').last;
    String join(String d, String n) => state.scope == FileScope.ssh
        ? _sshJoin(d, n)
        : state.scope == FileScope.adb
            ? _adbJoin(d, n)
            : _join(d, n);
    var target = join(dir, name);
    // 同名自动加后缀，不覆盖已有文件。
    final existing = dir == state.path
        ? {for (final e in state.entries) e.path}
        : <String>{};
    if (existing.contains(target)) {
      final dot = name.lastIndexOf('.');
      final stem = dot > 0 ? name.substring(0, dot) : name;
      final ext = dot > 0 ? name.substring(dot) : '';
      var i = 2;
      while (existing.contains(target)) {
        target = join(dir, '$stem($i)$ext');
        i++;
      }
    }
    final cut = state.clipboardIsCut;
    final ok = await _guard(() => _pasteAction(source, target, cut, dir));
    if (ok) state = state.copyWith(clearClipboard: true);
    return ok;
  }

  Future<void> _pasteAction(
    String source,
    String target,
    bool cut,
    String dir,
  ) async {
    final sourceScopeName = state.clipboardScope;
    final sourceSshId = state.clipboardSshId;
    final sourceAdbId = state.clipboardAdbId;
    final sourceScope = sourceScopeName == null
        ? state.scope
        : FileScope.values.firstWhere(
            (e) => e.name == sourceScopeName,
            orElse: () => state.scope,
          );
    final sameScope = sourceScope == state.scope &&
        ((sourceScope != FileScope.ssh && sourceScope != FileScope.adb) ||
            (sourceScope == FileScope.ssh &&
                sourceSshId == state.sshSessionId) ||
            (sourceScope == FileScope.adb &&
                sourceAdbId == state.adbSessionId));

    if (sameScope) {
      if (state.scope == FileScope.adb) {
        if (cut) {
          await _adbMove(source, target);
        } else {
          await _adbCopy(source, target);
        }
        return;
      }
      if (state.scope == FileScope.ssh) {
        final remoteTarget = target;
        if (cut) {
          await _sftpFor(state.sshSessionId!)
              .then((sftp) => sftp.rename(source, remoteTarget));
        } else {
          await _sshCopy(source, remoteTarget);
        }
        return;
      }
      if (cut) {
        await _bridge.movePath(from: source, to: target, scope: _scope);
      } else {
        await _bridge.copyPath(from: source, to: target, scope: _scope);
      }
      return;
    }

    // 跨区：先判断目录。目录级跨区暂不支持，避免半截复制。
    final isDir = await _crossSourceIsDir(
      source,
      sourceScope,
      sourceSshId,
      adbId: sourceAdbId,
    );
    if (isDir) {
      throw StateError('跨区复制/剪切暂只支持文件，文件夹请先从里面复制文件');
    }

    // SSH -> 终端/APP/ADB
    if (sourceScope == FileScope.ssh && state.scope != FileScope.ssh) {
      final sftp = await _sftpFor(sourceSshId!);
      final src = await sftp.open(source);
      final bytes = await src.readBytes();
      await src.close();
      if (state.scope == FileScope.adb) {
        await _adbWriteBytes(target, bytes);
      } else {
        final host = await _hostPathFor(target, state.scope);
        if (host.isEmpty) {
          throw StateError('目标目录不存在或不可写');
        }
        await File(host).writeAsBytes(bytes, flush: true);
      }
      if (cut) await _sftpFor(sourceSshId).then((s) => s.remove(source));
      return;
    }

    // 终端/APP/ADB -> SSH
    if (sourceScope != FileScope.ssh && state.scope == FileScope.ssh) {
      Uint8List bytes;
      if (sourceScope == FileScope.adb) {
        final raw = await AdbSessionManager.instance
            .runBase64Read(sourceAdbId!, source);
        if (raw == null) throw StateError('ADB 读取源文件失败');
        bytes = raw;
      } else {
        final host = await _hostPathFor(source, sourceScope);
        if (host.isEmpty) {
          throw StateError('取不到源文件宿主路径（文件不存在或已删除）');
        }
        bytes = await File(host).readAsBytes();
      }
      final sftp = await _sftpFor(state.sshSessionId!);
      final dst = await sftp.open(
        target,
        mode: SftpFileOpenMode.write |
            SftpFileOpenMode.create |
            SftpFileOpenMode.truncate,
      );
      await dst.writeBytes(bytes);
      await dst.close();
      if (cut) {
        if (sourceScope == FileScope.adb) {
          await AdbSessionManager.instance
              .execute(sourceAdbId!, 'rm -rf ${_shq(source)}');
        } else {
          await _bridge.deletePath(source, scope: sourceScope.name);
        }
      }
      return;
    }

    // ADB -> 终端/APP（源 ADB 目标本地）
    if (sourceScope == FileScope.adb && state.scope != FileScope.adb) {
      final raw = await AdbSessionManager.instance
          .runBase64Read(sourceAdbId!, source);
      if (raw == null) throw StateError('ADB 读取源文件失败');
      final bytes = raw;
      final host = await _hostPathFor(target, state.scope);
      if (host.isEmpty) {
        throw StateError('目标目录不存在或不可写');
      }
      await File(host).writeAsBytes(bytes, flush: true);
      if (cut) {
        await AdbSessionManager.instance
            .execute(sourceAdbId, 'rm -rf ${_shq(source)}');
      }
      return;
    }

    // 终端/APP -> ADB（源本地目标 ADB）
    if (sourceScope != FileScope.adb && state.scope == FileScope.adb) {
      Uint8List bytes;
      if (sourceScope == FileScope.ssh) {
        final sftp = await _sftpFor(sourceSshId!);
        final src = await sftp.open(source);
        bytes = await src.readBytes();
        await src.close();
      } else {
        final host = await _hostPathFor(source, sourceScope);
        if (host.isEmpty) {
          throw StateError('取不到源文件宿主路径（文件不存在或已删除）');
        }
        bytes = await File(host).readAsBytes();
      }
      await _adbWriteBytes(target, bytes);
      if (cut) {
        if (sourceScope == FileScope.ssh) {
          final sftp = await _sftpFor(sourceSshId!);
          await sftp.remove(source);
        } else {
          await _bridge.deletePath(source, scope: sourceScope.name);
        }
      }
      return;
    }

    // 终端 ↔ APP（不同 scope，但都在本地）
    final srcHost = await _hostPathFor(source, sourceScope);
    final dstHost = await _hostPathFor(target, state.scope);
    if (srcHost.isEmpty || dstHost.isEmpty) {
      throw StateError('取不到本地文件路径（文件不存在或已删除）');
    }
    await File(srcHost).copy(dstHost);
    if (cut) await _bridge.deletePath(source, scope: sourceScope.name);
  }

  Future<bool> _crossSourceIsDir(
    String path,
    FileScope scope,
    String? sshId, {
    String? adbId,
  }) async {
    try {
      if (scope == FileScope.adb) {
        final raw = await AdbSessionManager.instance
            .execute(adbId!, 'ls -ld ${_shq(path)}');
        return raw.trimLeft().startsWith('d');
      }
      if (scope == FileScope.ssh) {
        final sftp = await _sftpFor(sshId!);
        final attrs = await sftp.stat(path);
        return attrs.isDirectory;
      }
      final s = await _bridge.stat(path, scope: scope.name);
      return s.entry.isDirectory;
    } catch (_) {
      return false;
    }
  }

  Future<void> _sshCopy(String from, String to) async {
    final sftp = await _sftpFor(state.sshSessionId!);
    final src = await sftp.open(from);
    final dst = await sftp.open(
      to,
      mode: SftpFileOpenMode.write |
          SftpFileOpenMode.create |
          SftpFileOpenMode.truncate,
    );
    try {
      final bytes = await src.readBytes();
      await dst.writeBytes(bytes);
    } finally {
      await src.close();
      await dst.close();
    }
  }

  void clearError() => state = state.copyWith(clearError: true);

  /// 统一的「执行 → 刷新 → 出错记到 state」包装。
  Future<bool> _guard(Future<Object?> Function() action) async {
    try {
      await action();
      await refresh();
      return true;
    } catch (e) {
      state = state.copyWith(error: _message(e));
      return false;
    }
  }

  String _join(String dir, String name) {
    final clean = name.trim();
    if (dir.endsWith('/')) return '$dir$clean';
    return '$dir/$clean';
  }

  Future<String> _hostPathFor(String path, FileScope scope) async {
    try {
      // 粘贴目标是还没创建的新文件，必须允许 hostPath 解析不存在的路径。
      return await _bridge.hostPath(
        path: path,
        scope: scope.name,
        mustExist: false,
      );
    } catch (_) {
      return '';
    }
  }

  String _message(Object error) {
    final text = error.toString();
    final match = RegExp(r'message: ([^,)]+)').firstMatch(text);
    return match?.group(1)?.trim() ?? text;
  }
}

final shellFilesProvider =
    NotifierProvider<ShellFilesNotifier, ShellFilesState>(
  ShellFilesNotifier.new,
);
