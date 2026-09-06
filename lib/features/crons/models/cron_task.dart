class CronTask {
  const CronTask({
    this.id,
    this.name = '',
    this.command = '',
    this.schedule = '',
    this.labels = const [],
    this.isDisabled = false,
    this.isPinned = false,
    this.subId,
    this.extraSchedules = const [],
    this.taskBefore,
    this.taskAfter,
    this.lastRunTime,
    this.lastExecutionTime,
    this.lastResult,
    this.pid,
    this.logPath,
  });

  final int? id;
  final String name;
  final String command;
  final String schedule;
  final List<String> labels;
  final bool isDisabled;
  final bool isPinned;
  final int? subId;
  final List<String> extraSchedules;
  final String? taskBefore;
  final String? taskAfter;
  final DateTime? lastRunTime;
  final DateTime? lastExecutionTime;
  final String? lastResult;
  final int? pid;
  final String? logPath;

  factory CronTask.fromJson(Map<String, dynamic> json) {
    DateTime? parseTime(dynamic v) {
      if (v == null) return null;
      if (v is int) return DateTime.fromMillisecondsSinceEpoch(v * 1000);
      return DateTime.tryParse(v.toString());
    }

    List<String> parseList(dynamic v) {
      if (v is List) {
        return v.map((e) => e.toString()).toList();
      }
      return const [];
    }

    bool? asBool(dynamic v) {
      if (v == null) return null;
      if (v is bool) return v;
      if (v is int) return v != 0;
      if (v is String) {
        final t = v.trim().toLowerCase();
        return t == '1' || t == 'true';
      }
      return null;
    }

    int? asInt(dynamic v) {
      if (v == null) return null;
      if (v is int) return v;
      if (v is num) return v.toInt();
      if (v is String) return int.tryParse(v.trim());
      return null;
    }

    return CronTask(
      id: asInt(json['id']),
      name: json['name'] as String? ?? '',
      command: json['command'] as String? ?? '',
      schedule: json['schedule'] as String? ?? '',
      labels: parseList(json['labels']),
      isDisabled: asBool(json['isDisabled']) ?? false,
      isPinned: asBool(json['isPinned']) ?? false,
      subId: asInt(json['subId']),
      extraSchedules: parseList(json['extraSchedules']),
      taskBefore:
          json['task_before'] as String? ?? json['taskBefore'] as String?,
      taskAfter: json['task_after'] as String? ?? json['taskAfter'] as String?,
      lastRunTime: parseTime(json['lastRunTime']),
      lastExecutionTime: parseTime(json['lastExecutionTime']),
      lastResult: json['lastResult'] as String?,
      pid: asInt(json['pid']),
      logPath: json['log_path'] as String? ?? json['logPath'] as String?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'command': command,
      'schedule': schedule,
      'labels': labels,
      'isDisabled': isDisabled,
      'isPinned': isPinned,
      'extraSchedules': extraSchedules,
      'task_before': taskBefore,
      'task_after': taskAfter,
    };
  }

  CronTask copyWith({
    int? id,
    String? name,
    String? command,
    String? schedule,
    List<String>? labels,
    bool? isDisabled,
    bool? isPinned,
    int? subId,
    List<String>? extraSchedules,
    String? taskBefore,
    String? taskAfter,
    DateTime? lastRunTime,
    DateTime? lastExecutionTime,
    String? lastResult,
    int? pid,
    String? logPath,
  }) {
    return CronTask(
      id: id ?? this.id,
      name: name ?? this.name,
      command: command ?? this.command,
      schedule: schedule ?? this.schedule,
      labels: labels ?? this.labels,
      isDisabled: isDisabled ?? this.isDisabled,
      isPinned: isPinned ?? this.isPinned,
      subId: subId ?? this.subId,
      extraSchedules: extraSchedules ?? this.extraSchedules,
      taskBefore: taskBefore ?? this.taskBefore,
      taskAfter: taskAfter ?? this.taskAfter,
      lastRunTime: lastRunTime ?? this.lastRunTime,
      lastExecutionTime: lastExecutionTime ?? this.lastExecutionTime,
      lastResult: lastResult ?? this.lastResult,
      pid: pid ?? this.pid,
      logPath: logPath ?? this.logPath,
    );
  }
}

class CronPageResult {
  const CronPageResult({required this.items, required this.total});

  final List<CronTask> items;
  final int total;
}
