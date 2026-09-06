import 'package:flutter_test/flutter_test.dart';
import 'package:qinglong_flutter/features/ai/agent/tool_registry.dart';
import 'package:qinglong_flutter/features/subscriptions/models/subscription.dart';
import 'package:qinglong_flutter/features/subscriptions/providers/subscription_list_provider.dart';

/// 订阅模块的回归点。
///
/// 这一块最容易出的三类事故，都不需要连真面板就能测：
/// 1. 请求体多带字段 → 面板 Joi 直接 400，界面上只显示一句"面板拒绝请求"；
/// 2. cron / interval 两种定时互相污染（改成间隔了还按老 cron 跑）；
/// 3. 别名没生成出来 → 面板报 alias 必填，用户完全看不懂。
void main() {
  group('别名自动推导', () {
    test('公开仓库取 owner_repo', () {
      expect(
        Subscription.aliasFromUrl('https://github.com/whyour/qinglong'),
        'whyour_qinglong',
      );
    });

    test('.git 后缀和结尾斜杠都要去掉', () {
      expect(
        Subscription.aliasFromUrl('https://github.com/owner/my-repo.git/'),
        'owner_my-repo',
      );
    });

    test('ssh 形式的地址也认', () {
      expect(
        Subscription.aliasFromUrl('git@github.com:owner/repo.git'),
        'owner_repo',
      );
    });

    test('单文件取文件名去扩展名', () {
      expect(
        Subscription.aliasFromUrl(
          'https://raw.githubusercontent.com/a/b/main/jd_bean.js',
          type: SubType.file,
        ),
        'jd_bean',
      );
    });

    test('中文仓库名削空后退到稳定哈希别名（同址同名）', () {
      const url = 'https://gitee.com/张三/我的 脚本';
      final alias = Subscription.aliasFromUrl(url);
      expect(alias, matches(RegExp(r'^sub_[0-9a-f]{6}$')));
      // 重算一次要一模一样：否则每次保存都换一个日志目录。
      expect(Subscription.aliasFromUrl(url), alias);
      expect(
        Subscription.aliasFromUrl('https://gitee.com/李四/别的 脚本'),
        isNot(alias),
      );
    });

    test('空地址给空别名（界面据此提示"先填地址"）', () {
      expect(Subscription.aliasFromUrl('   '), '');
    });
  });

  group('请求体只发面板认的字段', () {
    const allowedPost = {
      'type',
      'schedule',
      'interval_schedule',
      'name',
      'url',
      'whitelist',
      'blacklist',
      'branch',
      'dependences',
      'pull_type',
      'pull_option',
      'extensions',
      'sub_before',
      'sub_after',
      'schedule_type',
      'alias',
      'proxy',
      'autoAddCron',
      'autoDelCron',
    };

    test('新建：字段全在白名单内，且必填项都在', () {
      const sub = Subscription(
        type: SubType.publicRepo,
        url: 'https://github.com/owner/repo',
        alias: 'owner_repo',
        schedule: '0 6 * * *',
      );
      final body = sub.toRequestBody();
      expect(body.keys.toSet().difference(allowedPost), isEmpty);
      // 面板对这三个是 required，缺一个就 400。
      expect(body['type'], 'public-repo');
      expect(body['url'], 'https://github.com/owner/repo');
      expect(body['alias'], 'owner_repo');
      expect(body['schedule_type'], 'crontab');
      expect(body.containsKey('id'), isFalse);
      // 状态类字段一律不能发（"status" is not allowed）。
      expect(body.containsKey('status'), isFalse);
      expect(body.containsKey('is_disabled'), isFalse);
      expect(body.containsKey('command'), isFalse);
    });

    test('更新：带 id，其余仍在白名单内', () {
      const sub = Subscription(
        id: 7,
        type: SubType.file,
        url: 'https://example.com/x.js',
        alias: 'x',
        schedule: '0 6 * * *',
      );
      final body = sub.toRequestBody(withId: true);
      expect(body['id'], 7);
      expect(body.keys.toSet().difference({...allowedPost, 'id'}), isEmpty);
    });

    test('间隔模式：发 interval_schedule，并把 cron 清空', () {
      const sub = Subscription(
        type: SubType.publicRepo,
        url: 'https://github.com/owner/repo',
        alias: 'owner_repo',
        // 用户之前填过 cron，切到间隔之后这条不能再被面板拿去排程。
        schedule: '0 6 * * *',
        scheduleKind: SubScheduleKind.interval,
        interval: SubInterval(unit: 'hours', value: 6),
      );
      final body = sub.toRequestBody();
      expect(body['schedule_type'], 'interval');
      expect(body['schedule'], '');
      expect(body['interval_schedule'], {'type': 'hours', 'value': 6});
    });

    test('cron 模式不发 interval_schedule', () {
      const sub = Subscription(
        type: SubType.publicRepo,
        url: 'https://github.com/owner/repo',
        alias: 'owner_repo',
        schedule: '0 6 * * *',
      );
      expect(sub.toRequestBody().containsKey('interval_schedule'), isFalse);
    });

    test('单文件不发分支（面板拿它拼 git 命令，file 类型用不上）', () {
      const sub = Subscription(
        type: SubType.file,
        url: 'https://example.com/x.js',
        alias: 'x',
        branch: 'main',
      );
      expect(sub.toRequestBody()['branch'], '');
    });

    test('只有私有仓库才带凭据', () {
      const publicSub = Subscription(
        type: SubType.publicRepo,
        url: 'https://github.com/owner/repo',
        alias: 'owner_repo',
        pullType: SubPullType.userPwd,
        pullOption: {'username': 'u', 'password': 'p'},
      );
      final publicBody = publicSub.toRequestBody();
      expect(publicBody.containsKey('pull_type'), isFalse);
      expect(publicBody.containsKey('pull_option'), isFalse);

      const privateSub = Subscription(
        type: SubType.privateRepo,
        url: 'https://github.com/owner/repo',
        alias: 'owner_repo',
        pullType: SubPullType.sshKey,
        pullOption: {'private_key': 'KEY'},
      );
      final privateBody = privateSub.toRequestBody();
      expect(privateBody['pull_type'], 'ssh-key');
      expect(privateBody['pull_option'], {'private_key': 'KEY'});
    });
  });

  group('解析面板返回', () {
    test('字段齐全时逐项还原', () {
      final sub = Subscription.fromJson(const {
        'id': 3,
        'name': '京东脚本',
        'alias': 'jd',
        'type': 'private-repo',
        'schedule_type': 'crontab',
        'schedule': '0 7 * * *',
        'url': 'https://github.com/a/b',
        'branch': 'main',
        'whitelist': 'jd_',
        'blacklist': 'test',
        'dependences': 'utils',
        'extensions': 'js',
        'sub_before': 'echo a',
        'sub_after': 'echo b',
        'proxy': 'http://127.0.0.1:7890',
        'pull_type': 'user-pwd',
        'pull_option': {'username': 'u', 'password': 'p'},
        'status': 0,
        'is_disabled': 1,
        'autoAddCron': 1,
        'autoDelCron': 0,
        'log_path': 'jd/2026-01-01.log',
        'command': 'SUB_ID=3 ql repo ...',
      });
      expect(sub.id, 3);
      expect(sub.type, SubType.privateRepo);
      expect(sub.pullType, SubPullType.userPwd);
      expect(sub.status, SubStatus.running);
      expect(sub.isRunning, isTrue);
      expect(sub.isDisabled, isTrue);
      expect(sub.autoAddCron, isTrue);
      expect(sub.autoDelCron, isFalse);
      expect(sub.logPath, 'jd/2026-01-01.log');
    });

    test('autoAddCron / autoDelCron 缺省算开启（面板 isNil 语义）', () {
      final sub = Subscription.fromJson(const {'id': 1, 'url': 'u'});
      expect(sub.autoAddCron, isTrue);
      expect(sub.autoDelCron, isTrue);
    });

    test('排队中也算在忙，不该再点运行', () {
      final sub = Subscription.fromJson(const {'id': 1, 'status': 3});
      expect(sub.status, SubStatus.queued);
      expect(sub.isRunning, isTrue);
    });

    test('interval_schedule 往返不丢，非法单位回落到天', () {
      final sub = Subscription.fromJson(const {
        'schedule_type': 'interval',
        'interval_schedule': {'type': 'weeks', 'value': 0},
      });
      expect(sub.scheduleKind, SubScheduleKind.interval);
      // 面板要求 value ≥ 1；'weeks' 不在 toad-scheduler 的单位里。
      expect(sub.interval.unit, 'days');
      expect(sub.interval.value, 1);
    });

    test('名称留空时退到别名，再退到地址', () {
      expect(
        Subscription.fromJson(const {'alias': 'jd', 'url': 'u'}).displayName,
        'jd',
      );
      expect(
        Subscription.fromJson(const {'url': 'https://x/y'}).displayName,
        'https://x/y',
      );
    });

    test('定时说明：间隔模式说人话，cron 模式给表达式', () {
      final interval = Subscription.fromJson(const {
        'schedule_type': 'interval',
        'interval_schedule': {'type': 'hours', 'value': 12},
      });
      expect(interval.scheduleLabel, '每 12 小时');
      final cron = Subscription.fromJson(const {'schedule': '0 6 * * *'});
      expect(cron.scheduleLabel, '0 6 * * *');
      final none = Subscription.fromJson(const {'id': 1});
      expect(none.scheduleLabel, '未设置定时');
    });
  });

  group('命令预览与面板一致', () {
    test('仓库类型按 repo 的九个位置参数拼', () {
      const sub = Subscription(
        id: 5,
        type: SubType.publicRepo,
        url: 'https://github.com/a/b',
        alias: 'a_b',
        whitelist: 'jd_',
        blacklist: 'bl',
        dependences: 'utils',
        branch: 'main',
        extensions: 'js',
        proxy: 'p',
      );
      expect(
        sub.previewCommand,
        'SUB_ID=5 ql repo "https://github.com/a/b" "jd_" "bl" "utils" '
        '"main" "js" "p" "true" "true"',
      );
    });

    test('单文件按 raw 拼', () {
      const sub = Subscription(
        id: 6,
        type: SubType.file,
        url: 'https://x/y.js',
        alias: 'y',
        autoAddCron: false,
        autoDelCron: false,
      );
      expect(
        sub.previewCommand,
        'SUB_ID=6 ql raw "https://x/y.js" "" "false" "false"',
      );
    });
  });

  group('列表筛选', () {
    final items = [
      const Subscription(id: 1, alias: 'a'),
      const Subscription(id: 2, alias: 'b', isDisabled: true),
      const Subscription(id: 3, alias: 'c', status: SubStatus.running),
    ];

    test('四个筛选各自命中', () {
      List<int> ids(SubFilter f) => items
          .where(f.matches)
          .map((s) => s.id!)
          .toList();
      expect(ids(SubFilter.all), [1, 2, 3]);
      expect(ids(SubFilter.enabled), [1, 3]);
      expect(ids(SubFilter.disabled), [2]);
      expect(ids(SubFilter.running), [3]);
    });

    test('有在跑的才开轮询（省电）', () {
      expect(SubListState(items: items).anyRunning, isTrue);
      expect(
        SubListState(items: items.take(2).toList()).anyRunning,
        isFalse,
      );
    });
  });

  group('AI 工具接线', () {
    test('九个 sub_* 工具都在工具表里，且读写标记正确', () {
      final registry = QlToolRegistry(panelGetter: () => null);
      final byName = {for (final d in registry.definitions) d.name: d};
      for (final name in [
        'sub_list',
        'sub_log',
        'sub_create',
        'sub_update',
        'sub_run',
        'sub_stop',
        'sub_enable',
        'sub_disable',
        'sub_delete',
      ]) {
        expect(byName.containsKey(name), isTrue, reason: '缺少工具 $name');
      }
      expect(byName['sub_list']!.isWrite, isFalse);
      expect(byName['sub_log']!.isWrite, isFalse);
      // 拉取会真的覆盖脚本文件、增删任务，必须算危险操作（"仅危险"策略也要拦）。
      expect(byName['sub_run']!.danger, isTrue);
      expect(byName['sub_delete']!.danger, isTrue);
      expect(byName['sub_delete']!.reversible, isFalse);
      expect(byName['sub_enable']!.danger, isFalse);
    });

    test('写工具没确认过一律拒绝执行', () {
      final registry = QlToolRegistry(panelGetter: () => null);
      expect(
        () => registry.execute(
          toolName: 'sub_create',
          args: const {
            'type': 'public-repo',
            'url': 'https://github.com/a/b',
          },
          confirm: false,
        ),
        throwsA(isA<ConfirmRequiredException>()),
      );
    });

    test('只读工具不卡确认，卡的是"没选面板"', () {
      final registry = QlToolRegistry(panelGetter: () => null);
      expect(
        () => registry.execute(
          toolName: 'sub_list',
          args: const {},
          confirm: false,
        ),
        throwsA(isA<StateError>()),
      );
    });
  });
}
