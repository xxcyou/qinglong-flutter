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
        .where((l) => l.isNotEmpty && !l.contains('Cannot connect') && !l.startsWith('docker:'))
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

  static String _shq(String s) => "'${s.replaceAll("'", "'\\''")}'";
}
