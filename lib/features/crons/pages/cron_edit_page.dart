import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/llm/llm_config_provider.dart';
import '../../../core/theme/glass.dart';
import '../../../core/utils/cron_parser.dart';
import '../../../core/utils/error_text.dart';
import '../../../core/utils/formatter.dart';
import '../../../shared/glass_scaffold.dart';
import '../../panels/providers/panel_list_provider.dart';
import '../../scripts/api/script_api.dart';
import '../models/command_spec.dart';
import '../models/cron_task.dart';
import '../models/schedule_spec.dart';
import '../services/cron_ai_assist.dart';
import '../widgets/script_picker_sheet.dart';
import '../../../shared/mono_text.dart';

/// 新建/编辑定时任务：积木式可视化。
///
/// 三块积木拼一条任务：命令（执行器 + 脚本 + 参数）、定时（模式 + 时间旋钮）、
/// 名称与标签（留空就让 AI 看脚本自己写）。命令与表达式实时预览，
/// 想手写的人随时能切到自定义输入。
class CronEditPage extends ConsumerStatefulWidget {
  const CronEditPage({super.key, required this.onSubmit, this.task});

  final CronTask? task;
  final Future<void> Function(CronTask task) onSubmit;

  @override
  ConsumerState<CronEditPage> createState() => _CronEditPageState();
}

class _CronEditPageState extends ConsumerState<CronEditPage> {
  late final TextEditingController _nameController;
  late final TextEditingController _argsController;
  late final TextEditingController _rawCommandController;
  late final TextEditingController _customCronController;
  late final TextEditingController _beforeController;
  late final TextEditingController _afterController;
  late final TextEditingController _tagController;

  late CommandSpec _command;
  late ScheduleSpec _schedule;
  late List<String> _labels;

  bool _saving = false;
  bool _aiBusy = false;
  String? _aiNote;
  bool _advancedOpen = false;

  bool get _isEdit => widget.task != null;

  @override
  void initState() {
    super.initState();
    final t = widget.task;
    _command = CommandSpec.parse(t?.command ?? '');
    _schedule = ScheduleSpec.parse(t?.schedule ?? '');
    _labels = List.of(t?.labels ?? const []);
    _nameController = TextEditingController(text: t?.name ?? '');
    _argsController = TextEditingController(text: _command.args);
    _rawCommandController = TextEditingController(text: _command.raw);
    _customCronController = TextEditingController(text: _schedule.custom);
    _beforeController = TextEditingController(text: t?.taskBefore ?? '');
    _afterController = TextEditingController(text: t?.taskAfter ?? '');
    _tagController = TextEditingController();
    _advancedOpen = (t?.taskBefore?.isNotEmpty ?? false) ||
        (t?.taskAfter?.isNotEmpty ?? false);
  }

  @override
  void dispose() {
    _nameController.dispose();
    _argsController.dispose();
    _rawCommandController.dispose();
    _customCronController.dispose();
    _beforeController.dispose();
    _afterController.dispose();
    _tagController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final expr = _schedule.expression;
    final next =
        CronParser.isValid(expr) ? CronParser.nextExecution(expr) : null;
    return GlassScaffold(
      title: _isEdit ? '编辑任务' : '新建任务',
      subtitle: '拼积木，不填表',
      showBack: true,
      bottomBar: _buildSaveBar(),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(14, 4, 14, 118),
        children: [
          _PreviewCard(
            command: _command.command,
            expression: expr,
            describe: _schedule.describe(),
            next: next,
          ),
          const SizedBox(height: 12),
          _buildCommandBlock(),
          const SizedBox(height: 12),
          _buildScheduleBlock(),
          const SizedBox(height: 12),
          _buildNameBlock(),
          const SizedBox(height: 12),
          _buildAdvancedBlock(),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------- 命令积木

  Widget _buildCommandBlock() {
    return _Block(
      icon: Icons.play_circle_outline,
      title: '执行什么',
      trailing: TextButton.icon(
        onPressed: () => setState(() {
          final nextRaw = _command.useRaw ? _command.raw : _command.command;
          _command = _command.copyWith(useRaw: !_command.useRaw, raw: nextRaw);
          _rawCommandController.text = nextRaw;
        }),
        icon: Icon(
          _command.useRaw ? Icons.widgets_outlined : Icons.keyboard_outlined,
          size: 17,
        ),
        label: Text(_command.useRaw ? '回到积木' : '手写命令'),
      ),
      child: _command.useRaw
          ? TextField(
              controller: _rawCommandController,
              minLines: 2,
              maxLines: 4,
              style: const TextStyle(
                  fontFamily: kMonoFamily,
                  fontFamilyFallback: kMonoFallback,
                  fontSize: 13),
              decoration: const InputDecoration(
                hintText: 'task jd/jd_bean.js now',
                helperText: '管道、重定向、多条命令都写这里',
                border: OutlineInputBorder(),
              ),
              onChanged: (v) =>
                  setState(() => _command = _command.copyWith(raw: v)),
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('用什么跑', style: _labelStyle()),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final runner in CommandSpec.runners)
                      ChoiceChip(
                        label: Text(runner),
                        selected: _command.runner == runner,
                        onSelected: (_) => setState(
                          () => _command = _command.copyWith(runner: runner),
                        ),
                      ),
                    if (!CommandSpec.runners.contains(_command.runner))
                      ChoiceChip(
                        label: Text(_command.runner),
                        selected: true,
                        onSelected: (_) {},
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                Text('跑哪个脚本', style: _labelStyle()),
                const SizedBox(height: 6),
                InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: _pickScript,
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 12),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: Theme.of(context).colorScheme.outlineVariant,
                      ),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.description_outlined, size: 18),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            _command.script.isEmpty
                                ? '点这里从面板脚本里选一个'
                                : _command.script,
                            style: TextStyle(
                              fontFamily:
                                  _command.script.isEmpty ? null : kMonoFamily,
                              fontSize: 13,
                              color: _command.script.isEmpty
                                  ? Theme.of(context)
                                      .colorScheme
                                      .onSurfaceVariant
                                  : null,
                            ),
                          ),
                        ),
                        const Icon(Icons.unfold_more, size: 18),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Text('额外参数（可留空）', style: _labelStyle()),
                const SizedBox(height: 6),
                TextField(
                  controller: _argsController,
                  style: const TextStyle(
                      fontFamily: kMonoFamily,
                      fontFamilyFallback: kMonoFallback,
                      fontSize: 13),
                  decoration: const InputDecoration(
                    isDense: true,
                    hintText: 'now',
                    border: OutlineInputBorder(),
                  ),
                  onChanged: (v) =>
                      setState(() => _command = _command.copyWith(args: v)),
                ),
              ],
            ),
    );
  }

  Future<void> _pickScript() async {
    final picked = await ScriptPickerSheet.show(context);
    if (picked == null || !mounted) return;
    setState(() => _command = _command.copyWith(script: picked));
  }

  // ---------------------------------------------------------------- 定时积木

  Widget _buildScheduleBlock() {
    return _Block(
      icon: Icons.schedule,
      title: '什么时候跑',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final mode in ScheduleMode.values)
                ChoiceChip(
                  label: Text(mode.label),
                  selected: _schedule.mode == mode,
                  onSelected: (_) => setState(
                    () => _schedule = _schedule.copyWith(mode: mode),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 12),
          ..._buildScheduleKnobs(),
        ],
      ),
    );
  }

  List<Widget> _buildScheduleKnobs() {
    switch (_schedule.mode) {
      case ScheduleMode.everyNMinutes:
        return [
          _NumberSlider(
            label: '间隔分钟',
            value: _schedule.everyMinutes,
            min: 1,
            max: 59,
            onChanged: (v) =>
                setState(() => _schedule = _schedule.copyWith(everyMinutes: v)),
          ),
        ];
      case ScheduleMode.hourly:
        return [
          _NumberSlider(
            label: '每小时的第几分钟',
            value: _schedule.minute,
            min: 0,
            max: 59,
            onChanged: (v) =>
                setState(() => _schedule = _schedule.copyWith(minute: v)),
          ),
        ];
      case ScheduleMode.interval:
        return [
          _NumberSlider(
            label: '间隔小时',
            value: _schedule.everyHours,
            min: 1,
            max: 23,
            onChanged: (v) =>
                setState(() => _schedule = _schedule.copyWith(everyHours: v)),
          ),
          _NumberSlider(
            label: '第几分钟',
            value: _schedule.minute,
            min: 0,
            max: 59,
            onChanged: (v) =>
                setState(() => _schedule = _schedule.copyWith(minute: v)),
          ),
        ];
      case ScheduleMode.daily:
        return [_buildTimePicker()];
      case ScheduleMode.weekly:
        return [
          Text('星期几', style: _labelStyle()),
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (var i = 0; i < 7; i++)
                FilterChip(
                  label: Text(const ['日', '一', '二', '三', '四', '五', '六'][i]),
                  selected: _schedule.weekdays.contains(i),
                  onSelected: (on) {
                    final next = {..._schedule.weekdays};
                    if (on) {
                      next.add(i);
                    } else if (next.length > 1) {
                      // 至少留一天，否则表达式会退化成非法值。
                      next.remove(i);
                    }
                    setState(
                      () => _schedule = _schedule.copyWith(weekdays: next),
                    );
                  },
                ),
            ],
          ),
          const SizedBox(height: 10),
          _buildTimePicker(),
        ];
      case ScheduleMode.monthly:
        return [
          _NumberSlider(
            label: '每月几号',
            value: _schedule.monthDay,
            min: 1,
            max: 31,
            onChanged: (v) =>
                setState(() => _schedule = _schedule.copyWith(monthDay: v)),
          ),
          _buildTimePicker(),
        ];
      case ScheduleMode.custom:
        return [
          TextField(
            controller: _customCronController,
            style: const TextStyle(
                fontFamily: kMonoFamily,
                fontFamilyFallback: kMonoFallback,
                fontSize: 13),
            decoration: const InputDecoration(
              isDense: true,
              hintText: '30 8 * * *',
              helperText: '支持 5/6/7 段，提交时自动补秒位',
              border: OutlineInputBorder(),
            ),
            onChanged: (v) =>
                setState(() => _schedule = _schedule.copyWith(custom: v)),
          ),
        ];
    }
  }

  /// 时间点用系统时间选择器，比两个数字输入框快。
  Widget _buildTimePicker() {
    final text = '${_schedule.hour.toString().padLeft(2, '0')}'
        ':${_schedule.minute.toString().padLeft(2, '0')}';
    return Row(
      children: [
        Text('执行时刻', style: _labelStyle()),
        const Spacer(),
        GlassPill(
          icon: Icons.access_time,
          label: text,
          onTap: () async {
            final picked = await showTimePicker(
              context: context,
              initialTime:
                  TimeOfDay(hour: _schedule.hour, minute: _schedule.minute),
            );
            if (picked == null) return;
            setState(
              () => _schedule = _schedule.copyWith(
                hour: picked.hour,
                minute: picked.minute,
              ),
            );
          },
        ),
      ],
    );
  }

  // ------------------------------------------------------------ 名称与标签

  Widget _buildNameBlock() {
    return _Block(
      icon: Icons.label_outline,
      title: '叫什么',
      trailing: TextButton.icon(
        onPressed: _aiBusy ? null : () => _askAi(),
        icon: _aiBusy
            ? const SizedBox(
                width: 15,
                height: 15,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.auto_awesome, size: 17),
        label: Text(_aiBusy ? '想名字…' : 'AI 起名'),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _nameController,
            decoration: const InputDecoration(
              isDense: true,
              hintText: '留空就让 AI 看脚本自己起',
              border: OutlineInputBorder(),
            ),
            onChanged: (_) => setState(() {}),
          ),
          if (_aiNote != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                _aiNote!,
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          const SizedBox(height: 12),
          Text('标签（留空 AI 也会补）', style: _labelStyle()),
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final tag in _labels)
                InputChip(
                  label: Text(tag),
                  onDeleted: () => setState(() => _labels.remove(tag)),
                ),
              ActionChip(
                avatar: const Icon(Icons.add, size: 16),
                label: const Text('加标签'),
                onPressed: _addTagDialog,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _addTagDialog() async {
    _tagController.clear();
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('添加标签'),
        content: TextField(
          controller: _tagController,
          autofocus: true,
          decoration: const InputDecoration(hintText: '签到 / 通知 / 清理'),
          onSubmitted: (v) => Navigator.of(context).pop(v.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.of(context).pop(_tagController.text.trim()),
            child: const Text('添加'),
          ),
        ],
      ),
    );
    if (value == null || value.isEmpty) return;
    setState(() {
      if (!_labels.contains(value)) _labels.add(value);
    });
  }

  /// AI 起名/打标签：读脚本内容当上下文，读不到就只凭命令猜。
  ///
  /// [silent] 为真时是保存前的自动补全，只补空着的字段，不弹提示。
  Future<void> _askAi({bool silent = false}) async {
    final command = _command.command;
    if (command.isEmpty) {
      if (!silent) _toast('先选好脚本，AI 才知道这任务在干什么');
      return;
    }
    setState(() {
      _aiBusy = true;
      _aiNote = null;
    });
    try {
      final config = await ref.read(llmConfigProvider.future);
      var content = '';
      final script = _command.useRaw ? '' : _command.script;
      if (script.isNotEmpty) {
        try {
          final panel = ref.read(currentPanelProvider);
          if (panel != null) {
            content = await ScriptApi.read(
              apiBaseUrl: panel.apiBaseUrl,
              file: script,
            );
          }
        } catch (_) {
          // 读不到脚本不算错误，AI 仍可根据命令名猜个大概。
        }
      }
      final nameEmpty = _nameController.text.trim().isEmpty;
      final labelsEmpty = _labels.isEmpty;
      final wantName = silent ? nameEmpty : true;
      final wantLabels = silent ? labelsEmpty : true;
      final suggestion = await CronAiAssist.suggest(
        config: config,
        command: command,
        schedule: _schedule.expression,
        scriptContent: content,
        needName: wantName,
        needLabels: wantLabels,
      );
      if (!mounted) return;
      if (suggestion.isEmpty) {
        setState(() => _aiNote = 'AI 没给出建议，可手动填写');
        return;
      }
      setState(() {
        if (wantName && suggestion.name.isNotEmpty) {
          _nameController.text = suggestion.name;
        }
        if (wantLabels) {
          for (final l in suggestion.labels) {
            if (!_labels.contains(l)) _labels.add(l);
          }
        }
        _aiNote = 'AI 已填好，可以直接改';
      });
    } catch (e) {
      if (mounted) setState(() => _aiNote = 'AI 调用失败：${errorText(e)}');
    } finally {
      if (mounted) setState(() => _aiBusy = false);
    }
  }

  // ---------------------------------------------------------------- 高级项

  Widget _buildAdvancedBlock() {
    return _Block(
      icon: Icons.settings_outlined,
      title: '前后置命令（可选）',
      trailing: IconButton(
        onPressed: () => setState(() => _advancedOpen = !_advancedOpen),
        icon: Icon(_advancedOpen ? Icons.expand_less : Icons.expand_more),
      ),
      child: _advancedOpen
          ? Column(
              children: [
                TextField(
                  controller: _beforeController,
                  style: const TextStyle(
                      fontFamily: kMonoFamily,
                      fontFamilyFallback: kMonoFallback,
                      fontSize: 13),
                  decoration: const InputDecoration(
                    isDense: true,
                    labelText: '前置命令',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _afterController,
                  style: const TextStyle(
                      fontFamily: kMonoFamily,
                      fontFamilyFallback: kMonoFallback,
                      fontSize: 13),
                  decoration: const InputDecoration(
                    isDense: true,
                    labelText: '后置命令',
                    border: OutlineInputBorder(),
                  ),
                ),
              ],
            )
          : Text(
              '任务开始前 / 结束后要跑的命令，绝大多数任务不需要',
              style: _labelStyle(),
            ),
    );
  }

  // ---------------------------------------------------------------- 保存

  Widget _buildSaveBar() {
    final ready = _command.isValid && _schedule.isValid;
    final scheme = Theme.of(context).colorScheme;
    return GlassPanel(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Row(
        children: [
          Expanded(
            child: Text(
              ready
                  ? (_nameController.text.trim().isEmpty
                      ? '名称留空 → 保存时 AI 自动生成'
                      : '准备就绪')
                  : (!_command.isValid ? '还没选脚本 / 填命令' : '定时表达式不合法'),
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

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      // 名称/标签留空就先让 AI 补一次；AI 挂了也不能挡住保存，用脚本名兜底。
      if (_nameController.text.trim().isEmpty || _labels.isEmpty) {
        await _askAi(silent: true);
      }
      var name = _nameController.text.trim();
      if (name.isEmpty) {
        final script = _command.useRaw ? _command.raw : _command.script;
        final base = script.split('/').last.trim();
        name = base.isEmpty ? '未命名任务' : base;
      }
      final task = CronTask(
        id: widget.task?.id,
        name: name,
        command: _command.command,
        // 面板只认 6 段：5 段自动补秒，从根上消灭 400。
        schedule: CronParser.normalizeForQinglong(_schedule.expression),
        labels: _labels,
        isDisabled: widget.task?.isDisabled ?? false,
        isPinned: widget.task?.isPinned ?? false,
        taskBefore: _beforeController.text.trim().isEmpty
            ? null
            : _beforeController.text.trim(),
        taskAfter: _afterController.text.trim().isEmpty
            ? null
            : _afterController.text.trim(),
      );
      await widget.onSubmit(task);
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) _toast('保存失败：${errorText(e)}');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _toast(String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  TextStyle _labelStyle() => TextStyle(
        fontSize: 12.5,
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
              Icon(icon,
                  size: 18, color: Theme.of(context).colorScheme.primary),
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

/// 实时预览：拼出来的命令、cron 表达式、人话描述、下一次执行时间。
class _PreviewCard extends StatelessWidget {
  const _PreviewCard({
    required this.command,
    required this.expression,
    required this.describe,
    required this.next,
  });

  final String command;
  final String expression;
  final String describe;
  final DateTime? next;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return GlassPanel(
      radius: 20,
      blur: Glass.blurStrong,
      shadowY: 8,
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.visibility_outlined, size: 17, color: scheme.primary),
              const SizedBox(width: 6),
              const Text(
                '实时预览',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
              ),
            ],
          ),
          const SizedBox(height: 8),
          SelectableText(
            command.isEmpty ? '（还没拼出命令）' : command,
            style: TextStyle(
              fontFamily: kMonoFamily,
              fontFamilyFallback: kMonoFallback,
              fontSize: 13,
              color: command.isEmpty ? scheme.error : null,
            ),
          ),
          const SizedBox(height: 6),
          SelectableText(
            expression.isEmpty ? '（表达式为空）' : expression,
            style: const TextStyle(
                fontFamily: kMonoFamily,
                fontFamilyFallback: kMonoFallback,
                fontSize: 12.5),
          ),
          const SizedBox(height: 4),
          Text(
            describe,
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
          ),
          if (next != null)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                '下一次：${Formatter.dateTime(next)}',
                style: TextStyle(fontSize: 12, color: scheme.primary),
              ),
            ),
        ],
      ),
    );
  }
}

/// 数字旋钮：滑条 + 左右微调，手指点得准。
class _NumberSlider extends StatelessWidget {
  const _NumberSlider({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
  });

  final String label;
  final int value;
  final int min;
  final int max;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              label,
              style: TextStyle(
                fontSize: 12.5,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const Spacer(),
            IconButton(
              visualDensity: VisualDensity.compact,
              onPressed: value > min ? () => onChanged(value - 1) : null,
              icon: const Icon(Icons.remove_circle_outline, size: 19),
            ),
            Text(
              '$value',
              style: const TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w700,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
            IconButton(
              visualDensity: VisualDensity.compact,
              onPressed: value < max ? () => onChanged(value + 1) : null,
              icon: const Icon(Icons.add_circle_outline, size: 19),
            ),
          ],
        ),
        Slider(
          value: value.clamp(min, max).toDouble(),
          min: min.toDouble(),
          max: max.toDouble(),
          divisions: max - min,
          label: '$value',
          onChanged: (v) => onChanged(v.round()),
        ),
      ],
    );
  }
}
