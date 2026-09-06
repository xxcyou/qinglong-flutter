import 'package:dio/dio.dart';

import '../../../core/network/api_exception.dart';
import '../../../core/network/dio_client.dart';
import '../../../core/network/error_handler.dart';
import '../models/script_node.dart';

/// 脚本管理 API。
///
/// 对齐当前 QingLong 后端：
/// - 列表：GET /api/scripts
/// - 读取：GET /api/scripts/detail?path=&file=
/// - 新建/保存：POST/PUT /api/scripts，body 使用 filename + path + content
class ScriptApi {
  ScriptApi._();

  /// 把 "dir/name.js" 拆成 (目录, 文件名)。
  static (String dir, String name) _split(String file) {
    final index = file.lastIndexOf('/');
    if (index < 0) return ('', file);
    return (file.substring(0, index), file.substring(index + 1));
  }

  static Future<List<ScriptNode>> files({
    required String apiBaseUrl,
    String? searchValue,
  }) async {
    final response = await DioClient.dio.get<dynamic>(
      '$apiBaseUrl/scripts',
      queryParameters: {
        // 新版后端返回完整目录树，搜索在本地完成；searchValue 保留兼容旧版。
        if (searchValue != null && searchValue.isNotEmpty)
          'searchValue': searchValue,
      },
    );
    final data = parseQlResponse(response);
    if (data is List) {
      return data
          .whereType<Map<String, dynamic>>()
          .map(ScriptNode.fromJson)
          .toList();
    }
    return const [];
  }

  static Future<String> read({
    required String apiBaseUrl,
    required String file,
  }) async {
    try {
      final (dir, name) = _split(file);
      final response = await DioClient.dio.get<dynamic>(
        '$apiBaseUrl/scripts/$name',
        queryParameters: {
          // v2.15 的 /scripts/:file 要求 path 始终存在（空串也可），缺失会 500。
          'path': dir,
        },
      );
      final data = parseQlResponse(response);
      if (data is String) return data;
      if (data is Map<String, dynamic>) {
        final content = data['content'] ?? data['data'];
        if (content is String) return content;
      }
      return data?.toString() ?? '';
    } on DioException catch (e) {
      throw ApiException(message: readableError(e));
    }
  }

  /// 保证 `dir` 这一串目录在面板上存在。
  ///
  /// 为什么必须有它：面板写文件用的是 `fs.writeFile`，**不会**自动建父目录。
  /// 写 `sub/a.js` 时如果 `sub` 不存在，面板直接抛
  /// `ENOENT: no such file or directory, open '/ql/data/scripts/sub/a.js'`
  /// 并原样回 HTTP 500——看起来像"API 不支持子目录"，其实只是目录没建。
  ///
  /// 建目录接口是幂等的（已存在也回 200），逐级建，所以 `a/b/c` 也能一次成。
  static Future<void> ensureDirectory({
    required String apiBaseUrl,
    required String dir,
  }) async {
    final parts = dir.split('/').where((p) => p.trim().isNotEmpty).toList();
    if (parts.isEmpty) return;
    final walked = <String>[];
    for (final part in parts) {
      await createDirectory(
        apiBaseUrl: apiBaseUrl,
        path: walked.join('/'),
        directory: part,
      );
      walked.add(part);
    }
  }

  static Future<void> create({
    required String apiBaseUrl,
    required String path,
    required String content,
  }) async {
    final (dir, name) = _split(path);
    await ensureDirectory(apiBaseUrl: apiBaseUrl, dir: dir);
    final response = await DioClient.dio.post<dynamic>(
      '$apiBaseUrl/scripts',
      data: {
        // v2.15 的 path 参数即使为空也必须显式传空串，缺失会 500。
        'path': dir,
        'filename': name,
        'content': content,
      },
    );
    parseQlResponse(response);
  }

  static Future<void> save({
    required String apiBaseUrl,
    required String path,
    required String content,
  }) async {
    final (dir, name) = _split(path);
    // 保存也要建目录：PUT 对新文件同样是 writeFile，缺目录一样 500。
    await ensureDirectory(apiBaseUrl: apiBaseUrl, dir: dir);
    final response = await DioClient.dio.put<dynamic>(
      '$apiBaseUrl/scripts',
      data: {
        // v2.15 的 path 参数即使为空也必须显式传空串，缺失会 500。
        'path': dir,
        'filename': name,
        'content': content,
      },
    );
    parseQlResponse(response);
  }

  static Future<void> rename({
    required String apiBaseUrl,
    required String path,
    required String newFilename,
  }) async {
    final (dir, name) = _split(path);
    final response = await DioClient.dio.put<dynamic>(
      '$apiBaseUrl/scripts/rename',
      data: {
        'path': dir,
        'filename': name,
        'newFilename': newFilename,
      },
    );
    parseQlResponse(response);
  }

  static Future<void> createDirectory({
    required String apiBaseUrl,
    required String path,
    required String directory,
  }) async {
    final response = await DioClient.dio.post<dynamic>(
      '$apiBaseUrl/scripts',
      data: {
        'path': path,
        'directory': directory,
      },
    );
    parseQlResponse(response);
  }

  static Future<void> delete({
    required String apiBaseUrl,
    required String path,
    bool isDirectory = false,
  }) async {
    final (dir, name) = _split(path);
    final response = await DioClient.dio.delete<dynamic>(
      '$apiBaseUrl/scripts',
      data: {
        'path': dir,
        'filename': name,
        'type': isDirectory ? 'directory' : 'file',
      },
    );
    parseQlResponse(response);
  }

  /// 手动运行脚本。返回面板给的 pid（用于停止）。
  ///
  /// 关键：面板 `/scripts/run` 会把请求里的 `content` 写进一个
  /// `<name>.swap<ext>` 临时文件并执行**那个文件**，而不是执行仓库里的原文件。
  /// 所以 content 必须显式传；不传就等于跑了个空文件——表现就是
  /// 「开始执行 / 执行结束 耗时 1 秒」但一行输出都没有。
  static Future<Object?> run({
    required String apiBaseUrl,
    required String path,
    required String content,
  }) async {
    final (dir, name) = _split(path);
    final response = await DioClient.dio.put<dynamic>(
      '$apiBaseUrl/scripts/run',
      data: {
        'path': dir,
        'filename': name,
        'content': content,
      },
    );
    return parseQlResponse(response);
  }

  static Future<void> stop({
    required String apiBaseUrl,
    required String path,
    int? pid,
  }) async {
    final (dir, name) = _split(path);
    final response = await DioClient.dio.put<dynamic>(
      '$apiBaseUrl/scripts/stop',
      data: {
        'path': dir,
        'filename': name,
        // 有 pid 时精确杀；没有则由面板按命令行反查。
        if (pid != null) 'pid': pid,
      },
    );
    parseQlResponse(response);
  }
}
