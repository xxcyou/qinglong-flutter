package com.example.qinglong_flutter

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.graphics.PixelFormat
import android.graphics.RectF
import android.os.Build
import android.os.IBinder
import android.view.Gravity
import android.view.WindowManager
import io.flutter.embedding.android.FlutterView
import io.flutter.embedding.android.RenderMode
import io.flutter.embedding.android.TransparencyMode
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/// APP 外悬浮窗服务。
///
/// 它不创建新的 FlutterEngine，而是把主 APP 正在用的 engine 重新挂到一个
/// [FlutterView] 上，再作为 [WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY]
/// 窗口显示。因为 engine 没换，所以 Dart isolate、Riverpod Provider、浏览器
/// 内核、终端会话全部是同一份，悬浮窗和 APP 内看到的状态天然一致。
class ExternalOverlayService : Service() {
    companion object {
        private const val CHANNEL_ID = "qinglong_external_overlay"
        private const val NOTIFICATION_ID = 0x514C
        private const val ACTION_START =
            "com.example.qinglong_flutter.action.EXTERNAL_START"
        private const val ACTION_UPDATE =
            "com.example.qinglong_flutter.action.EXTERNAL_UPDATE"
        private const val ACTION_STOP =
            "com.example.qinglong_flutter.action.EXTERNAL_STOP"
        private const val EXTRA_LEFT = "left"
        private const val EXTRA_TOP = "top"
        private const val EXTRA_RIGHT = "right"
        private const val EXTRA_BOTTOM = "bottom"

        @Volatile
        private var instance: ExternalOverlayService? = null

        fun start(context: Context, bounds: RectF) {
            val intent = Intent(context, ExternalOverlayService::class.java).apply {
                action = ACTION_START
                putBounds(bounds)
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        /// 拖动/缩放悬浮窗时只更新已经在运行的 service 窗口，不再 startService，
        /// 避开 Android 12+ 后台启动前台服务的限制。
        fun updateBounds(context: Context, bounds: RectF) {
            instance?.applyBounds(bounds)
        }

        fun stop(context: Context) {
            instance?.let {
                it.hideOverlay(openApp = true)
                it.stopSelf()
                return
            }
            val intent = Intent(context, ExternalOverlayService::class.java).apply {
                action = ACTION_STOP
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
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
    private var bounds = RectF(0f, 0f, 1f, 1f)

    override fun onCreate() {
        super.onCreate()
        instance = this
        createNotificationChannel()
        startForeground(NOTIFICATION_ID, buildNotification())
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                hideOverlay(openApp = true)
                stopSelf()
                return START_NOT_STICKY
            }
            ACTION_START, ACTION_UPDATE -> {
                intent.readBounds()?.let { bounds = it }
                showOverlay()
                notifyDartMode(true)
            }
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

    private fun showOverlay() {
        if (flutterView != null) {
            applyBounds(bounds)
            return
        }
        val shared = SharedFlutterEngine.get(this)
        engine = shared
        val view = FlutterView(this, RenderMode.surface, TransparencyMode.transparent)
        view.setBackgroundColor(Color.TRANSPARENT)
        view.attachToFlutterEngine(shared)
        // Activity 已经 finish，engine 可能停在 paused；重新挂到悬浮窗后恢复。
        try {
            shared.lifecycleChannel.appIsResumed()
        } catch (_: Exception) {
        }
        flutterView = view
        val wm = getSystemService(WINDOW_SERVICE) as WindowManager
        windowManager = wm
        val type = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
        } else {
            @Suppress("DEPRECATION")
            WindowManager.LayoutParams.TYPE_PHONE
        }
        val params = WindowManager.LayoutParams(
            width(),
            height(),
            type,
            WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL or
                WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS or
                WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN or
                WindowManager.LayoutParams.FLAG_HARDWARE_ACCELERATED,
            PixelFormat.TRANSLUCENT,
        ).apply {
            gravity = Gravity.TOP or Gravity.START
            x = bounds.left.toInt()
            y = bounds.top.toInt()
            softInputMode = WindowManager.LayoutParams.SOFT_INPUT_ADJUST_RESIZE
        }
        layoutParams = params
        wm.addView(view, params)
    }

    private fun applyBounds(next: RectF) {
        bounds = next
        val params = layoutParams ?: return
        params.x = next.left.toInt()
        params.y = next.top.toInt()
        params.width = width()
        params.height = height()
        try {
            windowManager?.updateViewLayout(flutterView, params)
        } catch (_: Exception) {
        }
    }

    private fun width(): Int = bounds.width().toInt().coerceAtLeast(1)

    private fun height(): Int = bounds.height().toInt().coerceAtLeast(1)

    private fun hideOverlay(openApp: Boolean) {
        notifyDartMode(false)
        val view = flutterView
        flutterView = null
        if (view != null) {
            try {
                engine?.lifecycleChannel?.appIsPaused()
            } catch (_: Exception) {
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
        if (openApp) {
            val intent = Intent(this, MainActivity::class.java).apply {
                addFlags(
                    Intent.FLAG_ACTIVITY_NEW_TASK or
                        Intent.FLAG_ACTIVITY_CLEAR_TOP or
                        Intent.FLAG_ACTIVITY_SINGLE_TOP,
                )
            }
            try {
                startActivity(intent)
            } catch (_: Exception) {
            }
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
        val stopIntent = Intent(this, ExternalOverlayService::class.java).apply {
            action = ACTION_STOP
        }
        val flags = PendingIntent.FLAG_UPDATE_CURRENT or
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                PendingIntent.FLAG_IMMUTABLE
            } else {
                0
            }
        val pending = PendingIntent.getService(this, 0x514C, stopIntent, flags)
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        return builder
            .setContentTitle("青龙AI 外悬浮窗运行中")
            .setContentText("点此返回 APP，或继续在其它 APP 上使用悬浮窗")
            .setSmallIcon(android.R.drawable.ic_menu_compass)
            .setContentIntent(pending)
            .setOngoing(true)
            .build()
    }

    override fun onDestroy() {
        hideOverlay(openApp = false)
        instance = null
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null
}
