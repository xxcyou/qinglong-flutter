import 'dart:convert';

import '../../../core/llm/llm_client.dart';
import '../../../core/utils/logger.dart';

/// AI 给定时任务起名字 / 打标签的结果。
class CronAiSuggestion {
  const CronAiSuggestion({this.name = '', this.labels = const []});

  final String name;
  final List<String> labels;

  bool get isEmpty => name.isEmpty && labels.isEmpty;
}

/// 「名字留空 AI 自己看脚本生成名字，标签也是」——这里就是那个 AI。
///
/// 只做一次非流式补全，失败就返回空，让调用方回落到本地兜底命名，
/// 绝不因为 AI 不可用就卡住新建流程。
class CronAiAssist {
  const CronAiAssist._();

  static Future<CronAiSuggestion> suggest({
    required LlmConfig config,
    required String command,
    required String schedule,
    String scriptContent = '',
    bool needName = true,
    bool needLabels = true,
  }) async {
    if (!config.isConfigured) return const CronAiSuggestion();
    if (!needName && !needLabels) return const CronAiSuggestion();

    // 脚本可能很长，掐到前 4000 字符就够判断它在干什么了。
    final snippet = scriptContent.length > 4000
        ? scriptContent.substring(0, 4000)
        : scriptContent;

    final want = [
      if (needName) '"name": "不超过 12 个中文字的任务名"',
      if (needLabels) '"labels": ["1-3 个短标签"]',
    ].join(', ');

    final messages = [
      const LlmMessage(
        role: 'system',
        content: '你给青龙面板的定时任务起名和打标签。'
            '只输出一个 JSON 对象，不要代码块、不要解释。'
            '名字用中文、具体说明这个任务在做什么，不要出现"脚本""任务"这种废话词。'
            '标签是分类词（如 签到、通知、清理、京东），不要重复名字。',
      ),
      LlmMessage(
        role: 'user',
        content: '执行命令：$command\n'
            '定时：$schedule\n'
            '${snippet.isEmpty ? '（脚本内容不可读）' : '脚本内容片段：\n$snippet'}\n\n'
            '输出 JSON：{$want}',
      ),
    ];

    try {
      final response = await LlmClient.complete(
        config: config,
        messages: messages,
        maxRetries: 1,
      );
      return _parse(response.content,
          needName: needName, needLabels: needLabels);
    } catch (e) {
      Logger.e('cron', 'ai suggest failed', e);
      return const CronAiSuggestion();
    }
  }

  /// 模型经常裹一层 ```json 或前后加话，这里只挑第一个 JSON 对象。
  static CronAiSuggestion _parse(
    String raw, {
    required bool needName,
    required bool needLabels,
  }) {
    final start = raw.indexOf('{');
    final end = raw.lastIndexOf('}');
    if (start < 0 || end <= start) return const CronAiSuggestion();
    try {
      final map = jsonDecode(raw.substring(start, end + 1));
      if (map is! Map) return const CronAiSuggestion();
      final name = needName ? (map['name']?.toString().trim() ?? '') : '';
      final labels = <String>[];
      if (needLabels) {
        final rawLabels = map['labels'];
        if (rawLabels is List) {
          for (final l in rawLabels) {
            final text = l.toString().trim();
            if (text.isNotEmpty && !labels.contains(text)) labels.add(text);
          }
        } else if (rawLabels is String && rawLabels.trim().isNotEmpty) {
          labels.add(rawLabels.trim());
        }
      }
      return CronAiSuggestion(name: name, labels: labels.take(3).toList());
    } catch (e) {
      return const CronAiSuggestion();
    }
  }
}
