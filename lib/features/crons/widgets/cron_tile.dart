import 'package:flutter/material.dart';
import 'package:flutter_slidable/flutter_slidable.dart';

import '../../../core/theme/glass.dart';
import '../../../core/utils/cron_parser.dart';
import '../../../core/utils/formatter.dart';
import '../../../shared/glass_scaffold.dart';
import '../models/cron_task.dart';
import 'cron_status_badge.dart';
import '../../../shared/mono_text.dart';

class CronTile extends StatelessWidget {
  const CronTile({
    super.key,
    required this.task,
    required this.selected,
    required this.onTap,
    required this.onLongPress,
    required this.onRun,
    required this.onStop,
    required this.onLog,
    required this.onDelete,
    required this.onSendToAi,
    this.onOpenScript,
  });

  final CronTask task;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final VoidCallback onRun;
  final VoidCallback onStop;
  final VoidCallback onLog;
  final VoidCallback onDelete;
  final VoidCallback onSendToAi;
  final VoidCallback? onOpenScript;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDisabled = task.isDisabled;
    final next = CronParser.nextExecution(task.schedule);
    final lastDuration = _lastExecutionDuration(task);

    return Slidable(
      key: ValueKey('cron_${task.id}'),
      endActionPane: ActionPane(
        motion: const DrawerMotion(),
        extentRatio: 0.28,
        children: [
          SlidableAction(
            onPressed: (_) => onDelete(),
            backgroundColor: scheme.error,
            foregroundColor: scheme.onError,
            icon: Icons.delete_outline,
            label: '删除',
          ),
        ],
      ),
      child: GlassCard(
        selected: selected,
        onTap: onTap,
        onLongPress: onLongPress,
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                if (task.isPinned) ...[
                  Icon(Icons.push_pin, size: 18, color: scheme.primary),
                  const SizedBox(width: 4),
                ],
                Expanded(
                  child: Text(
                    task.name,
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      decoration:
                          isDisabled ? TextDecoration.lineThrough : null,
                      color: isDisabled ? scheme.onSurfaceVariant : null,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 8),
                CronStatusBadge(
                  isDisabled: task.isDisabled,
                  isRunning: task.pid != null && task.pid != 0,
                  lastResult: task.lastResult,
                ),
              ],
            ),
            const SizedBox(height: 8),
            InkWell(
              onTap: onOpenScript,
              borderRadius: BorderRadius.circular(6),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Text(
                  task.command,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: kMonoFamily,
                    fontFamilyFallback: kMonoFallback,
                    fontSize: 13,
                    color: onOpenScript == null
                        ? scheme.onSurfaceVariant
                        : scheme.primary,
                    decoration:
                        onOpenScript == null ? null : TextDecoration.underline,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            _InfoLine(
              icon: Icons.timer_outlined,
              text: _cronHumanText(task.schedule),
            ),
            const SizedBox(height: 4),
            _InfoLine(
              icon: Icons.event_outlined,
              text:
                  '下次执行：${next == null ? '暂无可计算时间' : Formatter.dateTime(next)}',
            ),
            if (lastDuration != null) ...[
              const SizedBox(height: 4),
              _InfoLine(
                icon: Icons.bolt,
                text: '上次耗时：$lastDuration',
              ),
            ],
            if (task.labels.isNotEmpty) ...[
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                runSpacing: 4,
                children: [
                  for (final label in task.labels)
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(
                        color: scheme.secondaryContainer.withValues(alpha: 0.6),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        label,
                        style: TextStyle(
                            fontSize: 12, color: scheme.onSecondaryContainer),
                      ),
                    ),
                ],
              ),
            ],
            const SizedBox(height: 8),
            Wrap(
              spacing: 4,
              runSpacing: 4,
              children: [
                GlassPill(
                  icon: Icons.auto_awesome,
                  tooltip: '发给 AI',
                  onTap: onSendToAi,
                  dense: true,
                ),
                GlassPill(
                  icon: Icons.play_arrow,
                  tooltip: '运行',
                  onTap: onRun,
                  dense: true,
                ),
                GlassPill(
                  icon: Icons.stop,
                  tooltip: '停止',
                  onTap: onStop,
                  dense: true,
                ),
                GlassPill(
                  icon: Icons.article_outlined,
                  tooltip: '日志',
                  onTap: onLog,
                  dense: true,
                ),
                if (onOpenScript != null)
                  GlassPill(
                    icon: Icons.code,
                    tooltip: '打开脚本',
                    onTap: onOpenScript,
                    dense: true,
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _InfoLine extends StatelessWidget {
  const _InfoLine({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 1),
          child: Icon(icon, size: 14, color: scheme.outline),
        ),
        const SizedBox(width: 4),
        Expanded(
          child: Text(
            text,
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}

/// 根据两个时间戳估算“最后执行耗时”。模型里没有明确耗时字段时返回 null。
String? _lastExecutionDuration(CronTask task) {
  final start = task.lastRunTime;
  final end = task.lastExecutionTime;
  if (start == null || end == null) return null;
  final duration = end.difference(start);
  if (duration.isNegative) return null;
  return Formatter.durationMs(duration.inMilliseconds);
}

/// 尽量把 Cron 表达式翻译成中文自然语言；无法识别时原样返回。
String _cronHumanText(String schedule) {
  var parts = schedule.trim().split(RegExp(r'\s+'));
  if (parts.length == 6) parts = parts.sublist(1);
  if (parts.length != 5) return schedule;

  final minute = parts[0];
  final hour = parts[1];
  final day = parts[2];
  final month = parts[3];
  final week = parts[4];
  final dayAny = day == '*' || day == '?';
  final monthAny = month == '*' || month == '?';
  final weekAny = week == '*' || week == '?';

  if (minute == '*' && hour == '*') {
    return '每分钟';
  }
  if (minute == '0' && hour == '*') {
    return '每小时';
  }
  if (minute.startsWith('*/') && hour == '*') {
    final step = minute.substring(2);
    if (int.tryParse(step) != null) return '每 $step 分钟';
  }
  if ((minute == '0' || minute == '?') &&
      hour.startsWith('*/') &&
      dayAny &&
      monthAny &&
      weekAny) {
    final step = hour.substring(2);
    if (int.tryParse(step) != null) return '每 $step 小时';
  }

  final timeText = _cronTimeText(minute, hour);
  if (timeText != null) {
    if (dayAny && monthAny && weekAny) {
      return '每天 $timeText';
    }
    if (!weekAny && dayAny && monthAny) {
      return '每周${_cronWeekText(week)} $timeText';
    }
    if (!dayAny && monthAny && weekAny) {
      return '每月${_cronDayText(day)} $timeText';
    }
    if (!dayAny && !monthAny && weekAny) {
      return '每年${_cronMonthText(month)}${_cronDayText(day)} $timeText';
    }
    return timeText;
  }

  return schedule;
}

String? _cronTimeText(String minute, String hour) {
  final m = int.tryParse(minute);
  final h = int.tryParse(hour);
  if (m == null || h == null) return null;
  return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}';
}

String _cronWeekText(String week) {
  const names = ['周日', '周一', '周二', '周三', '周四', '周五', '周六'];

  String one(String v) {
    final i = _weekIndex(v);
    return i == null ? v : names[i];
  }

  if (week.contains(',')) {
    return week.split(',').map(one).join('、');
  }
  if (week.contains('-')) {
    final parts = week.split('-');
    if (parts.length == 2) {
      final a = _weekIndex(parts[0]);
      final b = _weekIndex(parts[1]);
      if (a != null && b != null) return '${names[a]}至${names[b]}';
    }
  }
  return one(week);
}

int? _weekIndex(String value) {
  final n = int.tryParse(value.trim());
  if (n == null) return null;
  if (n == 7) return 0;
  if (n >= 0 && n <= 6) return n;
  return null;
}

String _cronDayText(String day) {
  if (day.startsWith('*/')) return '每 ${day.substring(2)} 日';
  if (day.contains(',')) {
    return day.split(',').map((e) => '${e.trim()} 日').join('、');
  }
  if (day.contains('-')) {
    final parts = day.split('-');
    if (parts.length == 2) return '${parts[0].trim()} 日至 ${parts[1].trim()} 日';
  }
  return '$day 日';
}

String _cronMonthText(String month) {
  if (month.startsWith('*/')) return '每 ${month.substring(2)} 月';
  if (month.contains(',')) {
    return month.split(',').map((e) => '${e.trim()} 月').join('、');
  }
  if (month.contains('-')) {
    final parts = month.split('-');
    if (parts.length == 2) return '${parts[0].trim()} 月至 ${parts[1].trim()} 月';
  }
  return '$month 月';
}
