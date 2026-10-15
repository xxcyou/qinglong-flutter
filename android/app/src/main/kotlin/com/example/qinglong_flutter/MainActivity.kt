package com.example.qinglong_flutter

import android.content.Context
import android.content.Intent
import android.graphics.RectF
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.android.FlutterView
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    companion object {
        /// APP 主 Activity 是否在前台。服务摘/挂 view 时用它决定要不要给
        /// 共享 engine 补发 lifecycle 状态。
        @Volatile
        var isResumed: Boolean = false
    }

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

    /// AI 悬浮球开关是否打开（用户是否要“缩后台也继续显示”）。
    private var externalArmed = false

    /// 原生覆盖窗口最后一次使用的几何；Dart 侧每次并集变化都会同步过来。
    private var lastBounds = RectF(0f, 0f, 72f, 72f)

    /// FlutterActivity 自己创建的那个 FlutterView。APP 退后台时把它从 engine
    /// 上摘下来、回前台再挂回去；同一时刻只挂一个 view，engine 渲染才稳定。
    private var activityFlutterView: FlutterView? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        // 进程/Activity 重建时，覆盖窗口可能还挂在共享 engine 上；先摘掉，
        // 避免 FlutterActivity 再挂 view 时抛 “child already has a parent”。
        ExternalOverlayService.detach()
        super.onCreate(savedInstanceState)
        activityFlutterView =
            findViewById<FlutterView>(FlutterActivity.FLUTTER_VIEW_ID)
        // Activity 被系统重建时字段会重置；只要准备态服务还在，就说明用户
        // 上次开着 APP 外悬浮，继续沿用，不要漏掉退后台的 attach。
        externalArmed = ExternalOverlayService.isRunning()
        ExternalOverlayService.currentBounds()?.let { lastBounds = it }
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

    override fun onStart() {
        super.onStart()
        // 回前台：先把覆盖窗口的 view 摘掉，再把 Activity 的 view 挂回 engine。
        if (ExternalOverlayService.isOverlayAttached()) {
            ExternalOverlayService.detach()
        }
        // 不管覆盖窗口有没有挂成功，Activity 的 view 都必须回到 engine；
        // 否则 attach 失败一次会让整个 APP 黑屏。
        reattachActivityView()
    }

    override fun onResume() {
        super.onResume()
        isResumed = true
        // 某些机型 onStart 里 view 还不可用，onResume 再兜一次。
        if (!ExternalOverlayService.isOverlayAttached() &&
            activityFlutterView?.isAttachedToFlutterEngine == false
        ) {
            reattachActivityView()
        }
    }

    override fun onPause() {
        isResumed = false
        super.onPause()
    }

    override fun onStop() {
        super.onStop()
        if (!externalArmed || isChangingConfigurations) return
        // 用户自己把 APP 缩到后台：把 Activity view 摘下来，让前台服务把
        // 同一个 engine 挂到系统覆盖窗口上，悬浮层原位继续显示。
        try {
            activityFlutterView?.detachFromFlutterEngine()
        } catch (_: Exception) {
        }
        try {
            ExternalOverlayService.attach(this, lastBounds)
        } catch (_: Exception) {
            // 极端情况下（权限被系统回收/后台启动前台服务被拦）不 crash，
            // 回前台时 onStart 会把 Activity 的 view 重新挂回去。
        }
    }

    private fun reattachActivityView() {
        val view = activityFlutterView ?: return
        if (view.isAttachedToFlutterEngine) return
        try {
            view.attachToFlutterEngine(SharedFlutterEngine.get(this))
        } catch (_: Exception) {
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
                    "arm" -> result.success(armExternal(call.toRectF()))
                    "disarm" -> {
                        disarmExternal()
                        result.success(null)
                    }
                    // 旧协议保留：不再 finish Activity，等用户自己缩后台。
                    "enter" -> result.success(armExternal(call.toRectF()))
                    "updateBounds" -> {
                        lastBounds = call.toRectF()
                        ExternalOverlayService.updateBounds(this, lastBounds)
                        result.success(null)
                    }
                    "exit" -> {
                        disarmExternal()
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
        }
    }

    /// 打开“缩后台也显示”的能力：只起准备态前台服务，不挂 view、不 finish。
    /// 返回 false 表示没有系统悬浮窗权限（并已拉起设置页）。
    private fun armExternal(bounds: RectF): Boolean {
        if (!canDrawOverlays()) {
            openOverlaySettings()
            return false
        }
        lastBounds = bounds
        return try {
            ExternalOverlayService.arm(this, bounds)
            externalArmed = true
            // 这里只“准备”服务；真正挂覆盖窗口由 onStop（用户缩后台）触发。
            // 不要在 arm 时立刻 attach：APP 启动早期 isResumed 还是 false，
            // 会把覆盖窗口错误地提前挂到前台。
            true
        } catch (_: Exception) {
            externalArmed = false
            false
        }
    }

    private fun disarmExternal() {
        externalArmed = false
        ExternalOverlayService.disarm(this)
    }

    /// 预览分支自动化测试入口：`am start ... --ez qinglong_preview_enter_external true`。
    /// arm 之后主动 moveTaskToBack，模拟用户按 Home；正式发布前应删除。
    private fun maybeEnterExternalForPreview(intent: Intent?, saved: Bundle?) {
        if (saved != null) return
        if (intent?.getBooleanExtra("qinglong_preview_enter_external", false) != true) return
        val dm = resources.displayMetrics
        val left = intent.getFloatExtra("left", 0f)
        val top = intent.getFloatExtra("top", dm.heightPixels / 3f)
        val right = intent.getFloatExtra("right", dm.widthPixels.toFloat())
        val bottom = intent.getFloatExtra("bottom", dm.heightPixels * 2f / 3f)
        Handler(Looper.getMainLooper()).postDelayed({
            if (isFinishing) return@postDelayed
            val bounds = RectF(left, top, right, bottom)
            if (armExternal(bounds)) {
                moveTaskToBack(true)
            }
        }, 800)
    }

    private fun MethodCall.toRectF(): RectF {
        val left = argument<Double>("left")?.toFloat() ?: 0f
        val top = argument<Double>("top")?.toFloat() ?: 0f
        val width = argument<Double>("width")?.toFloat() ?: 0f
        val height = argument<Double>("height")?.toFloat() ?: 0f
        return RectF(left, top, left + width, top + height)
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
