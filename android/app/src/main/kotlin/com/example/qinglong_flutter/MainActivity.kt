package com.example.qinglong_flutter

import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    /// 留着引用：系统文件选择器（SAF）的结果回到 Activity，得转交给它。
    private var prootBridge: ProotBridge? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        prootBridge = ProotBridge(this).also { it.configure(flutterEngine) }
        // 浏览器内核的 cookie 落盘 / 站点数据清理：Dart 侧接口缺这几件。
        WebBridge(this).configure(flutterEngine)
    }

    @Deprecated("Flutter 插件体系仍走这条老回调；换 ActivityResultLauncher 要动整个 Activity 生命周期")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        // 先给桥一次机会认领；不是它的请求码就照常交给 super（插件们都指着它）。
        if (prootBridge?.onActivityResult(requestCode, resultCode, data) == true) return
        super.onActivityResult(requestCode, resultCode, data)
    }
}
