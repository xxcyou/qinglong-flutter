package com.example.qinglong_flutter

import android.content.Context
import android.webkit.CookieManager
import android.webkit.WebStorage
import android.webkit.WebView
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * 浏览器内核的"持久化 + 会话"补丁层。
 *
 * webview_flutter 的 Dart 侧只给了 setCookie / getCookies / clearCookies，
 * 少了三件让 WebView 真正像浏览器的事：
 *
 * 1. **flush**：Android 的 CookieManager 先把 cookie 放在内存里，进程被杀之前
 *    不一定落盘。不主动 flush，用户登录完一次、APP 被后台清掉，登录态就没了。
 * 2. **第三方 cookie**：默认拒收。很多站点的登录（尤其接了 SSO / CF 的）靠
 *    跨站 cookie，不放开就一直登不上。
 * 3. **清数据**：localStorage / sessionStorage / IndexedDB 归 WebStorage 管，
 *    Dart 侧没有对应接口，"退出登录/换账号"就没法彻底清。
 *
 * 这三件都只是几行 Android API，所以直接开一条窄通道，不引第三方插件。
 */
class WebBridge(private val context: Context) {

    companion object {
        const val CHANNEL = "coomi/web"
    }

    fun configure(engine: FlutterEngine) {
        MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    // 把内存里的 cookie 立刻写盘。登录成功、页面加载完、
                    // 浏览器收起时各调一次，进程被杀也不丢登录态。
                    "flushCookies" -> {
                        try {
                            CookieManager.getInstance().flush()
                            result.success(true)
                        } catch (e: Throwable) {
                            result.error("FLUSH_FAILED", e.message, null)
                        }
                    }

                    // 允许第三方（跨站）cookie。setAcceptThirdPartyCookies 需要
                    // 具体的 WebView 实例，这里退一步用全局开关 + 让
                    // Dart 侧对当前 WebView 再单独放开一次。
                    "acceptCookies" -> {
                        try {
                            val accept = call.argument<Boolean>("accept") ?: true
                            CookieManager.getInstance().setAcceptCookie(accept)
                            result.success(true)
                        } catch (e: Throwable) {
                            result.error("ACCEPT_FAILED", e.message, null)
                        }
                    }

                    // 整站数据（localStorage / sessionStorage / IndexedDB / 缓存）。
                    // 相当于浏览器的"清除站点数据"。
                    "clearWebStorage" -> {
                        try {
                            WebStorage.getInstance().deleteAllData()
                            result.success(true)
                        } catch (e: Throwable) {
                            result.error("CLEAR_FAILED", e.message, null)
                        }
                    }

                    // 只清某个域的数据，换账号时用，不影响别的站点登录态。
                    "clearOrigin" -> {
                        try {
                            val origin = call.argument<String>("origin") ?: ""
                            if (origin.isEmpty()) {
                                result.error("BAD_ARGS", "origin 为空", null)
                            } else {
                                WebStorage.getInstance().deleteOrigin(origin)
                                result.success(true)
                            }
                        } catch (e: Throwable) {
                            result.error("CLEAR_FAILED", e.message, null)
                        }
                    }

                    // 读某个地址下的**全部** cookie，含 HttpOnly。
                    //
                    // 这条是关键：document.cookie 读不到 HttpOnly（cf_clearance、
                    // 各家的 session 票基本都是 HttpOnly），但 Android 的
                    // CookieManager 站在浏览器一侧，能原样给出来。
                    // 有了它，AI 才能把登录态导出去给别的工具用。
                    "getCookies" -> {
                        try {
                            val url = call.argument<String>("url") ?: ""
                            if (url.isEmpty()) {
                                result.error("BAD_ARGS", "url 为空", null)
                            } else {
                                result.success(cookiesFor(url))
                            }
                        } catch (e: Throwable) {
                            result.error("GET_FAILED", e.message, null)
                        }
                    }

                    // 写 cookie：value 是完整的 Set-Cookie 串
                    // （name=value; path=/; domain=…）。用来把别处拿到的
                    // 登录态灌进浏览器。
                    "setCookie" -> {
                        try {
                            val url = call.argument<String>("url") ?: ""
                            val value = call.argument<String>("value") ?: ""
                            if (url.isEmpty() || value.isEmpty()) {
                                result.error("BAD_ARGS", "url/value 为空", null)
                            } else {
                                CookieManager.getInstance().setCookie(url, value)
                                CookieManager.getInstance().flush()
                                result.success(true)
                            }
                        } catch (e: Throwable) {
                            result.error("SET_FAILED", e.message, null)
                        }
                    }

                    // 清全部 cookie。
                    //
                    // removeAllCookies 是**异步**的：以前紧接着 flush 再
                    // result.success，Dart 侧收到"已清完"时其实还没清完，
                    // 页面一刷新又把旧票读回来——这就是"要重启 APP 才生效"。
                    // 现在等回调真正回来再回话。
                    "clearCookies" -> {
                        try {
                            val cm = CookieManager.getInstance()
                            var replied = false
                            cm.removeAllCookies { removed ->
                                if (!replied) {
                                    replied = true
                                    try {
                                        cm.flush()
                                    } catch (_: Throwable) {
                                    }
                                    result.success(removed)
                                }
                            }
                            // 极少数机型不回调（内核实现差异）：兜一个超时，
                            // 否则 Dart 侧永远 await 不到，整条链就挂死。
                            android.os.Handler(android.os.Looper.getMainLooper())
                                .postDelayed({
                                    if (!replied) {
                                        replied = true
                                        try {
                                            cm.flush()
                                        } catch (_: Throwable) {
                                        }
                                        result.success(true)
                                    }
                                }, 1500)
                        } catch (e: Throwable) {
                            result.error("CLEAR_FAILED", e.message, null)
                        }
                    }

                    // 只清某个域的 cookie，等回调再回话（同上）。
                    "removeCookiesFor" -> {
                        try {
                            val host = call.argument<String>("host") ?: ""
                            if (host.isEmpty()) {
                                result.error("BAD_ARGS", "host 为空", null)
                            } else {
                                result.success(expireCookies(host))
                            }
                        } catch (e: Throwable) {
                            result.error("CLEAR_FAILED", e.message, null)
                        }
                    }

                    // 「清一个站、留住别人」的硬办法：整库清空 + 原样写回其它站。
                    //
                    // 为什么需要它：按 name 写一条过期 Set-Cookie 是"温柔删"，
                    // 对 **HttpOnly** 的登录票经常不生效（内核把这种写入当成
                    // 脚本来源看待，HttpOnly 条目不许覆盖）。现场表现就是
                    // reset 报"已清掉 N 个 Cookie"，回头一查 auth /
                    // authorization 原封不动还在，页面还是登录态；而
                    // removeAllCookies（整库清）一次就干净。
                    //
                    // 所以这里走内核唯一确定有效的那条路：先把整库读出来，
                    // removeAllCookies 清空，再把**不属于目标站**的条目连
                    // path / domain / Secure / HttpOnly / 过期时间一起写回去。
                    // 别的站点的登录态不受影响，目标站彻底没了。
                    "clearCookiesExcept" -> {
                        try {
                            val host = call.argument<String>("host") ?: ""
                            if (host.isEmpty()) {
                                result.error("BAD_ARGS", "host 为空", null)
                            } else {
                                clearExcept(host, result)
                            }
                        } catch (e: Throwable) {
                            result.error("CLEAR_FAILED", e.message, null)
                        }
                    }

                    // 把 cookie 库整个读出来。
                    //
                    // 为什么不能只靠 CookieManager.getCookie(url)：它只给
                    // **匹配这个 url 的 path** 的 cookie。很多站点把票放在
                    // /api、/eapi 这类子路径上（网易云的 MUSIC_A_T 就是），
                    // 站在首页问它，返回的是空——用户看到的就是"大多网站
                    // 获取的 cookie 都是空的"。
                    // 直接读内核自己的 SQLite 就没有这个盲区。
                    "dumpCookies" -> {
                        try {
                            val host = call.argument<String>("host") ?: ""
                            result.success(dumpCookies(host))
                        } catch (e: Throwable) {
                            result.error("DUMP_FAILED", e.message, null)
                        }
                    }

                    // 有没有 WebView 内核、版本多少：出问题时先看这个。
                    "engineInfo" -> {
                        val pkg = try {
                            WebView.getCurrentWebViewPackage()
                        } catch (_: Throwable) {
                            null
                        }
                        result.success(
                            mapOf(
                                "package" to (pkg?.packageName ?: ""),
                                "version" to (pkg?.versionName ?: ""),
                                "acceptCookie" to CookieManager.getInstance().acceptCookie(),
                            )
                        )
                    }

                    else -> result.notImplemented()
                }
            }
    }

    /// 读一个地址的 cookie，取不到就退一步换更宽的地址再问。
    ///
    /// getCookie 认的是"scheme + host + path"。传进来的常常是裸域名
    /// （`music.163.com`）或带一长串 query 的深链接，这两种情况内核直接
    /// 返回 null——不是没有 cookie，是问法不对。
    private fun cookiesFor(raw: String): String {
        val cm = CookieManager.getInstance()
        val candidates = LinkedHashSet<String>()
        candidates.add(raw)
        val normalized = if (raw.startsWith("http://") || raw.startsWith("https://")) {
            raw
        } else {
            "https://$raw"
        }
        candidates.add(normalized)
        try {
            val uri = android.net.Uri.parse(normalized)
            val host = uri.host
            if (!host.isNullOrEmpty()) {
                val scheme = uri.scheme ?: "https"
                candidates.add("$scheme://$host/")
                candidates.add("https://$host/")
                candidates.add("http://$host/")
            }
        } catch (_: Throwable) {
        }
        for (candidate in candidates) {
            val got = try {
                cm.getCookie(candidate)
            } catch (_: Throwable) {
                null
            }
            if (!got.isNullOrEmpty()) return got
        }
        return ""
    }

    /// 把某个域下的 cookie 逐条置过期。domain / path 的组合写全，
    /// 漏一种组合就清不掉那一条。
    /// 按库里的真实 host_key / path 逐条置过期，返回**真的少了几条**。
    ///
    /// ## 这里踩过的坑：Domain 属性不能乱加
    ///
    /// 以前每条都写三种 domain 变体（`host`、`.host`、`host_key`），以为"多写
    /// 几条总能命中一条"。恰恰相反：cookie 的删除要求
    /// **(host_key, name, path) 三者完全相同**，而只要 Set-Cookie 里带了
    /// `Domain=` 属性，内核就一定把它规范成"通配子域"cookie（host_key 前面带
    /// 点）。于是站点最常见的那种**host-only** 票
    /// （`Set-Cookie: auth=…; Path=/; HttpOnly; Secure`，没有 Domain）
    /// 永远删不到——写进去的过期 cookie 落在 `.host` 上，真票在 `host` 上，
    /// 两条各过各的。
    ///
    /// 现场就是这么翻车的：opencode.ai 的 `auth`、auth.opencode.ai 的
    /// `authorization` 都是 host-only，reset 报"已清掉 N 个 Cookie"（那个 N 是
    /// "库里有几条"，不是"删掉几条"），复查却发现两条原封不动，而
    /// logout（整库 removeAllCookies）一次就干净。
    ///
    /// 所以现在：host_key 带点才写 `Domain=`，不带点就一个字都不写；
    /// 并且返回值改成"清理前后条数之差"，删不掉就如实返回 0。
    private fun expireCookies(host: String): Int {
        val cm = CookieManager.getInstance()
        val rows = dumpCookies(host)
        if (rows.isEmpty()) return 0
        for (row in rows) {
            val name = row["name"] as? String ?: continue
            val hostKey = row["host"] as? String ?: host
            val path = (row["path"] as? String)?.ifEmpty { "/" } ?: "/"
            val secure = row["secure"] as? Boolean ?: false
            val bare = hostKey.trimStart('.')
            // host-only 的票不能带 Domain；通配子域的票必须带上原样的 host_key。
            val domainAttr = if (hostKey.startsWith(".")) "; domain=$hostKey" else ""
            val urls = if (secure) {
                listOf("https://$bare$path")
            } else {
                listOf("https://$bare$path", "http://$bare$path")
            }
            for (url in urls) {
                cm.setCookie(
                    url,
                    "$name=; expires=Thu, 01 Jan 1970 00:00:00 GMT; path=$path$domainAttr" +
                        (if (secure) "; Secure" else "")
                )
            }
        }
        cm.flush()
        // 报"真的少了几条"。以前报的是"库里有几条"，删不掉也照样报成功。
        val left = dumpCookies(host).size
        return (rows.size - left).coerceAtLeast(0)
    }

    /// 整库清空 + 写回"除目标站以外"的全部 cookie。
    ///
    /// 回给 Dart 三个数：cleared（目标站清掉几条）、restored（写回几条）、
    /// lost（值被内核加密、还不回去的条数）。lost 必须如实上报——那些站点
    /// 的用户要重新登录，闷着不说比清不掉更糟。
    private fun clearExcept(host: String, result: MethodChannel.Result) {
        val cm = CookieManager.getInstance()
        val all = dumpCookies("")
        val bare = host.trimStart('.').lowercase()
        fun belongsToTarget(hostKey: String): Boolean {
            val h = hostKey.trimStart('.').lowercase()
            return h == bare || h.endsWith(".$bare")
        }

        val keep = all.filter { !belongsToTarget((it["host"] as? String) ?: "") }
        val cleared = all.size - keep.size
        var replied = false
        fun finish() {
            if (replied) return
            replied = true
            var restored = 0
            var lost = 0
            for (row in keep) {
                val name = row["name"] as? String ?: continue
                val value = row["value"] as? String ?: ""
                val encrypted = row["encrypted"] as? Boolean ?: false
                if (encrypted || (value.isEmpty() && name.isEmpty())) {
                    lost++
                    continue
                }
                val hostKey = (row["host"] as? String) ?: continue
                val path = (row["path"] as? String)?.ifEmpty { "/" } ?: "/"
                val secure = row["secure"] as? Boolean ?: false
                val httpOnly = row["httpOnly"] as? Boolean ?: false
                val expires = row["expires"] as? Long ?: 0L
                val sb = StringBuilder("$name=$value; path=$path")
                // host_key 以点开头 = 通配子域，写回时要保留这个语义；
                // 不带点的是"只此主机"，不能写 domain=，否则会被放宽成通配。
                if (hostKey.startsWith(".")) sb.append("; domain=$hostKey")
                if (secure) sb.append("; Secure")
                if (httpOnly) sb.append("; HttpOnly")
                // Chromium 的 expires_utc 是 1601-01-01 起的微秒；0 = 会话 cookie。
                if (expires > 0) {
                    val ms = expires / 1000L - 11644473600000L
                    if (ms > System.currentTimeMillis()) {
                        val fmt = java.text.SimpleDateFormat(
                            "EEE, dd MMM yyyy HH:mm:ss 'GMT'",
                            java.util.Locale.US
                        )
                        fmt.timeZone = java.util.TimeZone.getTimeZone("GMT")
                        sb.append("; expires=${fmt.format(java.util.Date(ms))}")
                    }
                }
                val scheme = if (secure) "https" else "http"
                try {
                    cm.setCookie("$scheme://${hostKey.trimStart('.')}$path", sb.toString())
                    restored++
                } catch (_: Throwable) {
                    lost++
                }
            }
            try {
                cm.flush()
            } catch (_: Throwable) {
            }
            result.success(
                mapOf("cleared" to cleared, "restored" to restored, "lost" to lost)
            )
        }

        cm.removeAllCookies { finish() }
        // 少数内核不回调，兜个超时，否则 Dart 侧永远等不到。
        android.os.Handler(android.os.Looper.getMainLooper())
            .postDelayed({ finish() }, 2000)
    }

    /// 读内核的 cookie 库。只读一份拷贝：正在用的那个文件被 WebView
    /// 持有着（WAL），直接开会拿到半截数据或者干脆开不了。
    private fun dumpCookies(host: String): List<Map<String, Any?>> {
        val src = java.io.File(context.dataDir, "app_webview/Default/Cookies")
        if (!src.exists()) return emptyList()
        // 先 flush，否则刚登录进来的票还在内存里，库里读不到。
        try {
            CookieManager.getInstance().flush()
        } catch (_: Throwable) {
        }
        val copy = java.io.File(context.cacheDir, "cookies-dump.db")
        return try {
            src.copyTo(copy, overwrite = true)
            val db = android.database.sqlite.SQLiteDatabase.openDatabase(
                copy.absolutePath,
                null,
                android.database.sqlite.SQLiteDatabase.OPEN_READONLY
            )
            val out = mutableListOf<Map<String, Any?>>()
            db.use { d ->
                val where = if (host.isEmpty()) null else "host_key LIKE ? OR host_key LIKE ?"
                val bare = host.trimStart('.')
                val args = if (host.isEmpty()) null else arrayOf("%$bare", "%.$bare")
                d.query(
                    "cookies",
                    arrayOf(
                        "host_key", "name", "value", "path",
                        "is_secure", "is_httponly", "expires_utc", "encrypted_value"
                    ),
                    where, args, null, null, "host_key ASC"
                ).use { c ->
                    while (c.moveToNext()) {
                        val value = c.getString(2) ?: ""
                        val encLen = try {
                            c.getBlob(7)?.size ?: 0
                        } catch (_: Throwable) {
                            0
                        }
                        out.add(
                            mapOf(
                                "host" to (c.getString(0) ?: ""),
                                "name" to (c.getString(1) ?: ""),
                                // 值为空但有加密列 = 这台机器的内核加了密，
                                // 读不出明文，如实说明而不是给个空串糊过去。
                                "value" to if (value.isEmpty() && encLen > 0) "" else value,
                                "encrypted" to (value.isEmpty() && encLen > 0),
                                "path" to (c.getString(3) ?: "/"),
                                "secure" to (c.getInt(4) == 1),
                                "httpOnly" to (c.getInt(5) == 1),
                                "expires" to c.getLong(6),
                            )
                        )
                    }
                }
            }
            out
        } catch (_: Throwable) {
            emptyList()
        } finally {
            try {
                copy.delete()
            } catch (_: Throwable) {
            }
        }
    }
}
