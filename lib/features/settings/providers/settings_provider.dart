import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/network/dio_client.dart';

/// 全局设置的状态。
class AppSettings {
  const AppSettings({
    this.themeMode = ThemeMode.system,
    this.pollIntervalSeconds = 3,
    this.logPollIntervalSeconds = 2,
    this.languageCode = 'zh',
    this.llmBaseUrl = '',
    this.llmModel = '',
    this.llmApiKey = '',
    this.allowSelfSigned = false,
    this.debugLogEnabled = true,
    this.llmTemperature,
    this.llmTopP,
    this.llmMaxTokens,
    this.llmFrequencyPenalty,
    this.llmPresencePenalty,
    this.llmTimeoutSeconds = 180,
    this.llmExtraBody = '',
    this.llmExtraHeaders = '',
    this.llmDefaultContextLimit = 8000,
    this.autoStartTerminal = false,
    this.startupTabIndex = 2,
    this.logPollMillis = 500,
    this.terminalPalette = 'one_dark',
    this.terminalFontSize = 13,
    this.terminalLineHeight = 1.25,
    this.terminalCommandHighlight = true,
    this.cachedModels = const [],
    this.modelsFetchedAt,
  });

  final ThemeMode themeMode;
  final int pollIntervalSeconds;
  final int logPollIntervalSeconds;

  /// 日志自动刷新间隔（毫秒）。
  ///
  /// 秒为单位太粗：跑脚本时想看实时输出，1 秒一跳已经明显发涩，
  /// 所以改成毫秒，默认 500ms。
  final int logPollMillis;

  /// 手动获取并缓存下来的模型列表。
  ///
  /// AI 页不再自己去拉模型列表——每次进页面都发一次请求既慢又容易
  /// 在没网时弹一堆"获取模型列表失败"。改成只在设置页手动获取一次，
  /// 缓存起来给 AI 页选。
  final List<String> cachedModels;

  /// 上次手动获取模型列表的时间。
  final DateTime? modelsFetchedAt;
  final String languageCode;

  /// 老的单份 AI 连接配置。
  ///
  /// 上了多提供商之后这几项**只剩迁移用途**：首次启动时 [LlmRegistry] 会把
  /// 它们搬成一家提供商，之后连接参数一律读提供商那边。
  /// 别再往这里写新逻辑——写了也不会有人读。
  final String llmBaseUrl;
  final String llmModel;
  final String llmApiKey;
  final bool allowSelfSigned;
  final bool debugLogEnabled;

  /// 采样参数：null = 不发该字段，用服务端默认。
  final double? llmTemperature;
  final double? llmTopP;
  final int? llmMaxTokens;
  final double? llmFrequencyPenalty;
  final double? llmPresencePenalty;

  /// 单次请求接收超时（秒）。Agent 里一轮可能思考很久，默认放宽到 180。
  final int llmTimeoutSeconds;

  /// 透传给接口的额外 body / headers，JSON 文本形式保存，方便对接私有网关。
  final String llmExtraBody;
  final String llmExtraHeaders;

  /// 新模型没有实测上下文长度时的默认值。
  final int llmDefaultContextLimit;

  /// 启动 APP 时自动拉起 Debian 终端（仅在 Runtime 已安装时生效，
  /// 绝不会自动触发 150MB 下载）。
  final bool autoStartTerminal;

  /// 打开 APP 落在哪个标签页（0 任务 / 1 面板 / 2 AI / 3 终端 / 4 管理 / 5 设置）。
  /// 默认 AI —— 这个 APP 的主入口就是 AI，让用户少点一次。
  final int startupTabIndex;

  /// 终端配色方案 id（见 TerminalPalette.all）。
  final String terminalPalette;

  /// 终端字号。手机屏窄，13 是"一行 80 列刚好不折"的平衡点。
  final double terminalFontSize;

  /// 终端行高倍数。1.0 太挤，1.25 读日志最舒服。
  final double terminalLineHeight;

  /// 命令输入框是否做 shell 语法高亮。
  final bool terminalCommandHighlight;

  /// 解析额外 JSON，坏了就当空——配置错不该让对话直接不可用。
  Map<String, dynamic> get extraBodyMap => _decodeMap(llmExtraBody);

  Map<String, String> get extraHeaderMap => {
        for (final e in _decodeMap(llmExtraHeaders).entries)
          e.key: e.value.toString(),
      };

  static Map<String, dynamic> _decodeMap(String raw) {
    final text = raw.trim();
    if (text.isEmpty) return const {};
    try {
      final decoded = jsonDecode(text);
      return decoded is Map<String, dynamic> ? decoded : const {};
    } catch (_) {
      return const {};
    }
  }

  AppSettings copyWith({
    ThemeMode? themeMode,
    int? pollIntervalSeconds,
    int? logPollIntervalSeconds,
    int? logPollMillis,
    List<String>? cachedModels,
    DateTime? modelsFetchedAt,
    String? languageCode,
    String? llmBaseUrl,
    String? llmModel,
    String? llmApiKey,
    bool? allowSelfSigned,
    bool? debugLogEnabled,
    double? llmTemperature,
    double? llmTopP,
    int? llmMaxTokens,
    double? llmFrequencyPenalty,
    double? llmPresencePenalty,
    int? llmTimeoutSeconds,
    String? llmExtraBody,
    String? llmExtraHeaders,
    int? llmDefaultContextLimit,
    bool? autoStartTerminal,
    int? startupTabIndex,
    String? terminalPalette,
    double? terminalFontSize,
    double? terminalLineHeight,
    bool? terminalCommandHighlight,
    // 采样参数需要"清空"语义，单独给显式清除开关。
    bool clearTemperature = false,
    bool clearTopP = false,
    bool clearMaxTokens = false,
    bool clearFrequencyPenalty = false,
    bool clearPresencePenalty = false,
  }) {
    return AppSettings(
      themeMode: themeMode ?? this.themeMode,
      pollIntervalSeconds: pollIntervalSeconds ?? this.pollIntervalSeconds,
      logPollIntervalSeconds:
          logPollIntervalSeconds ?? this.logPollIntervalSeconds,
      logPollMillis: logPollMillis ?? this.logPollMillis,
      cachedModels: cachedModels ?? this.cachedModels,
      modelsFetchedAt: modelsFetchedAt ?? this.modelsFetchedAt,
      autoStartTerminal: autoStartTerminal ?? this.autoStartTerminal,
      startupTabIndex: startupTabIndex ?? this.startupTabIndex,
      terminalPalette: terminalPalette ?? this.terminalPalette,
      terminalFontSize: terminalFontSize ?? this.terminalFontSize,
      terminalLineHeight: terminalLineHeight ?? this.terminalLineHeight,
      terminalCommandHighlight:
          terminalCommandHighlight ?? this.terminalCommandHighlight,
      languageCode: languageCode ?? this.languageCode,
      llmBaseUrl: llmBaseUrl ?? this.llmBaseUrl,
      llmModel: llmModel ?? this.llmModel,
      llmApiKey: llmApiKey ?? this.llmApiKey,
      allowSelfSigned: allowSelfSigned ?? this.allowSelfSigned,
      debugLogEnabled: debugLogEnabled ?? this.debugLogEnabled,
      llmTemperature:
          clearTemperature ? null : (llmTemperature ?? this.llmTemperature),
      llmTopP: clearTopP ? null : (llmTopP ?? this.llmTopP),
      llmMaxTokens: clearMaxTokens ? null : (llmMaxTokens ?? this.llmMaxTokens),
      llmFrequencyPenalty: clearFrequencyPenalty
          ? null
          : (llmFrequencyPenalty ?? this.llmFrequencyPenalty),
      llmPresencePenalty: clearPresencePenalty
          ? null
          : (llmPresencePenalty ?? this.llmPresencePenalty),
      llmTimeoutSeconds: llmTimeoutSeconds ?? this.llmTimeoutSeconds,
      llmExtraBody: llmExtraBody ?? this.llmExtraBody,
      llmExtraHeaders: llmExtraHeaders ?? this.llmExtraHeaders,
      llmDefaultContextLimit:
          llmDefaultContextLimit ?? this.llmDefaultContextLimit,
    );
  }

  Map<String, Object> toPrefs() => {
        'themeMode': themeMode.name,
        'pollIntervalSeconds': pollIntervalSeconds,
        'logPollIntervalSeconds': logPollIntervalSeconds,
        'logPollMillis': logPollMillis,
        'cachedModels': cachedModels,
        'autoStartTerminal': autoStartTerminal,
        'startupTabIndex': startupTabIndex,
        'terminalPalette': terminalPalette,
        'terminalFontSize': terminalFontSize,
        'terminalLineHeight': terminalLineHeight,
        'terminalCommandHighlight': terminalCommandHighlight,
        'languageCode': languageCode,
        'llmBaseUrl': llmBaseUrl,
        'llmModel': llmModel,
        // API Key 不写入 shared_preferences，由 secure_storage 管理。
        // 'llmApiKey': llmApiKey,
        'allowSelfSigned': allowSelfSigned,
        'debugLogEnabled': debugLogEnabled,
        'llmTimeoutSeconds': llmTimeoutSeconds,
        'llmExtraBody': llmExtraBody,
        'llmExtraHeaders': llmExtraHeaders,
        'llmDefaultContextLimit': llmDefaultContextLimit,
      };
}

class SettingsNotifier extends Notifier<AppSettings> {
  @override
  AppSettings build() {
    return const AppSettings();
  }

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final themeName = prefs.getString('themeMode') ?? 'system';
    state = AppSettings(
      themeMode: ThemeMode.values.asNameMap()[themeName] ?? ThemeMode.system,
      pollIntervalSeconds: prefs.getInt('pollIntervalSeconds') ?? 3,
      logPollIntervalSeconds: prefs.getInt('logPollIntervalSeconds') ?? 2,
      // 老版本只存了秒，迁移时换算一次，用户设过的值不丢。
      logPollMillis: prefs.getInt('logPollMillis') ??
          (prefs.getInt('logPollIntervalSeconds') != null
              ? prefs.getInt('logPollIntervalSeconds')! * 1000
              : 500),
      cachedModels: prefs.getStringList('cachedModels') ?? const [],
      modelsFetchedAt: DateTime.tryParse(
        prefs.getString('modelsFetchedAt') ?? '',
      ),
      autoStartTerminal: prefs.getBool('autoStartTerminal') ?? false,
      startupTabIndex: prefs.getInt('startupTabIndex') ?? 2,
      terminalPalette: prefs.getString('terminalPalette') ?? 'one_dark',
      terminalFontSize: prefs.getDouble('terminalFontSize') ?? 13,
      terminalLineHeight: prefs.getDouble('terminalLineHeight') ?? 1.25,
      terminalCommandHighlight:
          prefs.getBool('terminalCommandHighlight') ?? true,
      languageCode: prefs.getString('languageCode') ?? 'zh',
      llmBaseUrl: prefs.getString('llmBaseUrl') ?? '',
      llmModel: prefs.getString('llmModel') ?? '',
      allowSelfSigned: prefs.getBool('allowSelfSigned') ?? false,
      debugLogEnabled: prefs.getBool('debugLogEnabled') ?? true,
      llmTemperature: prefs.getDouble('llmTemperature'),
      llmTopP: prefs.getDouble('llmTopP'),
      llmMaxTokens: prefs.getInt('llmMaxTokens'),
      llmFrequencyPenalty: prefs.getDouble('llmFrequencyPenalty'),
      llmPresencePenalty: prefs.getDouble('llmPresencePenalty'),
      llmTimeoutSeconds: prefs.getInt('llmTimeoutSeconds') ?? 180,
      llmExtraBody: prefs.getString('llmExtraBody') ?? '',
      llmExtraHeaders: prefs.getString('llmExtraHeaders') ?? '',
      llmDefaultContextLimit: prefs.getInt('llmDefaultContextLimit') ?? 8000,
    );
    // 把"允许自签名 HTTPS"交给网络层。
    //
    // 这个开关以前是死的：值存下来了，但没有任何地方读，Dio 一直用默认的
    // HttpClient（自签证书直接握手失败）。表现就是内网自签名的 LLM 网关
    // 打开开关也照样"获取不到模型 / 测试连通失败"。
    DioClient.allowSelfSigned = state.allowSelfSigned;
  }

  Future<void> update(AppSettings next) async {
    state = next;
    // 拨动开关立刻生效：Dio 的 badCertificateCallback 每次握手都读这个静态量。
    DioClient.allowSelfSigned = next.allowSelfSigned;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('themeMode', next.themeMode.name);
    await prefs.setInt('pollIntervalSeconds', next.pollIntervalSeconds);
    await prefs.setInt('logPollIntervalSeconds', next.logPollIntervalSeconds);
    await prefs.setInt('logPollMillis', next.logPollMillis);
    await prefs.setStringList('cachedModels', next.cachedModels);
    if (next.modelsFetchedAt != null) {
      await prefs.setString(
        'modelsFetchedAt',
        next.modelsFetchedAt!.toIso8601String(),
      );
    }
    await prefs.setBool('autoStartTerminal', next.autoStartTerminal);
    await prefs.setInt('startupTabIndex', next.startupTabIndex);
    await prefs.setString('terminalPalette', next.terminalPalette);
    await prefs.setDouble('terminalFontSize', next.terminalFontSize);
    await prefs.setDouble('terminalLineHeight', next.terminalLineHeight);
    await prefs.setBool(
      'terminalCommandHighlight',
      next.terminalCommandHighlight,
    );
    await prefs.setString('languageCode', next.languageCode);
    await prefs.setString('llmBaseUrl', next.llmBaseUrl);
    await prefs.setString('llmModel', next.llmModel);
    await prefs.setBool('allowSelfSigned', next.allowSelfSigned);
    await prefs.setBool('debugLogEnabled', next.debugLogEnabled);
    await prefs.setInt('llmTimeoutSeconds', next.llmTimeoutSeconds);
    await prefs.setString('llmExtraBody', next.llmExtraBody);
    await prefs.setString('llmExtraHeaders', next.llmExtraHeaders);
    await prefs.setInt(
      'llmDefaultContextLimit',
      next.llmDefaultContextLimit,
    );
    // 可空参数：null 要真正删掉键，否则下次 load 会把旧值捞回来。
    await _putDouble(prefs, 'llmTemperature', next.llmTemperature);
    await _putDouble(prefs, 'llmTopP', next.llmTopP);
    await _putInt(prefs, 'llmMaxTokens', next.llmMaxTokens);
    await _putDouble(prefs, 'llmFrequencyPenalty', next.llmFrequencyPenalty);
    await _putDouble(prefs, 'llmPresencePenalty', next.llmPresencePenalty);
  }

  Future<void> _putDouble(
    SharedPreferences prefs,
    String key,
    double? value,
  ) async {
    if (value == null) {
      await prefs.remove(key);
    } else {
      await prefs.setDouble(key, value);
    }
  }

  Future<void> _putInt(
    SharedPreferences prefs,
    String key,
    int? value,
  ) async {
    if (value == null) {
      await prefs.remove(key);
    } else {
      await prefs.setInt(key, value);
    }
  }
}

final settingsProvider =
    NotifierProvider<SettingsNotifier, AppSettings>(SettingsNotifier.new);
