import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/utils/cron_parser.dart';
import '../../../core/utils/error_text.dart';
import '../../../core/utils/formatter.dart';
import '../../../shared/glass_scaffold.dart';
import '../../../shared/mono_text.dart';
import '../../../core/theme/glass.dart';
import '../models/subscription.dart';

/// 新建 / 编辑订阅。
///
/// 面板网页版这一页是十几个平铺输入框，小白第一次看只会问"到底填哪几个"。
/// 这里按"先选是什么、再填地址、再说多久拉一次"排，仓库筛选和私有凭据
/// 只在用到的类型下出现，剩下的塞进高级里，并且顶部一直显示最终会执行的命令。
class SubscriptionEditPage extends ConsumerStatefulWidget {
  const SubscriptionEditPage({
    super.key,
    required this.onSubmit,
    this.sub,
  });

  final Subscription? sub;
  final Future<void> Function(Subscription sub) onSubmit;

  @override
  ConsumerState<SubscriptionEditPage> createState() =>
      _SubscriptionEditPageState();
}

class _SubscriptionEditPageState extends ConsumerState<SubscriptionEditPage> {
  late final TextEditingController _urlController;
  late final TextEditingController _aliasController;
  late final TextEditingController _nameController;
  late final TextEditingController _branchController;
  late final TextEditingController _scheduleController;
  late final TextEditingController _intervalController;
  late final TextEditingController _whitelistController;
  late final TextEditingController _blacklistController;
  late final TextEditingController _dependencesController;
  late final TextEditingController _extensionsController;
  late final TextEditingController _beforeController;
  late final TextEditingController _afterController;
  late final TextEditingController _proxyController;
  late final TextEditingController _keyController;
  late final TextEditingController _userController;
  late final TextEditingController _passController;

  late SubType _type;
  late SubScheduleKind _scheduleKind;
  late String _intervalUnit;
  late bool _autoAddCron;
  late bool _autoDelCron;
  SubPullType? _pullType;

  /// 别名是否还跟着 URL 自动走。用户手动改过就不再覆盖他的输入。
  bool _aliasAuto = true;
  bool _advancedOpen = false;
  bool _saving = false;

  bool get _isEdit => widget.sub != null;

  @override
  void initState() {
    super.initState();
    final s = widget.sub;
    _type = s?.type ?? SubType.publicRepo;
    _scheduleKind = s?.scheduleKind ?? SubScheduleKind.crontab;
    _intervalUnit = s?.interval.unit ?? 'days';
    _autoAddCron = s?.autoAddCron ?? true;
    _autoDelCron = s?.autoDelCron ?? true;
    _pullType = s?.pullType ?? (_type == SubType.privateRepo ? SubPullType.userPwd : null);
    _aliasAuto = s == null;
    _urlController = TextEditingController(text: s?.url ?? '');
    _aliasController = TextEditingController(text: s?.alias ?? '');
    _nameController = TextEditingController(text: s?.name ?? '');
    _branchController = TextEditingController(text: s?.branch ?? '');
    // 默认每天 6 点拉一次：仓库脚本更新频率就这个量级，
    // 留空会被面板拒（cron 解析不过），给个能直接用的值。
    _scheduleController =
        TextEditingController(text: s?.schedule ?? '0 6 * * *');
    _intervalController =
        TextEditingController(text: '${s?.interval.value ?? 1}');
    _whitelistController = TextEditingController(text: s?.whitelist ?? '');
    _blacklistController = TextEditingController(text: s?.blacklist ?? '');
    _dependencesController = TextEditingController(text: s?.dependences ?? '');
    _extensionsController = TextEditingController(text: s?.extensions ?? '');
    _beforeController = TextEditingController(text: s?.subBefore ?? '');
    _afterController = TextEditingController(text: s?.subAfter ?? '');
    _proxyController = TextEditingController(text: s?.proxy ?? '');
    final option = s?.pullOption ?? const {};
    _keyController =
        TextEditingController(text: option['private_key']?.toString() ?? '');
    _userController =
        TextEditingController(text: option['username']?.toString() ?? '');
    _passController =
        TextEditingController(text: option['password']?.toString() ?? '');
    _advancedOpen = (s?.subBefore.isNotEmpty ?? false) ||
        (s?.subAfter.isNotEmpty ?? false) ||
        (s?.proxy.isNotEmpty ?? false);
  }

  @override
  void dispose() {
    _urlController.dispose();
    _aliasController.dispose();
    _nameController.dispose();
    _branchController.dispose();
    _scheduleController.dispose();
    _intervalController.dispose();
    _whitelistController.dispose();
    _blacklistController.dispose();
    _dependencesController.dispose();
    _extensionsController.dispose();
    _beforeController.dispose();
    _afterController.dispose();
    _proxyController.dispose();
    _keyController.dispose();
    _userController.dispose();
    _passController.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------------ 校验

  String get _cronExpr => _scheduleController.text.trim();

  int get _intervalValue {
    final v = int.tryParse(_intervalController.text.trim()) ?? 0;
    return v < 1 ? 0 : v;
  }

  /// 还差什么。返回空串表示可以保存。
  String get _blocker {
    if (_urlController.text.trim().isEmpty) return '先填订阅地址';
    if (_aliasController.text.trim().isEmpty) return '别名不能为空（面板拿它当日志目录名）';
    if (_scheduleKind == SubScheduleKind.crontab) {
      if (_cronExpr.isEmpty) return '填一个 cron 表达式';
      if (!CronParser.isValid(_cronExpr)) return 'cron 表达式不合法';
    } else if (_intervalValue < 1) {
      return '间隔至少是 1';
    }
    if (_type == SubType.privateRepo) {
      if (_pullType == SubPullType.sshKey &&
          _keyController.text.trim().isEmpty) {
        return '私有仓库要填 SSH 私钥';
      }
      if (_pullType == SubPullType.userPwd &&
          (_userController.text.trim().isEmpty ||
              _passController.text.trim().isEmpty)) {
        return '私有仓库要填用户名和密码/Token';
      }
    }
    return '';
  }

  Subscription _build() {
    final option = <String, dynamic>{};
    if (_type == SubType.privateRepo) {
      if (_pullType == SubPullType.sshKey) {
        option['private_key'] = _keyController.text.trim();
      } else {
        option['username'] = _userController.text.trim();
        option['password'] = _passController.text.trim();
      }
    }
    return Subscription(
      id: widget.sub?.id,
      name: _nameController.text.trim(),
      alias: _aliasController.text.trim(),
      type: _type,
      url: _urlController.text.trim(),
      branch: _branchController.text.trim(),
      scheduleKind: _scheduleKind,
      schedule: _cronExpr,
      interval: SubInterval(
        unit: _intervalUnit,
        value: _intervalValue < 1 ? 1 : _intervalValue,
      ),
      whitelist: _whitelistController.text.trim(),
      blacklist: _blacklistController.text.trim(),
      dependences: _dependencesController.text.trim(),
      extensions: _extensionsController.text.trim(),
      subBefore: _beforeController.text.trim(),
      subAfter: _afterController.text.trim(),
      proxy: _proxyController.text.trim(),
      autoAddCron: _autoAddCron,
      autoDelCron: _autoDelCron,
      pullType: _type == SubType.privateRepo ? _pullType : null,
      pullOption: option,
    );
  }

  // ------------------------------------------------------------------ UI

  @override
  Widget build(BuildContext context) {
    return GlassScaffold(
      title: _isEdit ? '编辑订阅' : '新建订阅',
      subtitle: '拉仓库 / 拉单文件，自动建任务',
      showBack: true,
      bottomBar: _buildSaveBar(),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(14, 4, 14, 118),
        children: [
          _buildPreview(),
          const SizedBox(height: 12),
          _buildTypeBlock(),
          const SizedBox(height: 12),
          _buildSourceBlock(),
          if (_type == SubType.privateRepo) ...[
            const SizedBox(height: 12),
            _buildCredentialBlock(),
          ],
          const SizedBox(height: 12),
          _buildScheduleBlock(),
          if (_type.isRepo) ...[
            const SizedBox(height: 12),
            _buildFilterBlock(),
          ],
          const SizedBox(height: 12),
          _buildCronBlock(),
          const SizedBox(height: 12),
          _buildAdvancedBlock(),
        ],
      ),
    );
  }

  Widget _buildPreview() {
    final scheme = Theme.of(context).colorScheme;
    final next = _scheduleKind == SubScheduleKind.crontab &&
            CronParser.isValid(_cronExpr)
        ? CronParser.nextExecution(_cronExpr)
        : null;
    return GlassCard(
      accent: scheme.primary,
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.terminal, size: 17, color: scheme.primary),
              const SizedBox(width: 6),
              const Text(
                '面板会执行',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            _build().previewCommand,
            style: TextStyle(
              fontFamily: kMonoFamily,
              fontFamilyFallback: kMonoFallback,
              fontSize: 12,
              height: 1.35,
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            _scheduleKind == SubScheduleKind.interval
                ? '拉取频率：每 ${_intervalValue < 1 ? '?' : _intervalValue} '
                    '${SubInterval.units[_intervalUnit]}'
                : next == null
                    ? '拉取频率：表达式还不合法'
                    : '下次拉取：${Formatter.dateTime(next)}',
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  Widget _buildTypeBlock() {
    return _Block(
      icon: Icons.category_outlined,
      title: '订阅什么',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final t in SubType.values)
                ChoiceChip(
                  label: Text(t.label),
                  selected: _type == t,
                  onSelected: (_) => setState(() {
                    _type = t;
                    if (t == SubType.privateRepo) {
                      _pullType ??= SubPullType.userPwd;
                    }
                    if (_aliasAuto) _syncAlias();
                  }),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Text(_type.hint, style: _hintStyle()),
        ],
      ),
    );
  }

  Widget _buildSourceBlock() {
    return _Block(
      icon: Icons.link,
      title: '地址与别名',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _urlController,
            onChanged: (_) => setState(() {
              if (_aliasAuto) _syncAlias();
            }),
            minLines: 1,
            maxLines: 3,
            style: const TextStyle(fontSize: 13.5),
            decoration: InputDecoration(
              labelText: _type == SubType.file ? '脚本文件直链' : '仓库地址',
              hintText: _type == SubType.file
                  ? 'https://raw.githubusercontent.com/…/xxx.js'
                  : 'https://github.com/owner/repo',
              isDense: true,
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _aliasController,
            onChanged: (_) => setState(() => _aliasAuto = false),
            style: const TextStyle(fontSize: 13.5),
            decoration: InputDecoration(
              labelText: '别名（唯一，日志目录名）',
              isDense: true,
              suffixIcon: IconButton(
                tooltip: '按地址重新生成',
                icon: const Icon(Icons.auto_fix_high, size: 18),
                onPressed: () => setState(() {
                  _aliasAuto = true;
                  _syncAlias();
                }),
              ),
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _nameController,
            style: const TextStyle(fontSize: 13.5),
            decoration: const InputDecoration(
              labelText: '显示名称（可留空，留空用别名）',
              isDense: true,
            ),
          ),
          if (_type.isRepo) ...[
            const SizedBox(height: 10),
            TextField(
              controller: _branchController,
              style: const TextStyle(fontSize: 13.5),
              decoration: const InputDecoration(
                labelText: '分支（留空用默认分支）',
                hintText: 'main / master',
                isDense: true,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildCredentialBlock() {
    return _Block(
      icon: Icons.lock_outline,
      title: '私有仓库凭据',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            children: [
              for (final t in SubPullType.values)
                ChoiceChip(
                  label: Text(t.label),
                  selected: _pullType == t,
                  onSelected: (_) => setState(() => _pullType = t),
                ),
            ],
          ),
          const SizedBox(height: 10),
          if (_pullType == SubPullType.sshKey)
            TextField(
              controller: _keyController,
              minLines: 3,
              maxLines: 6,
              style: const TextStyle(
                fontFamily: kMonoFamily,
                fontFamilyFallback: kMonoFallback,
                fontSize: 12,
              ),
              decoration: const InputDecoration(
                labelText: 'SSH 私钥',
                hintText: '-----BEGIN OPENSSH PRIVATE KEY-----',
                isDense: true,
              ),
            )
          else ...[
            TextField(
              controller: _userController,
              style: const TextStyle(fontSize: 13.5),
              decoration: const InputDecoration(
                labelText: '用户名',
                isDense: true,
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _passController,
              obscureText: true,
              style: const TextStyle(fontSize: 13.5),
              decoration: const InputDecoration(
                labelText: '密码 / 访问 Token',
                isDense: true,
              ),
            ),
          ],
          const SizedBox(height: 8),
          Text(
            '凭据只发给你的面板，本地不额外留存；日志与「发给 AI」都不会带上它。',
            style: _hintStyle(),
          ),
        ],
      ),
    );
  }

  Widget _buildScheduleBlock() {
    return _Block(
      icon: Icons.schedule,
      title: '多久拉一次',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            children: [
              for (final k in SubScheduleKind.values)
                ChoiceChip(
                  label: Text(k.label),
                  selected: _scheduleKind == k,
                  onSelected: (_) => setState(() => _scheduleKind = k),
                ),
            ],
          ),
          const SizedBox(height: 10),
          if (_scheduleKind == SubScheduleKind.crontab) ...[
            TextField(
              controller: _scheduleController,
              onChanged: (_) => setState(() {}),
              style: const TextStyle(
                fontFamily: kMonoFamily,
                fontFamilyFallback: kMonoFallback,
                fontSize: 13.5,
              ),
              decoration: InputDecoration(
                labelText: 'cron 表达式',
                hintText: '0 6 * * *',
                isDense: true,
                errorText: _cronExpr.isEmpty || CronParser.isValid(_cronExpr)
                    ? null
                    : '表达式不合法',
              ),
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                for (final preset in const [
                  ('每天 6 点', '0 6 * * *'),
                  ('每 12 小时', '0 */12 * * *'),
                  ('每小时', '0 * * * *'),
                  ('每周一 3 点', '0 3 * * 1'),
                ])
                  ActionChip(
                    label: Text(preset.$1, style: const TextStyle(fontSize: 12)),
                    onPressed: () => setState(() {
                      _scheduleController.text = preset.$2;
                    }),
                  ),
              ],
            ),
          ] else
            Row(
              children: [
                SizedBox(
                  width: 96,
                  child: TextField(
                    controller: _intervalController,
                    keyboardType: TextInputType.number,
                    onChanged: (_) => setState(() {}),
                    style: const TextStyle(fontSize: 13.5),
                    decoration: const InputDecoration(
                      labelText: '每',
                      isDense: true,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                DropdownButton<String>(
                  value: _intervalUnit,
                  underline: const SizedBox.shrink(),
                  items: [
                    for (final e in SubInterval.units.entries)
                      DropdownMenuItem(value: e.key, child: Text(e.value)),
                  ],
                  onChanged: (v) =>
                      setState(() => _intervalUnit = v ?? _intervalUnit),
                ),
              ],
            ),
        ],
      ),
    );
  }

  Widget _buildFilterBlock() {
    return _Block(
      icon: Icons.filter_alt_outlined,
      title: '要拉哪些文件',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _whitelistController,
            style: const TextStyle(fontSize: 13.5),
            decoration: const InputDecoration(
              labelText: '白名单（只要匹配的，逗号分隔）',
              hintText: 'jd_,jx_',
              isDense: true,
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _blacklistController,
            style: const TextStyle(fontSize: 13.5),
            decoration: const InputDecoration(
              labelText: '黑名单（排除匹配的）',
              isDense: true,
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _dependencesController,
            style: const TextStyle(fontSize: 13.5),
            decoration: const InputDecoration(
              labelText: '依赖文件（会一起拉下来）',
              hintText: 'utils,sendNotify',
              isDense: true,
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _extensionsController,
            style: const TextStyle(fontSize: 13.5),
            decoration: const InputDecoration(
              labelText: '扩展名（默认 js py sh ts）',
              hintText: 'js py',
              isDense: true,
            ),
          ),
          const SizedBox(height: 8),
          Text('留空 = 全都拉。白名单是最常用的一项：只装自己要的那几个脚本。',
              style: _hintStyle()),
        ],
      ),
    );
  }

  Widget _buildCronBlock() {
    return _Block(
      icon: Icons.playlist_add_check,
      title: '拉完之后',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            dense: true,
            value: _autoAddCron,
            onChanged: (v) => setState(() => _autoAddCron = v),
            title: const Text('自动新建定时任务', style: TextStyle(fontSize: 13.5)),
            subtitle: Text('按脚本里写的 cron 注释建任务', style: _hintStyle()),
          ),
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            dense: true,
            value: _autoDelCron,
            onChanged: (v) => setState(() => _autoDelCron = v),
            title: const Text('自动删除失效任务', style: TextStyle(fontSize: 13.5)),
            subtitle: Text('仓库里删掉的脚本，对应任务一起清掉', style: _hintStyle()),
          ),
        ],
      ),
    );
  }

  Widget _buildAdvancedBlock() {
    return _Block(
      icon: Icons.tune,
      title: '高级',
      trailing: TextButton(
        onPressed: () => setState(() => _advancedOpen = !_advancedOpen),
        child: Text(_advancedOpen ? '收起' : '展开'),
      ),
      child: _advancedOpen
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: _proxyController,
                  style: const TextStyle(fontSize: 13.5),
                  decoration: const InputDecoration(
                    labelText: '代理（拉不动 GitHub 时用）',
                    hintText: 'http://127.0.0.1:7890',
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _beforeController,
                  minLines: 1,
                  maxLines: 3,
                  style: const TextStyle(fontSize: 13.5),
                  decoration: const InputDecoration(
                    labelText: '拉取前执行的命令',
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _afterController,
                  minLines: 1,
                  maxLines: 3,
                  style: const TextStyle(fontSize: 13.5),
                  decoration: const InputDecoration(
                    labelText: '拉取后执行的命令',
                    isDense: true,
                  ),
                ),
              ],
            )
          : Text('代理、拉取前后命令。一般不用管。', style: _hintStyle()),
    );
  }

  Widget _buildSaveBar() {
    final blocker = _blocker;
    final ready = blocker.isEmpty;
    final scheme = Theme.of(context).colorScheme;
    return GlassPanel(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Row(
        children: [
          Expanded(
            child: Text(
              ready ? '准备就绪' : blocker,
              style: TextStyle(
                fontSize: 12.5,
                color: ready ? scheme.onSurfaceVariant : scheme.error,
              ),
            ),
          ),
          const SizedBox(width: 8),
          FilledButton.icon(
            onPressed: (!ready || _saving) ? null : _save,
            icon: _saving
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.check),
            label: Text(_saving ? '保存中…' : '保存'),
          ),
        ],
      ),
    );
  }

  void _syncAlias() {
    _aliasController.text = Subscription.aliasFromUrl(
      _urlController.text,
      type: _type,
    );
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await widget.onSubmit(_build());
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('保存失败：${errorText(e)}')),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  TextStyle _hintStyle() => TextStyle(
        fontSize: 12,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      );
}

/// 一块积木：图标 + 标题 + 右上操作 + 内容。
class _Block extends StatelessWidget {
  const _Block({
    required this.icon,
    required this.title,
    required this.child,
    this.trailing,
  });

  final IconData icon;
  final String title;
  final Widget child;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 18, color: Theme.of(context).colorScheme.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    fontSize: 14.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              if (trailing != null) trailing!,
            ],
          ),
          const SizedBox(height: 10),
          child,
        ],
      ),
    );
  }
}
