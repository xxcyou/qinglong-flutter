import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../utils/logger.dart';

/// 缓存专用目录的自动保洁。
///
/// 规则：
/// - 超过 30 天的缓存文件直接删；
/// - 总大小超过 [maxBytes]（默认 200MB）时，按“最旧优先”继续删到
///   [softTargetBytes]（默认 140MB）以下，智能腾地方；
/// - 只删缓存目录里的文件，不碰 workspace、用户文件、设置等长期数据。
class CacheCleaner {
  CacheCleaner._();

  /// 缓存最大保留时长。
  static const maxAge = Duration(days: 30);

  /// 缓存总量硬上限；超过后触发“旧数据优先”清理。
  static const maxBytes = 200 * 1024 * 1024;

  /// 清到多少以下才算完事，留点余量避免每次启动都清。
  static const softTargetBytes = 140 * 1024 * 1024;

  /// 启动时调用一次。结果只写日志，绝不阻塞首帧（调用方负责 unawaited）。
  static Future<void> run() async {
    try {
      final root = await getApplicationCacheDirectory();
      final stat = await _clean(root);
      if (stat.deletedFiles > 0 || stat.deletedBytes > 0) {
        Logger.d(
          'cache',
          '启动缓存清理完成：删除 ${stat.deletedFiles} 个文件，'
              '释放 ${_fmt(stat.deletedBytes)}，当前缓存 ${_fmt(stat.remainingBytes)}',
        );
      }
    } catch (e) {
      // 清理失败不能影响 App 启动，记录一下就好。
      Logger.e('cache', '启动缓存清理失败', e);
    }
  }

  static Future<_CleanStat> _clean(Directory root) async {
    final files = await _collectFiles(root);
    final now = DateTime.now();
    final cutoff = now.subtract(maxAge);
    final deletable = <File>[];

    var totalBytes = 0;
    for (final f in files) {
      try {
        final st = f.statSync();
        totalBytes += st.size;
        if (st.modified.isBefore(cutoff)) deletable.add(f);
      } catch (_) {
        // 文件可能在收集过程中被删了，跳过。
      }
    }

    var deletedBytes = 0;
    var deletedFiles = 0;

    Future<bool> deleteOne(File f, int size) async {
      try {
        await f.delete();
        deletedBytes += size;
        deletedFiles++;
        return true;
      } catch (_) {
        // 删不掉就留着，可能是占用中。
        return false;
      }
    }

    // 第一波：按时间清掉超过一个月的。
    for (final f in deletable) {
      try {
        final size = f.lengthSync();
        if (await deleteOne(f, size)) totalBytes -= size;
      } catch (_) {}
    }

    // 第二波：如果还超上限，最旧的优先删到软目标以下。
    if (totalBytes > maxBytes) {
      final remaining = <File>[];
      for (final f in files) {
        try {
          if (f.existsSync()) remaining.add(f);
        } catch (_) {}
      }
      remaining.sort((a, b) {
        final ma = a.statSync().modified.millisecondsSinceEpoch;
        final mb = b.statSync().modified.millisecondsSinceEpoch;
        return ma.compareTo(mb);
      });
      for (final f in remaining) {
        if (totalBytes <= softTargetBytes) break;
        try {
          final size = f.lengthSync();
          if (await deleteOne(f, size)) totalBytes -= size;
        } catch (_) {}
      }
    }

    // 顺手把空目录收掉，别留一堆空壳。
    await _removeEmptyDirs(root);

    var remaining = 0;
    try {
      remaining = await _dirSize(root);
    } catch (_) {}

    return _CleanStat(deletedFiles, deletedBytes, remaining);
  }

  static Future<List<File>> _collectFiles(Directory dir) async {
    final out = <File>[];
    try {
      await for (final entity
          in dir.list(recursive: true, followLinks: false)) {
        if (entity is File) out.add(entity);
      }
    } catch (_) {
      // 个别子目录读取失败不影响整体清理。
    }
    return out;
  }

  static Future<void> _removeEmptyDirs(Directory root) async {
    try {
      final dirs = <Directory>[];
      await for (final entity
          in root.list(recursive: true, followLinks: false)) {
        if (entity is Directory) dirs.add(entity);
      }
      dirs.sort((a, b) => b.path.length.compareTo(a.path.length));
      for (final d in dirs) {
        try {
          if (d.existsSync() && d.listSync().isEmpty) d.deleteSync();
        } catch (_) {}
      }
    } catch (_) {}
  }

  static Future<int> _dirSize(Directory dir) async {
    var total = 0;
    try {
      await for (final entity
          in dir.list(recursive: true, followLinks: false)) {
        if (entity is File) {
          try {
            total += entity.lengthSync();
          } catch (_) {}
        }
      }
    } catch (_) {}
    return total;
  }

  static String _fmt(int bytes) {
    if (bytes >= 1024 * 1024)
      return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
    if (bytes >= 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    return '$bytes B';
  }
}

class _CleanStat {
  const _CleanStat(this.deletedFiles, this.deletedBytes, this.remainingBytes);

  final int deletedFiles;
  final int deletedBytes;
  final int remainingBytes;
}
