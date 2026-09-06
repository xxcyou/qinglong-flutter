import 'package:flutter/material.dart';

enum CronRunStatus {
  disabled('已禁用', Icons.block, null),
  idle('空闲', Icons.schedule, null),
  running('运行中', Icons.directions_run, Colors.green),
  failed('失败', Icons.error_outline, Colors.red);

  const CronRunStatus(this.label, this.icon, this.color);
  final String label;
  final IconData icon;
  final Color? color;
}

class CronStatusBadge extends StatelessWidget {
  const CronStatusBadge({
    super.key,
    required this.isDisabled,
    required this.isRunning,
    this.lastResult,
  });

  final bool isDisabled;
  final bool isRunning;
  final String? lastResult;

  CronRunStatus get status {
    if (isDisabled) return CronRunStatus.disabled;
    if (isRunning) return CronRunStatus.running;
    if (lastResult != null &&
        lastResult!.isNotEmpty &&
        lastResult != 'success') {
      return CronRunStatus.failed;
    }
    return CronRunStatus.idle;
  }

  @override
  Widget build(BuildContext context) {
    final s = status;
    final color = s.color ?? Theme.of(context).colorScheme.outline;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(s.icon, size: 14, color: color),
          const SizedBox(width: 4),
          Text(s.label, style: TextStyle(fontSize: 12, color: color)),
        ],
      ),
    );
  }
}
