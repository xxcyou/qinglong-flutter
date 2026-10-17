import 'dart:convert';
import 'dart:typed_data';

import '../providers/ssh_session_provider.dart';

class DockerContainer {
  const DockerContainer({
    required this.id,
    required this.name,
    required this.image,
    required this.status,
    required this.state,
    required this.ports,
    required this.createdAt,
  });

  final String id;
  final String name;
  final String image;
  final String status;
  final String state;
  final String ports;
  final String createdAt;

  bool get running => state == 'running';
}

/// 通过已连接的 SSH 会话调用远端 docker CLI。
class DockerService {
  const DockerService(this.sessionId);

  final String sessionId;

  Future<List<DockerContainer>> list() async {
    final raw = await SshSessionManager.instance.executeFull(
      sessionId,
      r"docker ps -a --no-trunc --format '{{.ID}}\t{{.Names}}\t{{.Image}}\t{{.Status}}\t{{.State}}\t{{.Ports}}\t{{.CreatedAt}}' 2>&1",
    );
    final lines = raw
        .split('\n')
        .map((l) => l.trim())
        .where((l) =>
            l.isNotEmpty &&
            !l.contains('Cannot connect') &&
            !l.startsWith('docker:'))
        .toList();
    final containers = <DockerContainer>[];
    for (final line in lines) {
      final parts = line.split('\t');
      if (parts.length < 7) continue;
      containers.add(DockerContainer(
        id: parts[0].trim(),
        name: parts[1].trim().split(',')[0],
        image: parts[2].trim(),
        status: parts[3].trim(),
        state: parts[4].trim(),
        ports: parts[5].trim(),
        createdAt: parts[6].trim(),
      ));
    }
    // 有输出但没有合法行，把原始文本作为 error 抛出去。
    if (containers.isEmpty && raw.trim().isNotEmpty) {
      throw StateError(raw.trim());
    }
    return containers;
  }

  Future<String> run(String id, String action, {String? name}) async {
    final command = switch (action) {
      'start' => 'docker start $id',
      'stop' => 'docker stop $id',
      'restart' => 'docker restart $id',
      'pause' => 'docker pause $id',
      'unpause' => 'docker unpause $id',
      'kill' => 'docker kill $id',
      'remove' => 'docker rm -f $id',
      'rename' => 'docker rename $id ${_shq(name ?? '')}',
      _ => throw ArgumentError('unknown docker action: $action'),
    };
    return SshSessionManager.instance
        .executeFull(sessionId, command)
        .then((r) => r.trim().isEmpty ? 'ok' : r);
  }

  /// 读取上限：超过后直接拒绝，避免大文件把手机内存打爆（用户反馈闪退）。
  ///
  /// 复制/粘贴也走这里，所以给得比“内置打开”宽一点；打开文本/图片时
  /// 会再按类型收窄。
  static const int maxReadBytes = 32 * 1024 * 1024;

  /// 读取容器内文件原始字节。
  ///
  /// 会检查 stderr/exit code，并把二进制错误写进异常，UI 才能显示
  /// “为什么打不开”（权限不足/路径不存在/文件过大），而不是一个空字符串。
  Future<Uint8List> readFileBytes(
    String containerId,
    String path, {
    int maxBytes = maxReadBytes,
  }) async {
    final client = SshSessionManager.instance.clientOf(sessionId);
    if (client == null) throw StateError('SSH 未连接：$sessionId');
    final session = await client.execute(
      'docker exec $containerId cat ${_shq(path)}',
    );
    final builder = BytesBuilder(copy: false);
    final errorText = StringBuffer();
    final stderrDone = session.stderr.listen((chunk) {
      if (errorText.length < 4096) {
        errorText.write(utf8.decode(chunk, allowMalformed: true));
      }
    }).asFuture<void>();
    var exceeded = false;
    await for (final chunk in session.stdout) {
      if (builder.length + chunk.length > maxBytes) {
        exceeded = true;
        session.close();
        break;
      }
      builder.add(chunk);
    }
    await session.done;
    await stderrDone;
    if (exceeded) {
      final limit = maxBytes >= 1024 * 1024
          ? '${(maxBytes / (1024 * 1024)).toStringAsFixed(0)}MB'
          : '${(maxBytes / 1024).toStringAsFixed(0)}KB';
      throw StateError('文件超过 $limit，为避免闪退已阻止直接读取');
    }
    final err = errorText.toString().trim();
    final code = session.exitCode;
    if (code != null && code != 0) {
      throw StateError(err.isEmpty ? '读取失败（exit=$code）' : err);
    }
    return builder.takeBytes();
  }

  /// 把原始字节写入容器内文件（不存在自动创建/存在则覆盖）。
  Future<void> writeFileBytes(
      String containerId, String path, Uint8List bytes) async {
    final client = SshSessionManager.instance.clientOf(sessionId);
    if (client == null) throw StateError('SSH 未连接：$sessionId');
    final session = await client.execute(
      "docker exec -i $containerId sh -c 'cat > \"\$1\"' sh ${_shq(path)}",
    );
    session.write(bytes);
    session.close();
    await session.done;
  }

  /// 删除容器内文件。
  Future<String> deleteFile(String containerId, String path) async {
    return SshSessionManager.instance.executeFull(
      sessionId,
      "docker exec $containerId sh -c 'rm -f -- \"\$1\"' sh ${_shq(path)}",
    );
  }

  static String _shq(String s) => "'${s.replaceAll("'", "'\\''")}'";
}
