import 'dart:convert';
import 'dart:typed_data';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/local_shell/proot_bridge.dart';
import 'ssh_session_provider.dart';

/// 文件管理的两套根：终端（PRoot guest 挂载点）与 APP 自身沙箱目录。
enum FileScope {
  /// 终端里看到的 /workspace、/home/coomi 等，与 shell 共享同一份文件。
  shell('终端文件'),

  /// APP 沙箱：filesDir / cacheDir / 外部 files 目录。
  app('APP 文件'),

  /// 已连接 SSH 会话的远程目录（SFTP）。
  ssh('SSH 文件');

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
    this.error,
  });

  final FileScope scope;

  /// 当前 SSH 会话 id（scope == ssh 时有效）。
  final String? sshSessionId;
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
    bool clearClipboard = false,
    String? error,
    bool clearError = false,
  }) {
    return ShellFilesState(
      scope: scope ?? this.scope,
      sshSessionId: clearSshSession ? null : sshSessionId ?? this.sshSessionId,
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
      error: clearError ? null : error ?? this.error,
    );
  }
}

class ShellFilesNotifier extends Notifier<ShellFilesState> {
  final _bridge = ProotBridge();
  final Map<String, SftpClient> _sftpClients = {};
  final Map<FileScope, String> _pathsByScope = {
    FileScope.shell: '/workspace',
    FileScope.app: '',
    FileScope.ssh: '/',
  };

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
      } else {
        listing = await _sshListing(target);
      }
      _pathsByScope[state.scope] = listing.path;
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
    var path = _pathsByScope[scope] ??
        (scope == FileScope.shell
            ? '/workspace'
            : scope == FileScope.app
                ? ''
                : '/');
    if (scope == FileScope.ssh) {
      if (sshId == null || SshSessionManager.instance.clientOf(sshId) == null) {
        final connected = [
          for (final s in SshSessionManager.instance.sessions)
            if (s.isConnected) s.id
        ];
        if (connected.isEmpty) {
          state = state.copyWith(
            scope: scope,
            sshSessionId: null,
            clearSshSession: true,
            entries: const [],
            selected: const {},
            clearError: false,
            clearClipboard: true,
            error: '请先在终端页连接 SSH，再打开 SSH 文件管理',
          );
          return;
        }
        sshId = connected.first;
      }
    }
    state = state.copyWith(
      scope: scope,
      sshSessionId: sshId,
      entries: const [],
      keyword: '',
      clearSearch: true,
      selected: const {},
      clearError: true,
      clearClipboard: true,
      path: path,
    );
    await open(path);
  }

  /// 切换当前 SSH 会话。
  Future<void> setSshSession(String? id) async {
    if (id == null || state.scope != FileScope.ssh) return;
    state = state.copyWith(
      sshSessionId: id,
      entries: const [],
      keyword: '',
      clearSearch: true,
      selected: const {},
      clearError: true,
      clearClipboard: true,
      path: '/',
    );
    await open('/');
  }

  Future<SftpClient> _sftpFor(String id) async {
    final existing = _sftpClients[id];
    if (existing != null) return existing;
    final client = SshSessionManager.instance.clientOf(id);
    if (client == null) throw StateError('SSH 未连接：$id');
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

  /// SSH 下两个路径是否来自同一会话（剪贴板跨会话粘贴不安全）。
  bool _sshClipboardSafe(String source) {
    if (state.scope != FileScope.ssh) return false;
    final id = state.sshSessionId;
    return id != null && (source.startsWith('/') || source.startsWith('~/'));
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

  /// 当前作用域给原生侧的标记。两套目录树在磁盘上是嵌套的
  /// （guest 的 /workspace 就在 filesDir 下），路径字符串分不出来，必须带上。
  String get _scope => switch (state.scope) {
        FileScope.shell => 'shell',
        FileScope.app => 'app',
        FileScope.ssh => 'ssh',
      };

  Future<String?> readFile(String path) async {
    try {
      if (state.scope == FileScope.ssh) {
        final sftp = await _sftpFor(state.sshSessionId!);
        final f = await sftp.open(path);
        final bytes = await f.readBytes();
        return utf8.decode(bytes, allowMalformed: true);
      }
      return await _bridge.readFile(path: path, scope: _scope);
    } catch (e) {
      state = state.copyWith(error: _message(e));
      return null;
    }
  }

  /// 取宿主真实路径（内置图片查看器要用）。
  Future<String?> hostPath(String path) async {
    if (state.scope == FileScope.ssh) return null;
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
            : _bridge.writeFile(path: path, content: content, scope: _scope),
      );

  Future<bool> createDirectory(String name) => _guard(
        () => state.scope == FileScope.ssh
            ? _sftpFor(state.sshSessionId!)
                .then((sftp) => sftp.mkdir(_sshJoin(state.path, name)))
            : _bridge.makeDirectory(_join(state.path, name), scope: _scope),
      );

  Future<bool> createFile(String name) => _guard(
        () => state.scope == FileScope.ssh
            ? _sshWrite(_sshJoin(state.path, name), '')
            : _bridge.writeFile(
                path: _join(state.path, name),
                content: '',
                scope: _scope,
              ),
      );

  Future<bool> delete(String path) => _guard(
        () => state.scope == FileScope.ssh
            ? _sshDelete(path)
            : _bridge.deletePath(path, scope: _scope),
      );

  Future<void> _sshWrite(String path, String content) async {
    final sftp = await _sftpFor(state.sshSessionId!);
    final f = await sftp.open(
      path,
      mode: SftpFileOpenMode.write | SftpFileOpenMode.truncate,
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
              mode: SftpFileOpenMode.write | SftpFileOpenMode.truncate,
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
            : _bridge.movePath(
                from: entry.path,
                to: _join(state.path, newName),
                scope: _scope,
              ),
      );

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

  void copyToClipboard(String path) =>
      state = state.copyWith(clipboardPath: path, clipboardIsCut: false);

  void cutToClipboard(String path) =>
      state = state.copyWith(clipboardPath: path, clipboardIsCut: true);

  /// 粘贴：剪切 = move，复制 = copy。同名自动加后缀，不覆盖已有文件。
  ///
  /// [targetDir] 给"长按某个文件夹 → 粘贴进去"用：不填就粘到当前目录。
  Future<bool> paste({String? targetDir}) async {
    final source = state.clipboardPath;
    if (source == null) return false;
    final dir = targetDir ?? state.path;
    final name = source.split('/').last;
    var target = _join(dir, name);
    // 粘到别的目录时手上没有那个目录的清单，同名判断只对当前目录有效；
    // 底层 copy/move 本身也拒绝覆盖，所以最坏情况是给出"目标已存在"错误。
    final existing = dir == state.path
        ? {for (final e in state.entries) e.path}
        : <String>{};
    if (existing.contains(target)) {
      final dot = name.lastIndexOf('.');
      final stem = dot > 0 ? name.substring(0, dot) : name;
      final ext = dot > 0 ? name.substring(dot) : '';
      var i = 2;
      while (existing.contains(target)) {
        target = _join(dir, '$stem($i)$ext');
        i++;
      }
    }
    final cut = state.clipboardIsCut;
    final ok = await _guard(() {
      if (state.scope == FileScope.ssh) {
        if (!_sshClipboardSafe(source)) {
          throw StateError('SSH 剪切板只支持同会话内粘贴');
        }
        final remoteDir = dir;
        final remoteTarget = _sshJoin(remoteDir, name);
        return cut
            ? _sftpFor(state.sshSessionId!)
                .then((sftp) => sftp.rename(source, remoteTarget))
            : _sshCopy(source, remoteTarget);
      }
      return cut
          ? _bridge.movePath(from: source, to: target, scope: _scope)
          : _bridge.copyPath(from: source, to: target, scope: _scope);
    });
    if (ok) state = state.copyWith(clearClipboard: true);
    return ok;
  }

  Future<void> _sshCopy(String from, String to) async {
    final sftp = await _sftpFor(state.sshSessionId!);
    final src = await sftp.open(from);
    final dst = await sftp.open(
      to,
      mode: SftpFileOpenMode.write | SftpFileOpenMode.truncate,
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
