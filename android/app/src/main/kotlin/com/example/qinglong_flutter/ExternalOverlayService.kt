package com.example.qinglong_flutter

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.graphics.Color
import android.graphics.PixelFormat
import android.graphics.RectF
import android.os.Build
import android.os.IBinder
import android.os.SystemClock
import android.util.Log
import android.view.Gravity
import android.view.MotionEvent
import android.view.SurfaceHolder
import android.view.WindowInsets
import android.view.SurfaceView
import android.view.WindowManager
import android.view.inputmethod.InputMethodManager
import io.flutter.embedding.android.FlutterView
import io.flutter.embedding.android.RenderMode
import io.flutter.embedding.android.TransparencyMode
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/// APP 外悬浮窗服务（单引擎 · 准备态方案）。
///
/// 它不创建新的 FlutterEngine，而是把主 APP 正在用的 engine 在 APP 退到后台
/// 时重新挂到一个 [FlutterView] 上，再作为
/// [WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY] 窗口显示。
///
/// 生命周期：
///  - ARM：用户打开 AI 悬浮球时调用。只把前台服务跑起来（准备态），不挂 view，
///    所以 APP 仍在前台、不会最小化/重启。
///  - ATTACH：APP 真正退到后台时调用，挂 view、通知 Dart 切到悬浮层。
///  - DETACH：APP 回到前台时调用，摘 view、通知 Dart 切回 APP 页面。
///  - DISARM：用户关 AI 悬浮球时调用，摘 view 并停服务。
///
/// 因为 engine / Dart isolate / Riverpod Provider 还是同一份，悬浮窗和 APP 内
/// 状态天然一致，位置也不会因为切前后台而变化。
class ExternalOverlayService : Service() {
    /// 带 ACTION_OUTSIDE 监听的 FlutterView：覆盖窗口带
    /// FLAG_WATCH_OUTSIDE_TOUCH，用户点击覆盖窗以外的区域（其他 APP）时，
    /// 这里能收到 ACTION_OUTSIDE，从而立刻释放 IME 焦点，避免一直占着
    /// 输入法。点在底部键盘区域的 outside 事件要忽略，否则会把自己刚弹
    /// 出来的键盘关掉。
    private class OverlayFlutterView(context: Context) :
        FlutterView(context, RenderMode.surface, TransparencyMode.transparent) {

        var onOutsideTouch: ((MotionEvent) -> Unit)? = null

        override fun dispatchTouchEvent(event: MotionEvent): Boolean {
            if (event.action == MotionEvent.ACTION_OUTSIDE) {
                onOutsideTouch?.invoke(event)
            }
            return super.dispatchTouchEvent(event)
        }
    }

    companion object {
        private const val CHANNEL_ID = "qinglong_external_overlay"
        private const val NOTIFICATION_ID = 0x514C
        private const val ACTION_ARM =
            "com.example.qinglong_flutter.action.EXTERNAL_ARM"
        private const val ACTION_ATTACH =
            "com.example.qinglong_flutter.action.EXTERNAL_ATTACH"
        private const val ACTION_DETACH =
            "com.example.qinglong_flutter.action.EXTERNAL_DETACH"
        private const val ACTION_DISARM =
            "com.example.qinglong_flutter.action.EXTERNAL_DISARM"
        private const val EXTRA_LEFT = "left"
        private const val EXTRA_TOP = "top"
        private const val EXTRA_RIGHT = "right"
        private const val EXTRA_BOTTOM = "bottom"

        private const val TAG = "QinglongOverlay"

        @Volatile
        private var instance: ExternalOverlayService? = null

        /// service 还没创建完时收到的 ATTACH 请求。等 ACTION_ARM 启动完成
        /// 后在 onStartCommand 里补挂，避免“刚开开关就按 Home”时后台启动
        /// 前台服务被系统拦截，导致悬浮球一直不出现。
        @Volatile
        private var pendingAttach: RectF? = null

        /// 准备态服务：起前台服务，但先不挂覆盖窗口 view。
        fun arm(context: Context, bounds: RectF) {
            val intent = Intent(context, ExternalOverlayService::class.java).apply {
                action = ACTION_ARM
                putBounds(bounds)
            }
            Log.i(TAG, "arm: startForegroundService bounds=$bounds")
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        /// 把覆盖窗口挂到共享 engine 上。由 MainActivity.onStop（APP 退后台）调用。
        ///
        /// 正常情况下 ARM 已经把服务跑起来了；这里再兜底一次，防止用户
        /// “刚开开关就立刻按 Home”时服务还没创建完。
        fun attach(context: Context, bounds: RectF) {
            val service = instance
            if (service != null) {
                Log.i(TAG, "attach: service ready, bounds=$bounds")
                service.applyBounds(bounds)
                service.attachOverlay()
                return
            }
            // service 还没起来：记下请求，并尝试用 ACTION_ATTACH 启动一次。
            // 如果此刻 APP 已在后台、系统拦截了后台 FGS 启动，这次 start
            // 会抛异常；但先前 ARM 的启动仍在进行，ACTION_ARM 处理时会
            // 发现 pendingAttach 并补挂，悬浮球不会丢。
            pendingAttach = RectF(bounds)
            Log.i(TAG, "attach: service not ready, pending bounds=$bounds")
            val intent = Intent(context, ExternalOverlayService::class.java).apply {
                action = ACTION_ATTACH
                putBounds(bounds)
            }
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(intent)
                } else {
                    context.startService(intent)
                }
            } catch (e: Exception) {
                Log.w(TAG, "attach: start service from background failed: $e")
            }
        }

        /// 摘掉覆盖窗口，但服务继续准备着。由 MainActivity.onStart（回前台）调用。
        fun detach() {
            pendingAttach = null
            instance?.detachOverlay()
        }

        /// 关闭能力：摘窗口 + 停服务。
        fun disarm(context: Context) {
            pendingAttach = null
            instance?.let {
                it.detachOverlay()
                it.stopSelf()
                return
            }
            val intent = Intent(context, ExternalOverlayService::class.java).apply {
                action = ACTION_DISARM
            }
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(intent)
                } else {
                    context.startService(intent)
                }
            } catch (_: Exception) {
                // 服务本来就没起来，不需要为了 stop 再冒险启动。
            }
        }

        fun isOverlayAttached(): Boolean = instance?.flutterView != null

        /// 服务是否在准备态/悬浮态运行。Activity 重建时用它判断用户是否
        /// 还开着“APP 外悬浮”，避免 externalArmed 字段被重置后漏挂窗口。
        fun isRunning(): Boolean = instance != null

        fun currentBounds(): RectF? = instance?.bounds

        /// 拖动/缩放悬浮窗时只更新已在运行的 service 里的 bounds；服务没挂
        /// view 时也会先存下来，等 ATTACH 时用同一份几何，位置不跳。
        fun updateBounds(context: Context, bounds: RectF) {
            instance?.applyBounds(bounds)
        }

        /// 悬浮窗里的输入框获得/失去焦点时切换覆盖窗口的 IME 焦点。
        fun setImeFocus(focused: Boolean) {
            instance?.applyImeFocus(focused)
        }

        private fun Intent.putBounds(bounds: RectF) {
            putExtra(EXTRA_LEFT, bounds.left)
            putExtra(EXTRA_TOP, bounds.top)
            putExtra(EXTRA_RIGHT, bounds.right)
            putExtra(EXTRA_BOTTOM, bounds.bottom)
        }
    }

    private var engine: FlutterEngine? = null
    private var flutterView: FlutterView? = null
    private var windowManager: WindowManager? = null
    private var layoutParams: WindowManager.LayoutParams? = null
    private var bounds = RectF(0f, 0f, 72f, 72f)

    /// 为了让悬浮窗里的输入框弹键盘而临时获得焦点；默认 false。
    private var imeFocused = false
    private var methodChannel: MethodChannel? = null

    /// Home/最近任务/锁屏时，系统会发 CLOSE_SYSTEM_DIALOGS；此时必须立刻
    /// 释放覆盖窗口的 IME 焦点，否则 TYPE_APPLICATION_OVERLAY 会一直压在
    /// 其他应用上面，用户点其他应用的输入法也弹不出来。
    private val systemDialogReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            when (intent?.action) {
                Intent.ACTION_CLOSE_SYSTEM_DIALOGS,
                Intent.ACTION_SCREEN_OFF -> {
                    if (imeFocused) {
                        Log.i(TAG, "release IME focus: ${intent.action}")
                        applyImeFocus(false)
                    }
                }
            }
        }
    }

    override fun onCreate() {
        super.onCreate()
        instance = this
        Log.i(TAG, "service onCreate")
        createNotificationChannel()
        startForeground(NOTIFICATION_ID, buildNotification())
        try {
            val filter = IntentFilter().apply {
                addAction(Intent.ACTION_CLOSE_SYSTEM_DIALOGS)
                addAction(Intent.ACTION_SCREEN_OFF)
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                registerReceiver(
                    systemDialogReceiver,
                    filter,
                    Context.RECEIVER_NOT_EXPORTED,
                )
            } else {
                @Suppress("DEPRECATION")
                registerReceiver(systemDialogReceiver, filter)
            }
        } catch (_: Exception) {
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_DISARM -> {
                detachOverlay()
                stopSelf()
                return START_NOT_STICKY
            }
            ACTION_ARM -> {
                // 准备态：只更新 bounds，不挂 view。
                intent.readBounds()?.let { bounds = it }
                pendingAttach?.let { pending ->
                    Log.i(TAG, "ARM consumed pendingAttach bounds=$pending")
                    pendingAttach = null
                    bounds = pending
                    attachOverlay()
                }
            }
            ACTION_ATTACH -> {
                intent.readBounds()?.let { bounds = it }
                pendingAttach = null
                attachOverlay()
            }
            ACTION_DETACH -> detachOverlay()
        }
        return START_STICKY
    }

    private fun Intent.readBounds(): RectF? {
        if (!hasExtra(EXTRA_LEFT)) return null
        return RectF(
            getFloatExtra(EXTRA_LEFT, 0f),
            getFloatExtra(EXTRA_TOP, 0f),
            getFloatExtra(EXTRA_RIGHT, 1f),
            getFloatExtra(EXTRA_BOTTOM, 1f),
        )
    }

    private fun buildOverlayParams(): WindowManager.LayoutParams {
        val type = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
        } else {
            @Suppress("DEPRECATION")
            WindowManager.LayoutParams.TYPE_PHONE
        }
        val empty = isEmptyBounds(bounds)
        var flags = WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL or
            WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS or
            WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN or
            WindowManager.LayoutParams.FLAG_HARDWARE_ACCELERATED or
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
            WindowManager.LayoutParams.FLAG_WATCH_OUTSIDE_TOUCH
        if (empty) {
            // 没有可见悬浮窗时窗口收到 1x1，并且整窗不可触摸，
            // 连那 1 个像素也不会挡住桌面。
            flags = flags or WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE
        }
        return WindowManager.LayoutParams(
            if (empty) 1 else width(),
            if (empty) 1 else height(),
            type,
            flags,
            PixelFormat.TRANSLUCENT,
        ).apply {
            gravity = Gravity.TOP or Gravity.START
            x = if (empty) 0 else bounds.left.toInt()
            y = if (empty) 0 else bounds.top.toInt()
            softInputMode = WindowManager.LayoutParams.SOFT_INPUT_ADJUST_RESIZE
        }
    }

    private fun attachOverlay() {
        if (flutterView != null) {
            applyBounds(bounds)
            return
        }
        var view: OverlayFlutterView? = null
        try {
            val shared = SharedFlutterEngine.get(this)
            engine = shared
            try {
                methodChannel = MethodChannel(
                    shared.dartExecutor.binaryMessenger,
                    "qinglong/external_overlay",
                )
            } catch (_: Exception) {
            }
            val overlayView = OverlayFlutterView(this)
            view = overlayView
            overlayView.onOutsideTouch = { event ->
                if (imeFocused) {
                    Log.i(TAG, "outside touch y=${event.rawY}")
                    if (!isTouchOnIme(event)) {
                        Log.i(TAG, "release IME focus: outside touch")
                        applyImeFocus(false)
                    }
                }
            }
            overlayView.setBackgroundColor(Color.TRANSPARENT)
            overlayView.attachToFlutterEngine(shared)
            // APP 退到后台时 engine 可能被 LifecycleChannel 暂停；悬浮窗要动起来。
            try {
                shared.lifecycleChannel.appIsResumed()
            } catch (_: Exception) {
            }
            flutterView = view
            val wm = getSystemService(WINDOW_SERVICE) as WindowManager
            windowManager = wm
            val params = buildOverlayParams()
            layoutParams = params
            wm.addView(view, params)
            notifyDartMode(true)
            val attachedView = view
            installSurfaceKick(attachedView, shared)

            // 部分 ROM 上覆盖窗口的 SurfaceView 首帧不会自动上屏：
            // 在窗口角落发一个合成触摸，踢一下引擎的帧调度。坐标 (2,2)
            // 落在悬浮窗并集的透明留白里，不会点到任何悬浮窗。
            attachedView.postDelayed({
                try {
                    shared.lifecycleChannel.appIsResumed()
                } catch (_: Exception) {
                }
                kickFirstFrame(attachedView)
            }, 250)
            attachedView.postDelayed({
                kickFirstFrame(attachedView)
            }, 900)
        } catch (_: Exception) {
            // 权限被回收、WindowManager 拒绝、engine 异常等情况：保持 service
            // 准备态，不把主进程带崩；回前台 onStart 仍能 reattach Activity view。
            try {
                flutterView?.detachFromFlutterEngine()
            } catch (_: Exception) {
            }
            try {
                windowManager?.removeView(view)
            } catch (_: Exception) {
            }
            flutterView = null
            layoutParams = null
        }
    }

    /// SurfaceView 的 surface 是异步创建的：固定延时踢帧可能在 surface
    /// 就绪前就跑了（比如挂载时屏幕刚好熄灭/锁屏）。这里直接监听
    /// surfaceCreated，surface 一就绪就踢首帧，之后屏幕再亮也能补上。
    private fun installSurfaceKick(view: FlutterView, shared: FlutterEngine) {
        try {
            var surfaceView: SurfaceView? = null
            for (i in 0 until view.childCount) {
                val child = view.getChildAt(i)
                if (child is SurfaceView) {
                    surfaceView = child
                    break
                }
            }
            val target = surfaceView ?: return
            val holder = target.holder
            holder.addCallback(object : SurfaceHolder.Callback {
                override fun surfaceCreated(h: SurfaceHolder) {
                    // 让 Dart 侧重新补帧：surface 可能在屏幕重新点亮后才创建，
                    // 此时最初的补帧窗口已经过去。
                    notifyDartSurfaceReady()
                    view.postDelayed({ kickFirstFrame(view) }, 100)
                    view.postDelayed({ kickFirstFrame(view) }, 600)
                }

                override fun surfaceChanged(h: SurfaceHolder, format: Int, width: Int, height: Int) {
                    try {
                        shared.lifecycleChannel.appIsResumed()
                    } catch (_: Exception) {
                    }
                }

                override fun surfaceDestroyed(h: SurfaceHolder) {}
            })
            if (holder.surface?.isValid == true) {
                view.postDelayed({ kickFirstFrame(view) }, 100)
            }
        } catch (_: Exception) {
        }
    }

    private fun kickFirstFrame(view: FlutterView) {
        if (flutterView !== view) return
        try {
            val now = SystemClock.uptimeMillis()
            val down = MotionEvent.obtain(now, now, MotionEvent.ACTION_DOWN, 2f, 2f, 0)
            val up = MotionEvent.obtain(now, now + 16, MotionEvent.ACTION_UP, 2f, 2f, 0)
            try {
                view.dispatchTouchEvent(down)
                view.dispatchTouchEvent(up)
            } finally {
                down.recycle()
                up.recycle()
            }
        } catch (_: Exception) {
        }
    }

    private fun detachOverlay() {
        if (imeFocused) applyImeFocus(false)
        val view = flutterView
        flutterView = null
        if (view != null) {
            notifyDartMode(false)
            if (!MainActivity.isResumed) {
                try {
                    engine?.lifecycleChannel?.appIsPaused()
                } catch (_: Exception) {
                }
            }
            try {
                view.detachFromFlutterEngine()
            } catch (_: Exception) {
            }
            try {
                windowManager?.removeView(view)
            } catch (_: Exception) {
            }
        }
        layoutParams = null
    }

    /// 判断 ACTION_OUTSIDE 是否落在底部输入法区域。IME 窗口的
    /// window insets 在 API 30+ 用 WindowInsets.Type.ime()，老系统用
    /// systemWindowInsetBottom。点在键盘上不能释放焦点。
    private fun isTouchOnIme(event: MotionEvent): Boolean {
        val view = flutterView ?: return false
        val screenHeight = resources.displayMetrics.heightPixels
        val imeBottom = try {
            val insets = view.rootWindowInsets
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                insets?.getInsets(WindowInsets.Type.ime())?.bottom ?: 0
            } else {
                @Suppress("DEPRECATION")
                insets?.systemWindowInsetBottom ?: 0
            }
        } catch (_: Exception) {
            0
        }
        if (imeBottom <= 0) return false
        return event.rawY >= screenHeight - imeBottom
    }

    /// 切换覆盖窗口的 IME 焦点。
    ///
    /// 默认带 FLAG_NOT_FOCUSABLE：不抢其他应用的输入法。只有悬浮窗里的
    /// 输入框拿到 Dart 焦点时才清掉该 flag、requestFocus 并 showSoftInput；
    /// 焦点离开或被别的应用抢走时立刻恢复。
    private fun applyImeFocus(focused: Boolean) {
        imeFocused = focused
        Log.i(TAG, "setImeFocus=$focused")
        val view = flutterView ?: return
        val params = layoutParams ?: return
        val nextFlags = if (focused) {
            params.flags and WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE.inv()
        } else {
            params.flags or WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE
        }
        if (nextFlags != params.flags) {
            params.flags = nextFlags
            try {
                windowManager?.updateViewLayout(view, params)
            } catch (_: Exception) {
            }
        }
        val imm = getSystemService(INPUT_METHOD_SERVICE) as? InputMethodManager
        if (focused) {
            try {
                view.requestFocus()
                // 键盘动画期间不要再反复 requestFocus/showSoftInput，
                // 否则系统会不断重启弹出动画，看起来就是“一点一点卡上来”。
                // 第一次等窗口焦点稳定后请求；只在 450ms 后还没弹出来时
                // 补一次，之后不再打扰。
                view.postDelayed({
                    if (!imeFocused) return@postDelayed
                    try {
                        imm?.showSoftInput(view, InputMethodManager.SHOW_IMPLICIT)
                    } catch (_: Exception) {
                    }
                }, 90)
                view.postDelayed({
                    if (!imeFocused) return@postDelayed
                    val active = try {
                        imm?.isActive(view) == true
                    } catch (_: Exception) {
                        false
                    }
                    if (!active) {
                        try {
                            imm?.showSoftInput(view, InputMethodManager.SHOW_IMPLICIT)
                        } catch (_: Exception) {
                        }
                    }
                }, 480)
            } catch (_: Exception) {
            }
        } else {
            // 通知 Dart 清掉输入焦点，否则 Dart 侧 _imeFocus 还是 true，
            // 下次点悬浮窗输入框时不会再发 setImeFocus(true)。
            try {
                methodChannel?.invokeMethod("imeReleased", null)
            } catch (_: Exception) {
            }
            try {
                imm?.hideSoftInputFromWindow(view.windowToken, 0)
            } catch (_: Exception) {
            }
            try {
                view.clearFocus()
            } catch (_: Exception) {
            }
        }
    }

    private fun applyBounds(next: RectF) {
        bounds = next
        val params = layoutParams ?: return
        if (isEmptyBounds(next)) {
            // 全部悬浮窗都关了：窗口缩到 1x1 且不可触摸，桌面触摸全部穿透。
            params.x = 0
            params.y = 0
            params.width = 1
            params.height = 1
            params.flags = params.flags or
                WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE or
                WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE
        } else {
            params.x = next.left.toInt()
            params.y = next.top.toInt()
            params.width = width()
            params.height = height()
            params.flags = params.flags and
                WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE.inv()
            // 有内容时按当前 IME 状态决定是否可聚焦。
            if (imeFocused) {
                params.flags = params.flags and
                    WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE.inv()
            } else {
                params.flags = params.flags or
                    WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE
            }
        }
        try {
            windowManager?.updateViewLayout(flutterView, params)
        } catch (_: Exception) {
        }
    }

    private fun isEmptyBounds(rect: RectF): Boolean =
        rect.width() < 1f || rect.height() < 1f

    private fun width(): Int = bounds.width().toInt().coerceAtLeast(1)

    private fun height(): Int = bounds.height().toInt().coerceAtLeast(1)

    private fun notifyDartSurfaceReady() {
        val e = engine ?: return
        try {
            MethodChannel(
                e.dartExecutor.binaryMessenger,
                "qinglong/external_overlay",
            ).invokeMethod("surfaceReady", null)
        } catch (_: Exception) {
        }
    }

    private fun notifyDartMode(active: Boolean) {
        val e = engine ?: return
        try {
            MethodChannel(
                e.dartExecutor.binaryMessenger,
                "qinglong/external_overlay",
            ).invokeMethod("modeChanged", active)
        } catch (_: Exception) {
        }
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
        val channel = NotificationChannel(
            CHANNEL_ID,
            "APP 外悬浮窗",
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = "保持悬浮球/悬浮窗显示在其它 APP 上层"
            setShowBadge(false)
        }
        manager.createNotificationChannel(channel)
    }

    private fun buildNotification(): Notification {
        val openIntent = Intent(this, MainActivity::class.java).apply {
            addFlags(
                Intent.FLAG_ACTIVITY_NEW_TASK or
                    Intent.FLAG_ACTIVITY_CLEAR_TOP or
                    Intent.FLAG_ACTIVITY_SINGLE_TOP,
            )
        }
        val flags = PendingIntent.FLAG_UPDATE_CURRENT or
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                PendingIntent.FLAG_IMMUTABLE
            } else {
                0
            }
        val pending = PendingIntent.getActivity(this, 0x514C, openIntent, flags)
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        return builder
            .setContentTitle("青龙AI 外悬浮窗运行中")
            .setContentText("缩到后台后悬浮球/悬浮窗继续显示；点此回到 APP")
            .setSmallIcon(android.R.drawable.ic_menu_compass)
            .setContentIntent(pending)
            .setOngoing(true)
            .build()
    }

    override fun onDestroy() {
        try {
            unregisterReceiver(systemDialogReceiver)
        } catch (_: Exception) {
        }
        detachOverlay()
        instance = null
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null
}
