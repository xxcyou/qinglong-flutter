import 'dart:async';

import 'package:flutter/services.dart';

class PreruntimeStatus {
  const PreruntimeStatus({
    required this.installed,
    required this.version,
    required this.runtimeRoot,
    required this.workspace,
  });

  final bool installed;
  final String version;
  final String runtimeRoot;
  final String workspace;

  factory PreruntimeStatus.fromMap(Map<dynamic, dynamic> map) {
    return PreruntimeStatus(
      installed: map['installed'] == true,
      version: (map['version'] as String? ?? ''),
      runtimeRoot: (map['runtimeRoot'] as String? ?? ''),
      workspace: (map['workspace'] as String? ?? ''),
    );
  }
}

class ExecResult {
  const ExecResult({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
  });

  final int exitCode;
  final String stdout;
  final String stderr;

  bool get success => exitCode == 0;

  factory ExecResult.fromMap(Map<dynamic, dynamic> map) {
    return ExecResult(
      exitCode: (map['code'] as num?)?.toInt() ?? -1,
      stdout: (map['stdout'] as String? ?? ''),
      stderr: (map['stderr'] as String? ?? ''),
    );
  }
}

/// PRoot guest 内的文件条目（路径为 guest 视角，如 /workspace/a.py）。
class ShellFileEntry {
  const ShellFileEntry({
    required this.name,
    required this.path,
    required this.isDirectory,
    required this.size,
    required this.modified,
    this.readable = true,
    this.writable = true,
    this.executable = false,
    this.hidden = false,
    this.matchedContent = false,
  });

  final String name;
  final String path;
  final bool isDirectory;
  final int size;
  final DateTime modified;

  /// 权限位。Android 沙箱只能拿到/设置 owner 的 rwx。
  final bool readable;
  final bool writable;
  final bool executable;
  final bool hidden;

  /// 搜索结果：命中的是文件内容而不是文件名。
  final bool matchedContent;

  /// 类 Unix 的 `rwx` 展示串。
  String get modeText =>
      '${readable ? 'r' : '-'}${writable ? 'w' : '-'}${executable ? 'x' : '-'}';

  factory ShellFileEntry.fromMap(Map<dynamic, dynamic> map) {
    return ShellFileEntry(
      name: map['name']?.toString() ?? '',
      path: map['path']?.toString() ?? '',
      isDirectory: map['isDirectory'] == true,
      size: (map['size'] as num?)?.toInt() ?? 0,
      modified: DateTime.fromMillisecondsSinceEpoch(
        (map['modified'] as num?)?.toInt() ?? 0,
      ),
      readable: map['readable'] != false,
      writable: map['writable'] != false,
      executable: map['executable'] == true,
      hidden: map['hidden'] == true,
      matchedContent: map['matchedContent'] == true,
    );
  }
}

/// 一次"从别的 APP 导入"的结果。
class ShellImportResult {
  const ShellImportResult({
    required this.canceled,
    required this.files,
    required this.failed,
  });

  /// 用户按返回键放弃了选择。不算错误，UI 应该静静收场。
  final bool canceled;

  /// 成功落地的文件。
  final List<ShellFileEntry> files;

  /// 单个文件失败的原因（名字 → 错误）。整批里一个失败不影响其余，
  /// 所以失败要单独报出来，不能整体抛异常。
  final List<({String name, String error})> failed;

  bool get isEmpty => files.isEmpty;

  factory ShellImportResult.fromMap(Map<dynamic, dynamic> map) {
    return ShellImportResult(
      canceled: map['canceled'] == true,
      files: [
        for (final f in (map['files'] as List? ?? const []))
          if (f is Map) ShellFileEntry.fromMap(f),
      ],
      failed: [
        for (final f in (map['failed'] as List? ?? const []))
          if (f is Map)
            (
              name: f['name']?.toString() ?? '',
              error: f['error']?.toString() ?? '未知错误',
            ),
      ],
    );
  }
}

/// `statPath` 的详细信息。
class ShellFileStat {
  const ShellFileStat({
    required this.entry,
    required this.totalBytes,
    required this.fileCount,
    required this.dirCount,
    required this.hostPath,
  });

  final ShellFileEntry entry;
  final int totalBytes;
  final int fileCount;
  final int dirCount;

  /// 宿主真实路径，便于在终端里 cd 过去。
  final String hostPath;

  factory ShellFileStat.fromMap(Map<dynamic, dynamic> map) {
    return ShellFileStat(
      entry: ShellFileEntry.fromMap(map),
      totalBytes: (map['totalBytes'] as num?)?.toInt() ?? 0,
      fileCount: (map['fileCount'] as num?)?.toInt() ?? 0,
      dirCount: (map['dirCount'] as num?)?.toInt() ?? 0,
      hostPath: map['hostPath']?.toString() ?? '',
    );
  }
}

/// 目录列表结果。
class ShellDirectoryListing {
  const ShellDirectoryListing({
    required this.path,
    required this.roots,
    required this.entries,
    this.rootLabels = const [],
  });

  final String path;
  final List<String> roots;
  final List<ShellFileEntry> entries;

  /// APP 目录树的根显示名（内部文件/缓存/外部文件）。guest 树为空。
  final List<String> rootLabels;

  factory ShellDirectoryListing.fromMap(Map<dynamic, dynamic> map) {
    return ShellDirectoryListing(
      path: map['path']?.toString() ?? '/workspace',
      roots: [
        for (final r in (map['roots'] as List? ?? const [])) r.toString(),
      ],
      rootLabels: [
        for (final r in (map['rootLabels'] as List? ?? const [])) r.toString(),
      ],
      entries: [
        for (final e in (map['entries'] as List? ?? const []))
          if (e is Map) ShellFileEntry.fromMap(e),
      ],
    );
  }
}

/// Runtime 安装进度。
class InstallProgress {
  const InstallProgress({
    required this.stage,
    required this.received,
    required this.total,
    required this.done,
    this.error,
  });

  final String stage;
  final int received;
  final int total;
  final bool done;
  final String? error;

  /// 未知总大小时返回 null（UI 应显示不确定进度条）。
  double? get fraction =>
      total <= 0 ? null : (received / total).clamp(0.0, 1.0);

  String get sizeText {
    if (total <= 0 && received <= 0) return '';
    String mb(int bytes) => (bytes / 1048576).toStringAsFixed(1);
    if (total <= 0) return '${mb(received)} MB';
    return '${mb(received)} / ${mb(total)} MB';
  }

  factory InstallProgress.fromMap(Map<dynamic, dynamic> map) {
    return InstallProgress(
      stage: map['stage']?.toString() ?? '',
      received: (map['received'] as num?)?.toInt() ?? 0,
      total: (map['total'] as num?)?.toInt() ?? 0,
      done: map['done'] == true,
      error: map['error']?.toString(),
    );
  }
}

class ProotBridge {
  static const MethodChannel _channel = MethodChannel('coomi/proot');
  static const EventChannel _events = EventChannel('coomi/terminal');
  static const EventChannel _installEvents = EventChannel('coomi/install');

  /// 安装进度流。原生侧会缓存最后一条事件，重新订阅可立刻拿到当前进度。
  Stream<InstallProgress> installProgress() {
    return _installEvents.receiveBroadcastStream().map((event) {
      if (event is Map) return InstallProgress.fromMap(event);
      return const InstallProgress(
        stage: '',
        received: 0,
        total: 0,
        done: false,
      );
    });
  }

  Future<PreruntimeStatus> status() async {
    final result = await _channel.invokeMethod<dynamic>('getStatus');
    if (result is Map) return PreruntimeStatus.fromMap(result);
    throw StateError('无法读取 PRoot 状态');
  }

  /// 安装 / 重装 Runtime。
  ///
  /// [clean] = true 时连缓存的下载包一起删掉重新下（约 150MB）；
  /// 默认只重新解压已下载的包，快得多，足够修复"装坏了"的情况。
  Future<Map<String, dynamic>> install({bool clean = false}) async {
    final result = await _channel.invokeMethod<dynamic>(
      'installRuntime',
      {'clean': clean},
    );
    if (result is Map) {
      return result.map((key, value) => MapEntry(key.toString(), value));
    }
    throw StateError('Runtime V2 安装返回异常');
  }

  Future<ExecResult> exec({
    required String command,
    List<String> args = const [],
    String? cwd,
    int timeoutSeconds = 60,
  }) async {
    // 双保险：原生侧自己会在 timeoutSeconds 到点时杀进程，但"原生侧线程
    // 本身卡住"（proot 收不到信号、机器 IO 挂了）时它就不会回话了。
    // Dart 这边再压一道更宽的超时，宁可返回一条错误，也不能让这个 await
    // 永远悬着——它悬着，终端锁就一直被占，后面所有命令跟着一起死。
    final ceiling = Duration(seconds: timeoutSeconds + 20);
    try {
      final result = await _channel.invokeMethod<dynamic>('exec', {
        'command': command,
        'args': args,
        'cwd': cwd,
        'timeoutSeconds': timeoutSeconds,
      }).timeout(ceiling);
      if (result is Map) return ExecResult.fromMap(result);
      throw StateError('PRoot exec 返回异常');
    } on TimeoutException {
      return ExecResult(
        exitCode: -1,
        stdout: '',
        stderr: '命令彻底卡死了：等了 ${ceiling.inSeconds}s 连"超时已杀掉"都没回。'
            '这条命令的进程可能还在后台，用 shell_exec '
            '"ps aux | head -30" 看一眼，必要时 kill 掉。'
            '下一条命令可以照常执行。',
      );
    }
  }

  /// 列目录。[path] 为 guest 路径（/workspace、/home/coomi、/opt/coomi-dev、/tmp）。
  Future<ShellDirectoryListing> listFiles({String path = '/workspace'}) async {
    final result = await _channel.invokeMethod<dynamic>('listFiles', {
      'path': path,
    });
    if (result is Map) return ShellDirectoryListing.fromMap(result);
    throw StateError('列目录返回异常');
  }

  /// 读文本文件（默认最多 1MB，超出请在终端处理）。
  ///
  /// [scope] = 'app' 表示 [path] 是 APP 沙箱里的宿主绝对路径。
  /// 必须显式带上：guest 的 /workspace 物理上就在 filesDir 下面，
  /// 两套树在磁盘上嵌套，光看路径字符串分不出是哪一套。
  Future<String> readFile({
    required String path,
    int maxBytes = 1048576,
    String scope = 'shell',
  }) async {
    final result = await _channel.invokeMethod<dynamic>('readFile', {
      'path': path,
      'maxBytes': maxBytes,
      'scope': scope,
    });
    if (result is Map) return result['content']?.toString() ?? '';
    throw StateError('读文件返回异常');
  }

  Future<ShellFileEntry> writeFile({
    required String path,
    required String content,
    String scope = 'shell',
  }) async {
    final result = await _channel.invokeMethod<dynamic>('writeFile', {
      'path': path,
      'content': content,
      'scope': scope,
    });
    if (result is Map) return ShellFileEntry.fromMap(result);
    throw StateError('写文件返回异常');
  }

  /// 追加文本到文件末尾。
  ///
  /// 专门给“AI 写超大文件”用的：内容不经过 shell 命令，直接走原生文件 IO，
  /// 不会出现 `Invalid argument(s): 命令过长`。配合 [writeFile] 首次覆盖 +
  /// 多次 [appendFile] 分块追加。
  Future<ShellFileEntry> appendFile({
    required String path,
    required String content,
    String scope = 'shell',
  }) async {
    final result = await _channel.invokeMethod<dynamic>('appendFile', {
      'path': path,
      'content': content,
      'scope': scope,
    });
    if (result is Map) return ShellFileEntry.fromMap(result);
    throw StateError('追加文件返回异常');
  }

  /// guest 路径 → 宿主真实路径。
  ///
  /// 图片查看器（Image.file）和系统 Intent 都只认宿主路径，
  /// /workspace/a.png 这种 guest 路径它们打不开。
  /// [scope] 传 'app' 表示传进来的本来就是宿主路径，只做越界校验。
  Future<String> hostPath(
      {required String path, String scope = 'shell'}) async {
    final result = await _channel.invokeMethod<dynamic>('hostPath', {
      'path': path,
      'scope': scope,
    });
    if (result is Map) return result['hostPath']?.toString() ?? '';
    throw StateError('取宿主路径返回异常');
  }

  /// 交给系统里能打开这个类型的 APP（看图、解压、读 PDF……）。
  ///
  /// 走 FileProvider 的 content:// URI，文件先复制到 cache/share 中转，
  /// 所以外部 APP 只看得到这一个文件，看不到沙箱其它内容。
  Future<bool> openExternal({
    required String path,
    required String mime,
    String scope = 'shell',
    bool share = false,
  }) async {
    final result = await _channel.invokeMethod<dynamic>('openExternal', {
      'path': path,
      'mime': mime,
      'scope': scope,
      'share': share,
    });
    return result == true;
  }

  Future<bool> deletePath(String path, {String scope = 'shell'}) async {
    final result = await _channel.invokeMethod<dynamic>('deletePath', {
      'path': path,
      'scope': scope,
    });
    return result == true;
  }

  Future<ShellFileEntry> makeDirectory(
    String path, {
    String scope = 'shell',
  }) async {
    final result = await _channel.invokeMethod<dynamic>('makeDirectory', {
      'scope': scope,
      'path': path,
    });
    if (result is Map) return ShellFileEntry.fromMap(result);
    throw StateError('创建目录返回异常');
  }

  Future<ShellFileEntry> movePath({
    required String from,
    required String to,
    String scope = 'shell',
  }) async {
    final result = await _channel.invokeMethod<dynamic>('movePath', {
      'from': from,
      'to': to,
      'scope': scope,
    });
    if (result is Map) return ShellFileEntry.fromMap(result);
    throw StateError('移动返回异常');
  }

  /// 复制文件或目录（目标已存在会报错，不静默覆盖）。
  Future<ShellFileEntry> copyPath({
    required String from,
    required String to,
    String scope = 'shell',
  }) async {
    final result = await _channel.invokeMethod<dynamic>('copyPath', {
      'from': from,
      'to': to,
      'scope': scope,
    });
    if (result is Map) return ShellFileEntry.fromMap(result);
    throw StateError('复制返回异常');
  }

  /// 设置权限位。只传要改的项，null = 保持不变。
  Future<ShellFileEntry> setPermissions({
    required String path,
    bool? readable,
    bool? writable,
    bool? executable,
    String scope = 'shell',
  }) async {
    final result = await _channel.invokeMethod<dynamic>('setPermissions', {
      'path': path,
      'scope': scope,
      if (readable != null) 'readable': readable,
      if (writable != null) 'writable': writable,
      if (executable != null) 'executable': executable,
    });
    if (result is Map) return ShellFileEntry.fromMap(result);
    throw StateError('设置权限返回异常');
  }

  Future<ShellFileStat> stat(String path, {String scope = 'shell'}) async {
    final result = await _channel.invokeMethod<dynamic>('statPath', {
      'path': path,
      'scope': scope,
    });
    if (result is Map) return ShellFileStat.fromMap(result);
    throw StateError('读取属性返回异常');
  }

  /// 递归搜索。[matchContent] 为真时同时搜文本内容（仅 <=512KB 的文件）。
  Future<List<ShellFileEntry>> search({
    required String path,
    required String keyword,
    bool matchContent = false,
    int limit = 200,
    String scope = 'shell',
  }) async {
    final result = await _channel.invokeMethod<dynamic>('searchFiles', {
      'path': path,
      'scope': scope,
      'keyword': keyword,
      'matchContent': matchContent,
      'limit': limit,
    });
    if (result is Map) return ShellDirectoryListing.fromMap(result).entries;
    throw StateError('搜索返回异常');
  }

  /// 列 APP 自身沙箱目录（与 guest 挂载点是两套根）。
  Future<ShellDirectoryListing> listAppFiles({String? path}) async {
    final result = await _channel.invokeMethod<dynamic>('listAppFiles', {
      'path': path,
    });
    if (result is Map) return ShellDirectoryListing.fromMap(result);
    throw StateError('列 APP 目录返回异常');
  }

  /// 从别的 APP 导入文件（系统文件选择器 / SAF）。
  ///
  /// 为什么必须走系统选择器：Android 10 起应用读不到别的 APP 的私有目录，
  /// /sdcard 的读权限也只覆盖媒体文件。选择器是唯一"不申请存储权限、
  /// 又能让用户从下载/网盘/微信任意来源交出文件"的通道，
  /// 而且授权只限用户亲手点的那几个文件。
  ///
  /// [path] 是落地目录（[scope] = 'shell' 时为 guest 路径，'app' 时为宿主路径）。
  /// 用户按返回键取消时返回 [ShellImportResult.canceled]，不是错误。
  Future<ShellImportResult> importFiles({
    required String path,
    String scope = 'shell',
  }) async {
    final result = await _channel.invokeMethod<dynamic>('importFiles', {
      'path': path,
      'scope': scope,
    });
    if (result is Map) return ShellImportResult.fromMap(result);
    throw StateError('导入文件返回异常');
  }

  Future<bool> spawnTerminal() async {
    final result = await _channel.invokeMethod<dynamic>('spawnTerminal');
    return result == true;
  }

  Future<bool> writeTerminal(String data) async {
    final result = await _channel.invokeMethod<dynamic>('writeTerminal', {
      'data': data,
    });
    return result == true;
  }

  Future<bool> stopTerminal() async {
    final result = await _channel.invokeMethod<dynamic>('stopTerminal');
    return result == true;
  }

  /// 把终端控件的行列数同步给 pty。
  ///
  /// 必须做：pty 的 winsize 默认是 0x0，guest 里的 bash 会以为终端零宽——
  /// ls 不分列、top/less 画不出界面、长命令换行位置也是错的。
  /// 控件尺寸一变就调一次。
  Future<bool> resizeTerminal(int cols, int rows) async {
    if (cols <= 0 || rows <= 0) return false;
    try {
      final result = await _channel.invokeMethod<dynamic>('resizeTerminal', {
        'cols': cols,
        'rows': rows,
      });
      return result == true;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  Stream<Map<String, dynamic>> terminalEvents() {
    return _events.receiveBroadcastStream().map((event) {
      if (event is Map) {
        return event.map((key, value) => MapEntry(key.toString(), value));
      }
      return {'type': 'output', 'data': event?.toString() ?? ''};
    });
  }
}
