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
        // 用户可能不是点通知、而是直接从桌面图标回到 APP。此时悬浮窗服务
        // 的 FlutterView 仍挂在共享 engine 上，FlutterActivity 再挂一个会抛
        // “child already has a parent”。先把服务视图摘掉再走 super。
        ExternalOverlayService.detachForAppReturn()
        super.onCreate(savedInstanceState)
        consumeViewIntent(intent)
        maybeEnterExternalForPreview(intent, savedInstanceState)
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
                    "enter" -> result.success(enterExternalOverlay(call.toRectF()))
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

    /// 进入外部悬浮模式。返回 false 表示没有系统悬浮窗权限（并已拉起设置页）。
    private fun enterExternalOverlay(bounds: android.graphics.RectF): Boolean {
        if (!canDrawOverlays()) {
            openOverlaySettings()
            return false
        }
        // 先把 Activity 的 FlutterView 从引擎上摘下来，避免和悬浮窗服务
        // 同时挂两个 surface；再启动服务并退到后台。
        Handler(Looper.getMainLooper()).postDelayed({
            detachFromFlutterEngine()
            ExternalOverlayService.start(this, bounds)
            if (!isFinishing) finish()
        }, 120)
        return true
    }

    /// 预览分支自动化测试入口：`am start ... --ez qinglong_preview_enter_external true`。
    /// 正式发布前应删除；不影响正常用户路径。
    private fun maybeEnterExternalForPreview(intent: Intent?, saved: Bundle?) {
        if (saved != null) return
        if (intent?.getBooleanExtra("qinglong_preview_enter_external", false) != true) return
        val dm = resources.displayMetrics
        val left = intent.getFloatExtra("left", 0f)
        val top = intent.getFloatExtra("top", dm.heightPixels / 3f)
        val right = intent.getFloatExtra("right", dm.widthPixels.toFloat())
        val bottom = intent.getFloatExtra("bottom", dm.heightPixels * 2f / 3f)
        Handler(Looper.getMainLooper()).postDelayed({
            if (!isFinishing) enterExternalOverlay(android.graphics.RectF(left, top, right, bottom))
        }, 800)
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
