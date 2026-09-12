import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../utils/logger.dart';

/// 缓存专用目录的自动保洁。
///
/// 规则：
/// - 超过 `cacheMaxAgeDays`（默认 30）天的缓存文件直接删；
/// - 总大小超过 `cacheMaxSizeMB`（默认 200MB）时，按“最旧优先”继续删到
///   其 70% 以下，智能腾地方；
/// - 只删缓存目录里的文件，不碰 workspace、用户文件、设置等长期数据。
class CacheCleaner {
  CacheCleaner._();

  static const _prefsEnabled = 'cacheCleanupEnabled';
  static const _prefsMaxAgeDays = 'cacheMaxAgeDays';
  static const _prefsMaxSizeMB = 'cacheMaxSizeMB';

  /// 启动时调用一次。结果只写日志，绝不阻塞首帧（调用方负责 unawaited）。
  static Future<void> run() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final enabled = prefs.getBool(_prefsEnabled) ?? true;
      if (!enabled) return;
      final maxAgeDays = prefs.getInt(_prefsMaxAgeDays) ?? 30;
      final maxSizeMB = prefs.getInt(_prefsMaxSizeMB) ?? 200;
      final root = await getApplicationCacheDirectory();
      final stat = await _clean(
        root,
        maxAgeDays: maxAgeDays,
        maxSizeMB: maxSizeMB,
      );
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

  /// 设置页手动“立即清理”：清空整个缓存目录，返回释放了多少字节。
  static Future<int> clearAll() async {
    final root = await getApplicationCacheDirectory();
    var freed = 0;
    try {
      await for (final entity in root.list(recursive: true, followLinks: false)) {
        try {
          if (entity is File) {
            freed += entity.lengthSync();
            await entity.delete();
          }
        } catch (_) {}
      }
      // 清完文件再收目录。
      final dirs = <Directory>[];
      await for (final entity in root.list(recursive: true, followLinks: false)) {
        if (entity is Directory) dirs.add(entity);
      }
      dirs.sort((a, b) => b.path.length.compareTo(a.path.length));
      for (final d in dirs) {
        try {
          if (d.existsSync() && d.listSync().isEmpty) d.deleteSync();
        } catch (_) {}
      }
    } catch (_) {}
    return freed;
  }

  /// 当前缓存目录总大小（字节）。
  static Future<int> size() async {
    final root = await getApplicationCacheDirectory();
    return _dirSize(root);
  }

  /// 按设置规则清理。
  static Future<_CleanStat> _clean(
    Directory root, {
    required int maxAgeDays,
    required int maxSizeMB,
  }) async {
    final files = await _collectFiles(root);
    final now = DateTime.now();
    final cutoff = now.subtract(Duration(days: maxAgeDays));
    final maxBytes = maxSizeMB * 1024 * 1024;
    final softTargetBytes = (maxBytes * 0.7).round();
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

    // 第一波：按时间清掉超过保留时长的。
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

    return _CleanStat(
      deletedFiles,
      deletedBytes,
      await _dirSize(root),
    );
  }

  static Future<List<File>> _collectFiles(Directory dir) async {
    final out = <File>[];
    try {
      await for (final entity in dir.list(recursive: true, followLinks: false)) {
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
      await for (final entity in dir.list(recursive: true, followLinks: false)) {
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
    if (bytes >= 1024 * 1024) {
      return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
    }
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
