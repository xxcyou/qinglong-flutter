import '../../../core/local_shell/proot_bridge.dart';
import '../../../core/local_shell/shell_lock.dart';
import '../ai/agent/external_tool.dart';

class LinuxContainerTools {
  static List<ExternalTool> build() => [
        ExternalTool(
          name: 'linux_container',
          description: '管理本机 Linux 容器（PRoot 里的虚拟环境）。'
              'action=list 列出所有已安装容器，current 看当前容器，'
              'clone 把当前容器复制一份新的，switch 切换到指定容器（会停掉所有终端），'
              'delete 删除非当前容器，install 首次下载/重装内置 Debian 容器。'
              '每个容器是独立的根文件系统，适合装不同软件栈、不同编译环境切换使用。',
          parameters: const {
            'type': 'object',
            'properties': {
              'action': {
                'type': 'string',
                'enum': [
                  'list', 'current', 'clone', 'switch', 'delete', 'install'
                ],
                'description': '默认 list',
              },
              'id': {
                'type': 'string',
                'description': '容器 id；switch/delete 时必填',
              },
              'name': {
                'type': 'string',
                'description': 'clone 时的新容器名称提示（可空）',
              },
            },
            'required': [],
          },
          origin: '本机 Linux 容器',
          isWrite: true,
          invoke: (args) async {
            final action = args['action']?.toString() ?? 'list';
            final bridge = ProotBridge();
            if (action == 'install') {
              return await ShellLock.run(
                ShellLock.terminal,
                () async {
                  await bridge.install();
                  final status = await bridge.status();
                  return status.installed
                      ? 'Debian 容器安装/重装完成。'
                      : '安装未完成：请检查安装进度或错误。';
                },
                label: 'linux_container:install',
                timeout: const Duration(minutes: 15),
              );
            }
            final list = await bridge.containerList();
            if (list.isEmpty) {
              return '还没有任何 Linux 容器。用 linux_container install 先装一个。';
            }
            final activeId = (await bridge.status()).version;
            if (action == 'list' || action == 'current') {
              final sb = StringBuffer();
              if (action == 'current') sb.writeln('当前 Linux 容器：$activeId');
              else sb.writeln('已安装 Linux 容器（${list.length}）：');
              for (final c in list) {
                final id = c['id']?.toString() ?? '';
                final mark = id == activeId ? '▶ ' : '';
                final active = id == activeId ? '（当前）' : '';
                sb.writeln('$mark$id$active');
              }
              return sb.toString();
            }
            if (action == 'clone') {
              final r = await bridge.containerClone(name: args['name']?.toString());
              final id = r['id']?.toString() ?? r['name']?.toString() ?? 'new';
              return '已克隆新容器：$id\n'
                  '用 linux_container switch id=$id 切换过去。';
            }
            final id = args['id']?.toString() ?? '';
            if (id.isEmpty) return 'switch/delete 需要容器 id。';
            if (!list.any((c) => c['id']?.toString() == id)) {
              return '找不到容器「$id」。先 linux_container list 看 id。';
            }
            if (action == 'switch') {
              return await ShellLock.run(
                ShellLock.terminal,
                () async {
                  await bridge.containerSwitch(id);
                  return '已切换到容器「$id」。所有终端已重启。';
                },
                label: 'linux_container:switch $id',
                timeout: const Duration(minutes: 3),
              );
            }
            if (action == 'delete') {
              if (id == activeId) return '不能删除当前正在使用的容器。';
              await bridge.containerDelete(id);
              return '已删除容器「$id」。';
            }
            return '未知 action：$action';
          },
        ),
      ];
}
