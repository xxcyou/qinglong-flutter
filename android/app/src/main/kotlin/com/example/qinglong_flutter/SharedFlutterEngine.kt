package com.example.qinglong_flutter

import android.content.Context
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugins.GeneratedPluginRegistrant

/// 主 APP 与 APP 外悬浮窗服务共用的唯一 FlutterEngine。
///
/// 共用同一个 engine 意味着同一个 Dart isolate、同一份 Provider 状态，
/// 所以外悬浮窗里的 AI 会话、浏览器内核、终端会话与 APP 内完全一致，
/// 不需要走平台通道做状态同步。
object SharedFlutterEngine {
    @Volatile
    private var engine: FlutterEngine? = null

    fun get(context: Context): FlutterEngine {
        engine?.let { return it }
        synchronized(this) {
            engine?.let { return it }
            val created = FlutterEngine(context.applicationContext)
            // 自定义 provideFlutterEngine 时，FlutterActivity 不会再替我们注册插件。
            GeneratedPluginRegistrant.registerWith(created)
            engine = created
            return created
        }
    }
}
