package com.example.qinglong_flutter

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    /// 作为默认浏览器收到 ACTION_VIEW 时，Flutter 会把 URL 当成 GoRouter
    /// 的 initialRoute 去匹配，导致 “no routes for location: https://...”。
    /// 这里强制从首页启动；URL 走 qinglong/open_url 通道交给内置浏览器。
    override fun getInitialRoute(): String? = "/"

    /// 外部悬浮窗预览：主 APP 和悬浮窗服务共用同一个 FlutterEngine，
    /// 所以两边是同一个 Dart isolate/同一份 Provider 状态，不需要做状态同步。
    override fun provideFlutterEngine(context: Context): FlutterEngine =
        SharedFlutterEngine.get(context)

    override fun shouldDestroyEngineWithHost(): Boolean = false

    private var externalChannel: MethodChannel? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        consumeViewIntent(intent)
        // 高刷屏不锁 60：把窗口首选模式指到设备支持的最高刷新率，
        // 让 Flutter 层和 WebView 的 HTML 动画都能吃满 120/144/240Hz。
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            val mode = display?.supportedModes?.maxByOrNull { it.refreshRate }
            if (mode != null) {
                val params = window.attributes
                params.preferredDisplayModeId = mode.modeId
                window.attributes = params
            }
        }
    }

    /// 留着引用：系统文件选择器（SAF）的结果回到 Activity，得转交给它。
    private var prootBridge: ProotBridge? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        prootBridge = ProotBridge(this).also { it.configure(flutterEngine) }
        // 浏览器内核的 cookie 落盘 / 站点数据清理：Dart 侧接口缺这几件。
        WebBridge(this).configure(flutterEngine)
        openChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "qinglong/open_url",
        )
        openChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "setReady" -> {
                    openHandlerReady = true
                    result.success(null)
                }
                "getPendingUrl" -> {
                    val url = pendingUrl
                    pendingUrl = null
                    result.success(url)
                }
                else -> result.notImplemented()
            }
        }
        externalChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "qinglong/external_overlay",
        ).also { channel ->
            channel.setMethodCallHandler { call, result ->
                when (call.method) {
                    "isPermissionGranted" -> result.success(canDrawOverlays())
                    "requestPermission" -> {
                        openOverlaySettings()
                        result.success(null)
                    }
                    "enter" -> {
                        if (!canDrawOverlays()) {
                            openOverlaySettings()
                            result.success(false)
                            return@setMethodCallHandler
                        }
                        val bounds = call.toRectF()
                        result.success(true)
                        // 先把 Activity 的 FlutterView 从引擎上摘下来，避免和
                        // 悬浮窗服务同时挂两个 surface；再启动服务并退到后台。
                        Handler(Looper.getMainLooper()).postDelayed({
                            detachFromFlutterEngine()
                            ExternalOverlayService.start(this, bounds)
                            finish()
                        }, 120)
                    }
                    "updateBounds" -> {
                        ExternalOverlayService.updateBounds(this, call.toRectF())
                        result.success(null)
                    }
                    "exit" -> {
                        ExternalOverlayService.stop(this)
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
        }
    }

    private fun MethodCall.toRectF(): android.graphics.RectF {
        val left = argument<Double>("left")?.toFloat() ?: 0f
        val top = argument<Double>("top")?.toFloat() ?: 0f
        val width = argument<Double>("width")?.toFloat() ?: 0f
        val height = argument<Double>("height")?.toFloat() ?: 0f
        return android.graphics.RectF(left, top, left + width, top + height)
    }

    private fun canDrawOverlays(): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.M || Settings.canDrawOverlays(this)

    private fun openOverlaySettings() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return
        try {
            startActivity(
                Intent(
                    Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                    Uri.parse("package:$packageName"),
                ),
            )
        } catch (_: Exception) {
        }
    }

    private var pendingUrl: String? = null
    private var openChannel: MethodChannel? = null
    private var openHandlerReady = false

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        consumeViewIntent(intent)
    }

    private fun consumeViewIntent(intent: Intent?) {
        if (intent?.action != Intent.ACTION_VIEW) return
        val url = intent.dataString ?: return
        pendingUrl = url
        if (openHandlerReady && openChannel != null) {
            // 只有 Dart 侧确认收到才清 pending；二次跳转/引擎重建时丢包也能靠
            // getPendingUrl 补取，避免“第二次打开没链接”。
            openChannel?.invokeMethod("openUrl", url, object : MethodChannel.Result {
                override fun success(result: Any?) {
                    if (pendingUrl == url) pendingUrl = null
                }

                override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) {
                    // 保留 pendingUrl，下一次 getPendingUrl 仍能拿到。
                }

                override fun notImplemented() {
                    // 保留 pendingUrl。
                }
            })
        }
    }

    @Deprecated("Flutter 插件体系仍走这条老回调；换 ActivityResultLauncher 要动整个 Activity 生命周期")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        // 先给桥一次机会认领；不是它的请求码就照常交给 super（插件们都指着它）。
        if (prootBridge?.onActivityResult(requestCode, resultCode, data) == true) return
        super.onActivityResult(requestCode, resultCode, data)
    }
}
