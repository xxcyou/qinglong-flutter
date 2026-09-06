import 'dart:convert';

import '../../panels/models/panel_info.dart';
import '../../configs/api/config_api.dart';
import '../../crons/api/cron_api.dart';
import '../../crons/models/cron_task.dart';
import '../../dependencies/api/dependency_api.dart';
import '../../envs/api/env_api.dart';
import '../../envs/models/env_var.dart';
import '../../logs/api/log_api.dart';
import '../../scripts/api/script_api.dart';
import '../../subscriptions/api/subscription_api.dart';
import '../../subscriptions/models/subscription.dart';
import '../../system/api/system_api.dart';
import '../../../core/local_shell/proot_bridge.dart';
import '../../../core/local_shell/sandbox.dart';
import '../../../core/local_shell/shell_lock.dart';
import '../models/approval_mode.dart';

class ToolDefinition {
  ToolDefinition({
    required this.name,
    required this.description,
    this.parameters = const {},
    required this.isWrite,
    this.impact = '',
    this.reversible = true,
    this.danger = false,
  });

  final String name;
  final String description;
  final Map<String, dynamic> parameters;
  final bool isWrite;

  /// 写操作的影响说明，直接展示在确认卡片上。
  final String impact;

  /// 是否可逆（不可逆的会在确认卡片上高亮）。
  final bool reversible;

  /// 危险操作：删除、覆盖既有内容、触发真实业务副作用、执行任意命令。
  /// "仅危险"策略只拦这一类。
  final bool danger;

  /// 按当前确认策略判断这次调用是否需要用户点确认。
  bool needsConfirm(AiApprovalMode mode) {
    if (!isWrite) return false;
    return switch (mode) {
      AiApprovalMode.strict => true,
      AiApprovalMode.cautious => danger,
      AiApprovalMode.full => false,
    };
  }
}

class ConfirmRequiredException implements Exception {
  const ConfirmRequiredException();

  @override
  String toString() => '该操作需要用户确认后才能执行';
}

class QlToolRegistry {
  QlToolRegistry({required PanelInfo? Function() panelGetter})
      : _panelGetter = panelGetter;

  final PanelInfo? Function() _panelGetter;

  static const _stringProp = {
    'type': 'string',
  };
  static const _intProp = {
    'type': 'integer',
  };
  static Map<String, dynamic> _obj(
      List<String> required, Map<String, dynamic> properties) {
    return {'type': 'object', 'properties': properties, 'required': required};
  }

  /// 按名字查工具，找不到返回 null。
  ToolDefinition? find(String name) {
    for (final d in definitions) {
      if (d.name == name) return d;
    }
    return null;
  }

  List<ToolDefinition> get definitions => [
        ToolDefinition(
          name: 'cron_list',
          description: '列出定时任务，可搜索',
          parameters: _obj(['searchValue'], {'searchValue': _stringProp}),
          isWrite: false,
        ),
        ToolDefinition(
          name: 'cron_log',
          description: '读取某个定时任务最近一次执行的日志（自动定位该任务的最新日志文件）',
          parameters: _obj(['id'], {'id': _intProp}),
          isWrite: false,
        ),
        ToolDefinition(
          name: 'cron_create',
          description: '创建定时任务',
          parameters: _obj([
            'name',
            'command',
            'schedule'
          ], {
            'name': _stringProp,
            'command': _stringProp,
            'schedule': _stringProp,
            'labels': {'type': 'array', 'items': _stringProp},
          }),
          isWrite: true,
          impact: '在面板新增一个定时任务，会按 cron 表达式自动执行',
          reversible: true,
        ),
        ToolDefinition(
          name: 'cron_update',
          description: '更新定时任务',
          parameters: _obj([
            'id',
            'name',
            'command',
            'schedule'
          ], {
            'id': _intProp,
            'name': _stringProp,
            'command': _stringProp,
            'schedule': _stringProp,
            'labels': {'type': 'array', 'items': _stringProp},
          }),
          isWrite: true,
          impact: '覆盖现有任务的名称/命令/调度，旧内容不保留',
          reversible: false,
          danger: true,
        ),
        ToolDefinition(
          name: 'cron_delete',
          description: '删除定时任务',
          parameters: _obj([
            'ids'
          ], {
            'ids': {'type': 'array', 'items': _intProp}
          }),
          isWrite: true,
          impact: '永久删除任务及其历史配置',
          reversible: false,
          danger: true,
        ),
        ToolDefinition(
          name: 'cron_run',
          description: '运行定时任务',
          parameters: _obj([
            'ids'
          ], {
            'ids': {'type': 'array', 'items': _intProp}
          }),
          isWrite: true,
          impact: '立即执行任务，可能产生真实业务副作用（下单、签到、发消息等）',
          reversible: false,
          danger: true,
        ),
        ToolDefinition(
          name: 'cron_stop',
          description: '停止定时任务',
          parameters: _obj([
            'ids'
          ], {
            'ids': {'type': 'array', 'items': _intProp}
          }),
          isWrite: true,
          impact: '中断正在运行的任务，可能留下半成品状态',
          reversible: true,
        ),
        ToolDefinition(
          name: 'cron_enable',
          description: '启用定时任务',
          parameters: _obj([
            'ids'
          ], {
            'ids': {'type': 'array', 'items': _intProp}
          }),
          isWrite: true,
          impact: '恢复任务按计划自动运行',
          reversible: true,
        ),
        ToolDefinition(
          name: 'cron_disable',
          description: '禁用定时任务',
          parameters: _obj([
            'ids'
          ], {
            'ids': {'type': 'array', 'items': _intProp}
          }),
          isWrite: true,
          impact: '停止任务按计划自动运行',
          reversible: true,
        ),
        // ------------------------------------------------------------ 订阅
        // 装脚本这件事在青龙里几乎都是靠订阅（ql repo / ql raw）完成的。
        // 没有这组工具，AI 只能教用户"去网页版加订阅"，装脚本这条链就断在这里。
        ToolDefinition(
          name: 'sub_list',
          description: '列出订阅（拉取仓库/脚本的配置），可搜索',
          parameters: _obj([], {'searchValue': _stringProp}),
          isWrite: false,
        ),
        ToolDefinition(
          name: 'sub_log',
          description: '读取某条订阅最近一次拉取的日志（排查拉不下来的原因）',
          parameters: _obj(['id'], {'id': _intProp}),
          isWrite: false,
        ),
        ToolDefinition(
          name: 'sub_create',
          description: '新建订阅。type: public-repo（公开仓库）/ private-repo（私有仓库）'
              '/ file（单文件直链）。alias 留空会按 URL 自动生成',
          parameters: _obj([
            'type',
            'url',
          ], {
            'type': _stringProp,
            'url': _stringProp,
            'alias': _stringProp,
            'name': _stringProp,
            'schedule': _stringProp,
            'branch': _stringProp,
            'whitelist': _stringProp,
            'blacklist': _stringProp,
            'dependences': _stringProp,
            'extensions': _stringProp,
            'proxy': _stringProp,
            'autoAddCron': {'type': 'boolean'},
            'autoDelCron': {'type': 'boolean'},
          }),
          isWrite: true,
          impact: '新增一条订阅，之后会按 cron 自动拉取仓库脚本，并可能自动创建定时任务',
          reversible: true,
        ),
        ToolDefinition(
          name: 'sub_update',
          description: '修改订阅。只需给要改的字段，其余沿用面板上的现值',
          parameters: _obj([
            'id',
          ], {
            'id': _intProp,
            'type': _stringProp,
            'url': _stringProp,
            'alias': _stringProp,
            'name': _stringProp,
            'schedule': _stringProp,
            'branch': _stringProp,
            'whitelist': _stringProp,
            'blacklist': _stringProp,
            'dependences': _stringProp,
            'extensions': _stringProp,
            'proxy': _stringProp,
            'autoAddCron': {'type': 'boolean'},
            'autoDelCron': {'type': 'boolean'},
          }),
          isWrite: true,
          impact: '覆盖订阅配置（地址/白名单/定时等），旧内容不保留',
          reversible: false,
          danger: true,
        ),
        ToolDefinition(
          name: 'sub_run',
          description: '立即拉取订阅（等于网页版点"运行"）',
          parameters: _obj([
            'ids'
          ], {
            'ids': {'type': 'array', 'items': _intProp}
          }),
          isWrite: true,
          impact: '真的去克隆/下载脚本，会覆盖同名脚本文件，并按配置自动增删定时任务',
          reversible: false,
          danger: true,
        ),
        ToolDefinition(
          name: 'sub_stop',
          description: '停止正在拉取的订阅',
          parameters: _obj([
            'ids'
          ], {
            'ids': {'type': 'array', 'items': _intProp}
          }),
          isWrite: true,
          impact: '中断拉取，可能留下半个仓库',
          reversible: true,
        ),
        ToolDefinition(
          name: 'sub_enable',
          description: '启用订阅',
          parameters: _obj([
            'ids'
          ], {
            'ids': {'type': 'array', 'items': _intProp}
          }),
          isWrite: true,
          impact: '恢复按计划自动拉取',
          reversible: true,
        ),
        ToolDefinition(
          name: 'sub_disable',
          description: '禁用订阅',
          parameters: _obj([
            'ids'
          ], {
            'ids': {'type': 'array', 'items': _intProp}
          }),
          isWrite: true,
          impact: '停止按计划自动拉取',
          reversible: true,
        ),
        ToolDefinition(
          name: 'sub_delete',
          description: '删除订阅。force=true 时连它自动建的定时任务一起删',
          parameters: _obj([
            'ids'
          ], {
            'ids': {'type': 'array', 'items': _intProp},
            'force': {'type': 'boolean'},
          }),
          isWrite: true,
          impact: '永久删除订阅配置；force 还会删掉它创建的定时任务',
          reversible: false,
          danger: true,
        ),
        ToolDefinition(
          name: 'script_list',
          description: '列出脚本文件树',
          parameters: _obj([], {}),
          isWrite: false,
        ),
        ToolDefinition(
          name: 'script_read',
          description: '读取脚本内容',
          parameters: _obj(['path'], {'path': _stringProp}),
          isWrite: false,
        ),
        ToolDefinition(
          name: 'script_write',
          description: '新建或保存脚本。path 可以带子目录（如 mytask/run.js），'
              '缺失的目录会自动建——面板自己不会建父目录，'
              '直接写子目录会返回 500 ENOENT。',
          parameters: _obj([
            'path',
            'content'
          ], {
            'path': _stringProp,
            'content': _stringProp,
          }),
          isWrite: true,
          impact: '新建或覆盖脚本文件内容',
          reversible: false,
          danger: true,
        ),
        ToolDefinition(
          name: 'script_delete',
          description: '删除脚本',
          parameters: _obj(['path'], {'path': _stringProp}),
          isWrite: true,
          impact: '永久删除脚本文件',
          reversible: false,
          danger: true,
        ),
        ToolDefinition(
          name: 'script_run',
          description: '运行脚本',
          parameters: _obj(['path'], {'path': _stringProp}),
          isWrite: true,
          impact: '在面板执行脚本，可能产生真实业务副作用',
          reversible: false,
          danger: true,
        ),
        ToolDefinition(
          name: 'env_list',
          description: '列出环境变量，可搜索',
          parameters: _obj(['searchValue'], {'searchValue': _stringProp}),
          isWrite: false,
        ),
        ToolDefinition(
          name: 'env_create',
          description: '创建环境变量',
          parameters: _obj([
            'name',
            'value'
          ], {
            'name': _stringProp,
            'value': _stringProp,
            'remarks': _stringProp,
          }),
          isWrite: true,
          impact: '新增环境变量，可能被任务立即使用',
          reversible: true,
        ),
        ToolDefinition(
          name: 'env_update',
          description: '更新环境变量',
          parameters: _obj([
            'id',
            'name',
            'value'
          ], {
            'id': _intProp,
            'name': _stringProp,
            'value': _stringProp,
            'remarks': _stringProp,
          }),
          isWrite: true,
          impact: '覆盖环境变量的值，旧值不保留',
          reversible: false,
          danger: true,
        ),
        ToolDefinition(
          name: 'env_delete',
          description: '删除环境变量',
          parameters: _obj([
            'ids'
          ], {
            'ids': {'type': 'array', 'items': _intProp}
          }),
          isWrite: true,
          impact: '永久删除环境变量，依赖它的任务会失败',
          reversible: false,
          danger: true,
        ),
        ToolDefinition(
          name: 'env_enable',
          description: '启用环境变量',
          parameters: _obj([
            'ids'
          ], {
            'ids': {'type': 'array', 'items': _intProp}
          }),
          isWrite: true,
          impact: '启用环境变量',
          reversible: true,
        ),
        ToolDefinition(
          name: 'env_disable',
          description: '禁用环境变量',
          parameters: _obj([
            'ids'
          ], {
            'ids': {'type': 'array', 'items': _intProp}
          }),
          isWrite: true,
          impact: '禁用环境变量，依赖它的任务可能失败',
          reversible: true,
        ),
        ToolDefinition(
          name: 'dep_list',
          description: '列出依赖',
          parameters: _obj(['type'], {'type': _intProp}),
          isWrite: false,
        ),
        ToolDefinition(
          name: 'dep_install',
          description: '安装依赖',
          parameters: _obj([
            'type',
            'names'
          ], {
            'type': _intProp,
            'names': {'type': 'array', 'items': _stringProp},
          }),
          isWrite: true,
          impact: '在面板安装依赖，耗时较长并会改动运行环境',
          reversible: true,
        ),
        ToolDefinition(
          name: 'dep_remove',
          description: '卸载依赖',
          parameters: _obj([
            'type',
            'names'
          ], {
            'type': _intProp,
            'names': {'type': 'array', 'items': _stringProp},
          }),
          isWrite: true,
          impact: '卸载依赖，依赖它的脚本会失败',
          reversible: true,
          danger: true,
        ),
        ToolDefinition(
          name: 'dep_reinstall',
          description: '重装依赖',
          parameters: _obj([
            'type',
            'names'
          ], {
            'type': _intProp,
            'names': {'type': 'array', 'items': _stringProp},
          }),
          isWrite: true,
          impact: '先卸载再安装依赖，期间相关脚本不可用',
          reversible: true,
          danger: true,
        ),
        ToolDefinition(
          name: 'config_list',
          description: '列出配置文件',
          parameters: _obj([], {}),
          isWrite: false,
        ),
        ToolDefinition(
          name: 'config_read',
          description: '读取配置文件',
          parameters: _obj(['file'], {'file': _stringProp}),
          isWrite: false,
        ),
        ToolDefinition(
          name: 'config_save',
          description: '保存配置文件',
          parameters: _obj([
            'file',
            'content'
          ], {
            'file': _stringProp,
            'content': _stringProp,
          }),
          isWrite: true,
          impact: '覆盖配置文件内容，可能影响面板整体行为',
          reversible: false,
          danger: true,
        ),
        ToolDefinition(
          name: 'system_info',
          description: '获取青龙系统信息',
          parameters: _obj([], {}),
          isWrite: false,
        ),
        ToolDefinition(
          name: 'log_list',
          description: '按关键字列出日志文件。返回的 path 形如 '
              '"任务目录/2026-08-31-19-39-00-131.log"，读取时把整个 path 传给 log_read。'
              '**searchValue 必须是用户点名的那个任务/脚本名**，不要留空拉全量：'
              '别的任务的日志和当前问题无关，读了只是烧 token。'
              '只想看某个任务最近一次执行的输出，用 cron_log 更直接。',
          parameters: _obj([
            'searchValue'
          ], {
            'searchValue': _stringProp,
            'per_task': {
              'type': 'integer',
              'description': '每个任务目录最多给几条（默认 3，按时间新→旧）',
            },
          }),
          isWrite: false,
        ),
        ToolDefinition(
          name: 'log_read',
          description: '读取日志内容。path 用 log_list 返回的完整路径（含目录），'
              '只给文件名会读不到内容',
          parameters: _obj([
            'path'
          ], {
            'path': _stringProp,
            'file': _stringProp,
            'dir': _stringProp,
          }),
          isWrite: false,
        ),
        ToolDefinition(
          name: 'system_update',
          description: '更新青龙面板',
          parameters: _obj([], {}),
          isWrite: true,
          impact: '触发面板自更新与重启，期间服务不可用',
          reversible: false,
          danger: true,
        ),
        ToolDefinition(
          name: 'shell_probe',
          description: '探测本地 PRoot Debian 环境是否已安装可用',
          parameters: _obj([], {}),
          isWrite: false,
        ),
        ToolDefinition(
          name: 'shell_exec',
          description: '在本机 PRoot Debian 里执行命令。这是一个**真正的 shell**：'
              '管道、重定向、&&、;、for 循环、heredoc 都能用，'
              'command 直接写整条命令行即可（例如 '
              '`ls -la /workspace | head -20`、`pip install requests`、'
              '`python3 -c "print(1+1)"`）。'
              '有 python3/pip/git/curl 等常规工具，装东西用 apt-get install -y。'
              '需要跑十几行以上的代码就用 shell_script（写文件+执行一步到位），'
              '不要把长脚本塞进 -c。'
              '多个代理同时用终端时会自动排队，不会互相踩。',
          parameters: _obj([
            'command'
          ], {
            'command': {
              'type': 'string',
              'description': '整条命令行（走 shell，支持管道/重定向/&&）',
            },
            'args': {
              'type': 'array',
              'items': _stringProp,
              'description': '可选：给了 args 就按"程序+参数"直接执行，不过 shell',
            },
            'timeoutSeconds': _intProp,
          }),
          isWrite: true,
          impact: '在本机 PRoot Debian 里执行命令，可读写 workspace 并访问网络',
          reversible: false,
          danger: true,
        ),
        ToolDefinition(
          name: 'shell_script',
          description: '写一个脚本文件并立刻跑它，一步到位（省掉"写文件→再执行"两次调用）。'
              '这是处理复杂计算、批量文本处理、解析 JSON/CSV、生成报表的首选做法：'
              '与其在脑子里硬算再猜结果（那就是幻觉的来源），不如写十行 python 让机器算，'
              '拿到的是真实输出。脚本会留在磁盘上，后面还能改了再跑。'
              '默认解释器 python3，也支持 bash / node。',
          parameters: _obj([
            'code'
          ], {
            'code': {'type': 'string', 'description': '脚本源码（完整可运行）'},
            'language': {
              'type': 'string',
              'description': 'python（默认）/ bash / node',
            },
            'path': {
              'type': 'string',
              'description': '保存路径，默认 /workspace/.ai/ 下自动起名。'
                  '想复用/迭代同一个脚本时显式给同一个路径',
            },
            'args': {
              'type': 'array',
              'items': _stringProp,
              'description': '传给脚本的命令行参数',
            },
            'stdin': {'type': 'string', 'description': '喂给脚本标准输入的内容'},
            'timeoutSeconds': _intProp,
          }),
          isWrite: true,
          impact: '在本机 PRoot Debian 里写入脚本文件并执行它',
          reversible: false,
          danger: true,
        ),
        ToolDefinition(
          name: 'shell_list_files',
          description:
              '列出本地 Debian 目录内容（/workspace、/home/coomi、/opt/coomi-dev、/tmp）',
          parameters: _obj(['path'], {'path': _stringProp}),
          isWrite: false,
        ),
        ToolDefinition(
          name: 'shell_read_file',
          description: '读取本地 Debian 里的文本文件内容',
          parameters: _obj(['path'], {'path': _stringProp}),
          isWrite: false,
        ),
        ToolDefinition(
          name: 'shell_write_file',
          description: '写入本地 Debian 文本文件（覆盖），终端和 APP 文件管理看到的是同一份',
          parameters: _obj([
            'path',
            'content'
          ], {
            'path': _stringProp,
            'content': _stringProp,
          }),
          isWrite: true,
          impact: '覆盖本机 Debian 里的文件内容，旧内容不保留',
          reversible: false,
        ),
      ];

  /// 这些工具只碰本机 Debian，不需要选中青龙面板。
  static const _localOnlyTools = {
    'shell_probe',
    'shell_exec',
    'shell_script',
    'shell_list_files',
    'shell_read_file',
    'shell_write_file',
  };

  Future<String> execute({
    required String toolName,
    required Map<String, dynamic> args,
    required bool confirm,
  }) async {
    final m = definitions.where((d) => d.name == toolName);
    final def = m.isEmpty ? null : m.first;
    if (def == null) {
      throw ArgumentError('未知工具：$toolName');
    }
    if (def.isWrite && !confirm) {
      throw const ConfirmRequiredException();
    }
    final panel = _panelGetter();
    if (panel == null && !_localOnlyTools.contains(toolName)) {
      throw StateError('未选择面板，无法调用青龙接口；本机命令与文件工具不受影响');
    }
    final base = panel?.apiBaseUrl ?? '';

    switch (toolName) {
      case 'cron_list':
        final result = await CronApi.list(
          apiBaseUrl: base,
          searchValue: args['searchValue']?.toString(),
          page: 1,
          pageSize: 100,
        );
        return jsonEncode({
          'total': result.total,
          'items': [
            for (final t in result.items)
              {
                'id': t.id,
                'name': t.name,
                'command': t.command,
                'schedule': t.schedule,
                'disabled': t.isDisabled,
              },
          ],
        });

      case 'cron_log':
        final id = (args['id'] as num).toInt();
        // 青龙 2.15 的 /crons/:id/log 常返回空；真正有内容的是任务对象上的
        // log_path 指向的日志文件。先从任务列表拿 log_path，再按文件读取。
        final page = await CronApi.list(
          apiBaseUrl: base,
          page: 1,
          pageSize: 200,
        );
        final matched = page.items.where((t) => t.id == id);
        final task = matched.isEmpty ? null : matched.first;
        if (task == null) {
          return jsonEncode({'error': '任务 $id 不存在，请先用 cron_list 确认 id'});
        }
        final log = await CronApi.fetchLog(
          apiBaseUrl: base,
          id: id,
          logPath: task.logPath,
        );
        final lines = log.lines.where((l) => l.trim().isNotEmpty).toList();
        if (lines.isEmpty) {
          // 兜底：按任务名在日志中心里找最新的一份。
          final candidates = await LogApi.list(
            apiBaseUrl: base,
            searchValue: task.name,
          );
          if (candidates.isNotEmpty) {
            candidates.sort((a, b) => b.file.compareTo(a.file));
            final latest = candidates.first;
            final fallback = await LogApi.read(
              apiBaseUrl: base,
              file: latest.file,
              dir: latest.dir,
            );
            final text = fallback.join('\n').trim();
            if (text.isNotEmpty) {
              return jsonEncode({
                'task': task.name,
                'logFile': latest.dir.isEmpty
                    ? latest.file
                    : '${latest.dir}/${latest.file}',
                'content': _clip(text),
              });
            }
          }
          return jsonEncode({
            'task': task.name,
            'logPath': task.logPath ?? '',
            'content': '',
            'note': '该任务暂无日志内容（可能从未执行过，或日志已被清理）。'
                '可以用 log_list 搜任务名确认有哪些日志文件。',
          });
        }
        return jsonEncode({
          'task': task.name,
          'logPath': task.logPath ?? '',
          'content': _clip(lines.join('\n')),
        });

      case 'cron_create':
        await CronApi.create(
          apiBaseUrl: base,
          task: CronTask(
            name: args['name'] as String,
            command: args['command'] as String,
            schedule: args['schedule'] as String,
            labels: (args['labels'] as List? ?? const [])
                .map((e) => e.toString())
                .toList(),
          ),
        );
        return '已创建任务 ${args['name']}';

      case 'cron_update':
        await CronApi.update(
          apiBaseUrl: base,
          task: CronTask(
            id: (args['id'] as num).toInt(),
            name: args['name'] as String,
            command: args['command'] as String,
            schedule: args['schedule'] as String,
            labels: (args['labels'] as List? ?? const [])
                .map((e) => e.toString())
                .toList(),
          ),
        );
        return '已更新任务 ${args['id']}';

      case 'cron_delete':
        await CronApi.delete(
          apiBaseUrl: base,
          ids: _intList(args['ids']),
        );
        return '已删除任务';

      case 'cron_run':
        await CronApi.run(apiBaseUrl: base, ids: _intList(args['ids']));
        return '已发送运行指令';

      case 'cron_stop':
        await CronApi.stop(apiBaseUrl: base, ids: _intList(args['ids']));
        return '已发送停止指令';

      case 'cron_enable':
        await CronApi.setEnabled(
          apiBaseUrl: base,
          ids: _intList(args['ids']),
          enabled: true,
        );
        return '已启用任务';

      case 'cron_disable':
        await CronApi.setEnabled(
          apiBaseUrl: base,
          ids: _intList(args['ids']),
          enabled: false,
        );
        return '已禁用任务';

      case 'sub_list':
        final items = await SubscriptionApi.list(
          apiBaseUrl: base,
          searchValue: args['searchValue']?.toString(),
        );
        return jsonEncode({
          'total': items.length,
          'items': [
            for (final s in items)
              {
                'id': s.id,
                'name': s.displayName,
                'alias': s.alias,
                'type': s.type.wire,
                'url': s.url,
                'branch': s.branch,
                'schedule': s.scheduleLabel,
                'whitelist': s.whitelist,
                'blacklist': s.blacklist,
                'dependences': s.dependences,
                'status': s.isDisabled ? 'disabled' : s.status.name,
                'autoAddCron': s.autoAddCron,
                'autoDelCron': s.autoDelCron,
                // pull_option（私钥/密码）绝不出现在工具结果里：
                // 这段 JSON 会原样进对话上下文，等于把凭据发给模型。
              },
          ],
        });

      case 'sub_log':
        final log = await SubscriptionApi.fetchLog(
          apiBaseUrl: base,
          id: (args['id'] as num).toInt(),
        );
        if (log.lines.isEmpty) return '这条订阅还没有日志（可能从未拉取过）';
        // 拉仓库的日志能有几千行（npm install 那段最长），
        // 只回末尾 300 行：报错都在末尾，前面全是进度条。
        final lines = log.lines.length > 300
            ? log.lines.sublist(log.lines.length - 300)
            : log.lines;
        return lines.join('\n');

      case 'sub_create':
        final created = await SubscriptionApi.create(
          apiBaseUrl: base,
          sub: _subFromArgs(args),
        );
        return '已创建订阅：${created.displayName}（id=${created.id ?? '未知'}）；'
            '还没有拉取，需要立即拉请用 sub_run';

      case 'sub_update':
        final id = (args['id'] as num).toInt();
        // 面板的 PUT 是全量覆盖（type/url/alias 都是必填），
        // 模型通常只给要改的那一个字段，所以先取现值再覆盖。
        final current = await SubscriptionApi.detail(apiBaseUrl: base, id: id);
        await SubscriptionApi.update(
          apiBaseUrl: base,
          sub: _subFromArgs(args, base: current),
        );
        return '已更新订阅 $id';

      case 'sub_run':
        await SubscriptionApi.run(apiBaseUrl: base, ids: _intList(args['ids']));
        return '已开始拉取（异步执行，用 sub_list 看状态、sub_log 看进度）';

      case 'sub_stop':
        await SubscriptionApi.stop(
            apiBaseUrl: base, ids: _intList(args['ids']));
        return '已发送停止指令';

      case 'sub_enable':
        await SubscriptionApi.setEnabled(
          apiBaseUrl: base,
          ids: _intList(args['ids']),
          enabled: true,
        );
        return '已启用订阅';

      case 'sub_disable':
        await SubscriptionApi.setEnabled(
          apiBaseUrl: base,
          ids: _intList(args['ids']),
          enabled: false,
        );
        return '已禁用订阅';

      case 'sub_delete':
        final force = args['force'] == true;
        await SubscriptionApi.delete(
          apiBaseUrl: base,
          ids: _intList(args['ids']),
          force: force,
        );
        return force ? '已删除订阅及其自动创建的定时任务' : '已删除订阅（它建的定时任务保留）';

      case 'script_list':
        final nodes = await ScriptApi.files(apiBaseUrl: base);
        return jsonEncode({'files': nodes.map((n) => n.title).toList()});

      case 'script_read':
        return await ScriptApi.read(
          apiBaseUrl: base,
          file: args['path'] as String,
        );

      case 'script_write':
        await ScriptApi.save(
          apiBaseUrl: base,
          path: args['path'] as String,
          content: args['content'] as String,
        );
        return '已保存脚本 ${args['path']}';

      case 'script_delete':
        await ScriptApi.delete(
          apiBaseUrl: base,
          path: args['path'] as String,
        );
        return '已删除脚本 ${args['path']}';

      case 'script_run':
        // 面板执行的是请求里带的 content（写成 .swap 临时文件），
        // 所以要先读回脚本内容再提交，否则等于跑空文件。
        final runPath = args['path'] as String;
        final runContent = await ScriptApi.read(
          apiBaseUrl: base,
          file: runPath,
        );
        await ScriptApi.run(
          apiBaseUrl: base,
          path: runPath,
          content: runContent,
        );
        return '已发送脚本运行指令';

      case 'env_list':
        final items = await EnvApi.list(
          apiBaseUrl: base,
          searchValue: args['searchValue']?.toString(),
        );
        return jsonEncode([
          for (final e in items)
            {
              'id': e.id,
              'name': e.name,
              'value': e.value,
              'enabled': e.isEnabled,
            },
        ]);

      case 'env_create':
        await EnvApi.create(
          apiBaseUrl: base,
          env: EnvVar(
            name: args['name'] as String,
            value: args['value'] as String,
            remarks: args['remarks']?.toString(),
          ),
        );
        return '已创建环境变量 ${args['name']}';

      case 'env_update':
        await EnvApi.update(
          apiBaseUrl: base,
          env: EnvVar(
            id: (args['id'] as num).toInt(),
            name: args['name'] as String,
            value: args['value'] as String,
            remarks: args['remarks']?.toString(),
          ),
        );
        return '已更新环境变量 ${args['name']}';

      case 'env_delete':
        await EnvApi.delete(apiBaseUrl: base, ids: _intList(args['ids']));
        return '已删除环境变量';

      case 'env_enable':
        await EnvApi.setEnabled(
          apiBaseUrl: base,
          ids: _intList(args['ids']),
          enabled: true,
        );
        return '已启用环境变量';

      case 'env_disable':
        await EnvApi.setEnabled(
          apiBaseUrl: base,
          ids: _intList(args['ids']),
          enabled: false,
        );
        return '已禁用环境变量';

      case 'dep_list':
        final items = await DependencyApi.list(
          apiBaseUrl: base,
          type: (args['type'] as num).toInt(),
        );
        return jsonEncode([
          for (final d in items)
            {'name': d.name, 'status': d.status, 'type': d.type},
        ]);

      case 'dep_install':
        await DependencyApi.install(
          apiBaseUrl: base,
          type: (args['type'] as num).toInt(),
          names: _stringList(args['names']),
        );
        return '已开始安装依赖';

      case 'dep_remove':
        final removeNames = _stringList(args['names']);
        final removeType = (args['type'] as num?)?.toInt() ?? 0;
        final removeItems = await DependencyApi.list(
          apiBaseUrl: base,
          type: removeType,
        );
        final removeIds = [
          for (final d in removeItems)
            if (removeNames.contains(d.name) && d.id != null) d.id!,
        ];
        await DependencyApi.remove(apiBaseUrl: base, ids: removeIds);
        return '已卸载依赖';

      case 'dep_reinstall':
        final reinstallNames = _stringList(args['names']);
        final reinstallType = (args['type'] as num?)?.toInt() ?? 0;
        final reinstallItems = await DependencyApi.list(
          apiBaseUrl: base,
          type: reinstallType,
        );
        final reinstallIds = [
          for (final d in reinstallItems)
            if (reinstallNames.contains(d.name) && d.id != null) d.id!,
        ];
        await DependencyApi.reinstall(apiBaseUrl: base, ids: reinstallIds);
        return '已开始重装依赖';

      case 'config_list':
        final items = await ConfigApi.files(apiBaseUrl: base);
        return jsonEncode([for (final c in items) c.name]);

      case 'config_read':
        return await ConfigApi.read(
          apiBaseUrl: base,
          file: args['file'] as String,
        );

      case 'config_save':
        await ConfigApi.save(
          apiBaseUrl: base,
          file: args['file'] as String,
          content: args['content'] as String,
        );
        return '已保存配置 ${args['file']}';

      case 'system_info':
        final info = await SystemApi.info(apiBaseUrl: base);
        return jsonEncode({'version': info.version});

      case 'log_list':
        final items = await LogApi.list(
          apiBaseUrl: base,
          searchValue: args['searchValue']?.toString(),
        );
        // 按任务目录折叠，每个目录只给最近几条。
        //
        // 面板里攒着几百个日志文件，全量返回既撑爆上下文，又诱导模型
        // "既然都列出来了就一份份读"——那些日志跟用户问的那一个任务无关。
        final perTask = ((args['per_task'] as num?)?.toInt() ?? 3).clamp(1, 20);
        final grouped = <String, List<Map<String, String>>>{};
        for (final l in items) {
          final bucket = grouped.putIfAbsent(l.dir, () => []);
          bucket.add({
            'path': l.dir.isEmpty ? l.file : '${l.dir}/${l.file}',
            'dir': l.dir,
            'file': l.file,
          });
        }
        final picked = <Map<String, String>>[];
        for (final entry in grouped.entries) {
          // 文件名以时间开头，倒序取最近的几条。
          final sorted = entry.value.toList()
            ..sort((a, b) => (b['file'] ?? '').compareTo(a['file'] ?? ''));
          picked.addAll(sorted.take(perTask));
        }
        return jsonEncode({
          'total': items.length,
          'tasks': grouped.length,
          'shown': picked.length,
          'note': grouped.length > 1
              ? '匹配到 ${grouped.length} 个任务目录，每个只给最近 $perTask 条。'
                  '只读和用户问的那个任务相关的，别的别读。'
              : '每个任务目录只给最近 $perTask 条。',
          'logs': picked,
        });

      case 'log_read':
        final raw = (args['path'] ?? args['file'] ?? '').toString();
        if (raw.isEmpty) {
          return jsonEncode({'error': '缺少 path，请先用 log_list 拿到完整路径'});
        }
        final slash = raw.lastIndexOf('/');
        final dir = args['dir']?.toString().isNotEmpty == true
            ? args['dir'].toString()
            : (slash < 0 ? '' : raw.substring(0, slash));
        final file = slash < 0 ? raw : raw.substring(slash + 1);
        final lines = await LogApi.read(
          apiBaseUrl: base,
          file: file,
          dir: dir,
        );
        final text = lines.join('\n').trim();
        if (text.isEmpty) {
          return jsonEncode({
            'path': raw,
            'content': '',
            'note': '这份日志文件是空的。换一个更近的日志文件试试，'
                '或者用 log_list 确认路径是否完整（需要包含目录）。',
          });
        }
        return _clip(text);

      case 'system_update':
        await SystemApi.update(apiBaseUrl: base);
        return '已发送面板更新指令';

      case 'shell_probe':
        try {
          final status = await ProotBridge().status();
          return jsonEncode({
            'installed': status.installed,
            'version': status.version,
            'workspace': status.workspace,
          });
        } catch (e) {
          return jsonEncode({'installed': false, 'error': e.toString()});
        }

      case 'shell_exec':
        const sandbox = CommandSandbox();
        final command = args['command'] as String;
        sandbox.validate(command);
        final cmdTimeout = (args['timeoutSeconds'] as num?)?.toInt() ?? 60;
        // 终端是单例资源：多个代理同时 exec 会互相拆台（dpkg 锁、cwd、同名文件）。
        // 这里排队而不是拒绝——任务照样能做完，只是慢一点。
        //
        // 等锁的上限跟着命令自己的超时走：一条 apt install 合法地要跑 5 分钟，
        // 用固定的 180 秒去等它，排在后面的命令会无辜失败。加 90 秒余量，
        // 真的卡死（连"超时已杀掉"都不回）时才报错，并且点名是谁占着。
        final result = await ShellLock.run(
          ShellLock.terminal,
          () => _exec(
            command,
            args: _stringList(args['args']),
            timeoutSeconds: cmdTimeout,
          ),
          label: 'shell_exec: ${_head(command)}',
          timeout: Duration(seconds: cmdTimeout + 90),
        );
        return jsonEncode({
          'code': result.exitCode,
          'stdout': result.stdout.substring(
              0, result.stdout.length > 20000 ? 20000 : result.stdout.length),
          'stderr': result.stderr,
        });

      case 'shell_script':
        return _runScript(args);

      case 'shell_list_files':
        final listing = await ProotBridge().listFiles(
          path: args['path']?.toString() ?? '/workspace',
        );
        return jsonEncode({
          'path': listing.path,
          'entries': [
            for (final e in listing.entries)
              {
                'name': e.name,
                'path': e.path,
                'type': e.isDirectory ? 'dir' : 'file',
                'size': e.size,
              },
          ],
        });

      case 'shell_read_file':
        final content = await ProotBridge().readFile(
          path: args['path']?.toString() ?? '',
        );
        return content.length > 20000
            ? '${content.substring(0, 20000)}\n…（内容过长已截断）'
            : content;

      case 'shell_write_file':
        final target = args['path']?.toString() ?? '';
        // 按文件排队：多个子代理同时写同一个文件时后写的会整篇覆盖前一个，
        // 排队至少保证每一次写是完整的（谁最后写谁生效，而不是内容交错）。
        final entry = await ShellLock.run(
          ShellLock.file(target),
          () => ProotBridge().writeFile(
            path: target,
            content: args['content']?.toString() ?? '',
          ),
          label: 'shell_write_file',
          timeout: const Duration(seconds: 60),
        );
        return '已写入 ${entry.path}（${entry.size} 字节）';

      default:
        throw ArgumentError('未实现工具：$toolName');
    }
  }

  /// 写脚本 + 立刻执行。
  ///
  /// 为什么单独做一个工具而不是让模型自己 write_file + exec：那是两次往返、
  /// 两次确认，而且中间那一步一旦漏掉（模型经常直接跳到 exec），跑的就是
  /// 上一版代码。合成一步之后"写完必然跑的是这一版"。
  Future<String> _runScript(Map<String, dynamic> args) async {
    final code = args['code']?.toString() ?? '';
    if (code.trim().isEmpty) return jsonEncode({'error': 'code 是空的'});
    final language = (args['language']?.toString() ?? 'python').toLowerCase();
    final ({String bin, String ext}) runtime = switch (language) {
      'bash' || 'sh' || 'shell' => (bin: 'bash', ext: 'sh'),
      'node' || 'js' || 'javascript' => (bin: 'node', ext: 'js'),
      _ => (bin: 'python3', ext: 'py'),
    };
    var path = args['path']?.toString().trim() ?? '';
    if (path.isEmpty) {
      path = '/workspace/.ai/s${DateTime.now().millisecondsSinceEpoch}'
          '.${runtime.ext}';
    } else if (!path.startsWith('/')) {
      path = '/workspace/$path';
    }
    const sandbox = CommandSandbox();
    sandbox.validate(code);
    final bridge = ProotBridge();
    final scriptArgs = _stringList(args['args']);
    final stdin = args['stdin']?.toString() ?? '';
    final timeout = (args['timeoutSeconds'] as num?)?.toInt() ?? 120;

    // 写 + 跑必须在同一个锁区间里：中间放别人进来的话，另一个代理可能
    // 正好把同一个路径覆盖掉，跑的就不是刚写的那份代码了。
    return ShellLock.run(
      ShellLock.terminal,
      timeout: Duration(seconds: timeout + 90),
      () async {
        await bridge.writeFile(path: path, content: code);
        final command = stdin.isEmpty
            ? '${runtime.bin} ${_quote(path)}'
                '${scriptArgs.isEmpty ? '' : ' ${scriptArgs.map(_quote).join(' ')}'}'
            // stdin 用 here-doc 喂：比写临时文件少一次落盘，也不怕转义。
            : '${runtime.bin} ${_quote(path)}'
                '${scriptArgs.isEmpty ? '' : ' ${scriptArgs.map(_quote).join(' ')}'}'
                " <<'__AI_STDIN__'\n$stdin\n__AI_STDIN__";
        final result = await _exec(command, timeoutSeconds: timeout);
        final stdout = result.stdout.length > 20000
            ? '${result.stdout.substring(0, 20000)}\n…（stdout 已截断）'
            : result.stdout;
        return jsonEncode({
          'script': path,
          'ran': '${runtime.bin} $path',
          'code': result.exitCode,
          'stdout': stdout,
          'stderr': result.stderr,
          if (result.exitCode == 127)
            'hint': '找不到 ${runtime.bin}：先 shell_exec 装它'
                '（apt-get install -y ${runtime.bin}），或者换个 language。',
        });
      },
      label: 'shell_script: $path',
    );
  }

  /// 执行命令。**需要 shell 语义时自动套一层 shell。**
  ///
  /// 原生侧的 exec 是 `env -i <command> <args...>` 直接 execve，没有 shell：
  /// 所以 `ls -la | head` 会被当成一个叫 "ls -la | head" 的可执行文件，
  /// 结果是"命令找不到"。而模型写命令的习惯就是整条命令行——这个落差
  /// 之前一直靠模型自己猜（猜错就是一堆无效调用）。
  ///
  /// 规则：显式给了 args 就按"程序 + 参数"直接执行（保持原语义）；
  /// 否则只要命令里有空格或 shell 元字符，就交给 bash -c。
  /// bash 不在（极简 rootfs）时退回 /bin/sh 再试一次。
  static Future<ExecResult> _exec(
    String command, {
    List<String> args = const [],
    int timeoutSeconds = 60,
  }) async {
    final bridge = ProotBridge();
    if (args.isNotEmpty) {
      return bridge.exec(
        command: command,
        args: args,
        timeoutSeconds: timeoutSeconds,
      );
    }
    final trimmed = command.trim();
    final needsShell = RegExp(r'''[\s|&;<>()$`*?\[\]{}"']''').hasMatch(trimmed);
    if (!needsShell) {
      return bridge.exec(command: trimmed, timeoutSeconds: timeoutSeconds);
    }
    final result = await bridge.exec(
      command: '/bin/bash',
      args: ['-c', trimmed],
      timeoutSeconds: timeoutSeconds,
    );
    // 127 + 提到 bash = 这个 rootfs 没装 bash，用 POSIX shell 再来一次。
    if (result.exitCode == 127 &&
        result.stdout.trim().isEmpty &&
        result.stderr.toLowerCase().contains('bash')) {
      return bridge.exec(
        command: '/bin/sh',
        args: ['-c', trimmed],
        timeoutSeconds: timeoutSeconds,
      );
    }
    return result;
  }

  /// shell 参数加引号。路径里有空格/中文时不加会被拆成两个参数。
  static String _quote(String value) => "'${value.replaceAll("'", "'\\''")}'";

  static String _head(String text, [int max = 40]) {
    final one = text.replaceAll('\n', ' ').trim();
    return one.length <= max ? one : '${one.substring(0, max)}…';
  }

  /// 统一裁剪超长文本，避免一份日志把上下文吃满。
  String _clip(String text, {int max = 12000}) {
    if (text.length <= max) return text;
    final tail = text.substring(text.length - max);
    return '…（已省略前 ${text.length - max} 字符，以下为日志末尾）…\n$tail';
  }

  /// 工具参数 → Subscription。
  ///
  /// [base] 是面板上的现值（更新时先拉一次）：模型只给了要改的字段，
  /// 其余必须沿用旧值，否则 PUT 的必填项（type/url/alias）会空着被 400。
  Subscription _subFromArgs(Map<String, dynamic> args, {Subscription? base}) {
    String pick(String key, String fallback) {
      final v = args[key];
      return v == null ? fallback : v.toString();
    }

    bool pickBool(String key, bool fallback) {
      final v = args[key];
      if (v == null) return fallback;
      if (v is bool) return v;
      final t = v.toString().trim().toLowerCase();
      return t == '1' || t == 'true';
    }

    final type = args['type'] == null
        ? (base?.type ?? SubType.publicRepo)
        : SubType.parse(args['type'].toString());
    final url = pick('url', base?.url ?? '');
    var alias = pick('alias', base?.alias ?? '').trim();
    if (alias.isEmpty) alias = Subscription.aliasFromUrl(url, type: type);
    // 只有 url 也空着才会走到这儿（正常不该发生，schema 里 url 是必填）。
    // 面板要求 alias 必填，给个兜底名，让错误停在"url 不能为空"上更好懂。
    if (alias.isEmpty) alias = 'sub_unnamed';
    final schedule = pick('schedule', base?.schedule ?? '').trim();
    return Subscription(
      id: base?.id,
      type: type,
      url: url,
      alias: alias,
      name: pick('name', base?.name ?? ''),
      // 只给了 cron 就按 cron 走；面板对 interval 有独立结构，
      // 模型侧不暴露它（要改间隔去界面上改，省一堆容易填错的字段）。
      scheduleKind: schedule.isNotEmpty
          ? SubScheduleKind.crontab
          : (base?.scheduleKind ?? SubScheduleKind.crontab),
      schedule: schedule.isEmpty ? '0 6 * * *' : schedule,
      interval: base?.interval ?? const SubInterval(),
      branch: pick('branch', base?.branch ?? ''),
      whitelist: pick('whitelist', base?.whitelist ?? ''),
      blacklist: pick('blacklist', base?.blacklist ?? ''),
      dependences: pick('dependences', base?.dependences ?? ''),
      extensions: pick('extensions', base?.extensions ?? ''),
      subBefore: base?.subBefore ?? '',
      subAfter: base?.subAfter ?? '',
      proxy: pick('proxy', base?.proxy ?? ''),
      autoAddCron: pickBool('autoAddCron', base?.autoAddCron ?? true),
      autoDelCron: pickBool('autoDelCron', base?.autoDelCron ?? true),
      // 凭据只能在界面上填：让模型经手等于把私钥写进对话记录。
      pullType: base?.pullType,
      pullOption: base?.pullOption ?? const {},
    );
  }

  List<int> _intList(Object? value) {
    if (value is List) {
      return value.map((e) => (e as num).toInt()).toList();
    }
    if (value is num) return [value.toInt()];
    return const [];
  }

  List<String> _stringList(Object? value) {
    if (value is List) return value.map((e) => e.toString()).toList();
    if (value is String) return [value];
    return const [];
  }
}
