package com.example.qinglong_flutter

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.provider.OpenableColumns
import android.util.Log
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.apache.commons.compress.archivers.tar.TarArchiveInputStream
import org.apache.commons.compress.compressors.gzip.GzipCompressorInputStream
import org.json.JSONObject
import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.BufferedReader
import java.io.File
import java.io.FileInputStream
import java.io.IOException
import java.io.FileOutputStream
import java.io.InputStream
import java.io.InputStreamReader
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

class ProotBridge(private val context: Context) {

    companion object {
        const val CHANNEL = "coomi/proot"
        const val EVENTS = "coomi/terminal"
        const val EVENTS_INSTALL = "coomi/install"

        /// 系统文件选择器（SAF）的请求码。挑一个不太可能撞上插件的值。
        const val REQUEST_IMPORT = 0x51A1
    }

    /// 拉起系统选择器需要 Activity。MainActivity 传的就是它自己，
    /// 别的宿主（后台 engine）拿不到 Activity 时这个功能直接报错，不静默失败。
    private val activity: Activity? get() = context as? Activity

    init {
        System.loadLibrary("qtermpty")
    }

    private external fun ptySpawn(cmd: Array<String>, env: Array<String>, cwd: String): Long
    private external fun ptyRead(handle: Long, buffer: ByteArray, offset: Int, length: Int): Int
    private external fun ptyWrite(handle: Long, data: ByteArray, offset: Int, length: Int): Int
    private external fun ptyClose(handle: Long)
    private external fun ptyWait(handle: Long): Int
    private external fun ptyKill(handle: Long)
    private external fun ptyResize(handle: Long, cols: Int, rows: Int): Int

    private val executor = Executors.newSingleThreadExecutor()

    /**
     * 跑用户命令**专用**的线程池。
     *
     * 以前 exec 和读文件、列目录、装运行时全挤在上面那个单线程池里：一条
     * `npm install` 跑三分钟，这三分钟里连"读一个文件"都排在它后面动不了，
     * 用户看到的就是"一个命令卡住，后面全都不用跑了，只能中断"。
     * 命令各跑各的线程，卡住的只有它自己。
     */
    private val execExecutor = Executors.newCachedThreadPool()

    /** 正在跑的命令数：卡住时用来告诉用户"是不是有别的命令占着"。 */
    private val runningExecs = java.util.concurrent.atomic.AtomicInteger(0)
    private var terminalProcess: Process? = null
    private var terminalHandle: Long = 0L

    private val mainHandler = Handler(Looper.getMainLooper())
    private var terminalSink: EventChannel.EventSink? = null
    private var installSink: EventChannel.EventSink? = null
    /// 安装是长任务，UI 可能中途重建；最后一次进度留着，重连后立刻回放。
    private var lastInstallEvent: Map<String, Any?>? = null
    private val pendingTerminalEvents = ArrayBlockingQueue<Map<String, Any?>>(1024)
    private val running = java.util.concurrent.atomic.AtomicBoolean(false)

    fun configure(engine: FlutterEngine) {
        MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "getStatus" -> handleGetStatus(result)
                "installRuntime" -> handleInstall(call, result)
                "exec" -> handleExec(call, result)
                "listFiles" -> handleListFiles(call, result)
                "readFile" -> handleReadFile(call, result)
                "writeFile" -> handleWriteFile(call, result)
                "appendFile" -> handleAppendFile(call, result)
                "deletePath" -> handleDeletePath(call, result)
                "makeDirectory" -> handleMakeDirectory(call, result)
                "movePath" -> handleMovePath(call, result)
                "copyPath" -> handleCopyPath(call, result)
                "setPermissions" -> handleSetPermissions(call, result)
                "statPath" -> handleStatPath(call, result)
                "searchFiles" -> handleSearchFiles(call, result)
                "listAppFiles" -> handleListAppFiles(call, result)
                "importFiles" -> handleImportFiles(call, result)
                "hostPath" -> handleHostPath(call, result)
                "openExternal" -> handleOpenExternal(call, result)
                "spawnTerminal" -> handleSpawnTerminal(result)
                "writeTerminal" -> handleWriteTerminal(call, result)
                "resizeTerminal" -> handleResizeTerminal(call, result)
                "stopTerminal" -> handleStopTerminal(result)
                else -> result.notImplemented()
            }
        }
        EventChannel(engine.dartExecutor.binaryMessenger, EVENTS_INSTALL).setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    installSink = events
                    lastInstallEvent?.let { event -> mainHandler.post { events?.success(event) } }
                }

                override fun onCancel(arguments: Any?) {
                    installSink = null
                }
            }
        )
        EventChannel(engine.dartExecutor.binaryMessenger, EVENTS).setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    terminalSink = events
                    drainPending(events)
                }

                override fun onCancel(arguments: Any?) {
                    terminalSink = null
                }
            }
        )
    }

    private fun runtimeRoot(): File = File(context.filesDir, "runtime-v2").apply { mkdirs() }

    private fun versionDir(version: String): File = File(runtimeRoot(), "versions/$version")

    private fun workspaceDir(): File = File(runtimeRoot(), "workspace").apply { mkdirs() }

    private fun homeDir(): File = File(runtimeRoot(), "home").apply { mkdirs() }

    private fun buildKitDir(): File = File(homeDir(), ".coomi-dev").apply { mkdirs() }

    private fun tmpDir(): File = File(runtimeRoot(), "tmp").apply { mkdirs() }

    private fun rootfsDir(version: String): File = File(versionDir(version), "rootfs")

    private fun prootBin(version: String): File = File(versionDir(version), "bin/proot")

    private fun prootLoaderPath(): String {
        val loader = File(context.applicationInfo.nativeLibraryDir, "libproot-loader.so")
        if (!loader.isFile) {
            throw IllegalStateException("PRoot loader missing: ${loader.absolutePath}")
        }
        return loader.absolutePath
    }

    /// 修好 guest 里的联网配置。每次启动终端 / 执行命令前都跑一遍（幂等）。
    ///
    /// 为什么必须做这件事：rootfs 是从 Debian 官方镜像打包来的，里面
    /// /etc/resolv.conf 指向 127.0.0.53——那是 systemd-resolved 的 stub。
    /// PRoot 里没有 systemd，也没人监听 53 端口，于是**所有域名都解析不了**，
    /// 表现就是 "apt-get update 失败 / 安装软件包失败：Temporary failure
    /// resolving 'deb.debian.org'"。同理 sources.list 指向 snapshot.debian.org
    /// （某个时间点的冻结快照），既慢又常年 404。
    ///
    /// 只在"内容明显不可用"时才改，用户自己配过的不动。
    private fun prepareGuestNetwork(version: String) {
        val rootfs = rootfsDir(version)
        if (!File(rootfs, "bin/sh").isFile) return
        try {
            val etc = File(rootfs, "etc").apply { mkdirs() }

            val resolv = File(etc, "resolv.conf")
            val current = if (resolv.isFile) resolv.readText() else ""
            // 127.0.0.x 的 stub 在 PRoot 里必然不通；空文件同样不通。
            val broken = current.isBlank() || current.contains("127.0.0.")
            if (broken) {
                resolv.writeText(
                    buildString {
                        appendLine("# 由青龙客户端写入：PRoot 内没有 systemd-resolved，")
                        appendLine("# 必须直接指向真实 DNS，否则 apt / pip / npm 全都解析失败。")
                        appendLine("nameserver 223.5.5.5")
                        appendLine("nameserver 119.29.29.29")
                        appendLine("nameserver 8.8.8.8")
                        appendLine("options timeout:2 attempts:2")
                    }
                )
            }

            val hosts = File(etc, "hosts")
            if (!hosts.isFile || hosts.readText().isBlank()) {
                hosts.writeText("127.0.0.1\tlocalhost\n::1\tlocalhost ip6-localhost ip6-loopback\n")
            }

            val nsswitch = File(etc, "nsswitch.conf")
            if (!nsswitch.isFile || !nsswitch.readText().contains("hosts:")) {
                nsswitch.writeText("hosts: files dns\npasswd: files\ngroup: files\nshadow: files\n")
            }

            // apt 源：snapshot 快照源换成正式源（国内走清华镜像，快且稳）。
            val sources = File(etc, "apt/sources.list")
            sources.parentFile?.mkdirs()
            val sourcesText = if (sources.isFile) sources.readText() else ""
            if (sourcesText.isBlank() || sourcesText.contains("snapshot.debian.org")) {
                sources.writeText(
                    buildString {
                        appendLine("# 由青龙客户端写入：原 snapshot.debian.org 是冻结快照，update 常年失败。")
                        appendLine("deb https://mirrors.tuna.tsinghua.edu.cn/debian bookworm main contrib non-free non-free-firmware")
                        appendLine("deb https://mirrors.tuna.tsinghua.edu.cn/debian bookworm-updates main contrib non-free non-free-firmware")
                        appendLine("deb https://mirrors.tuna.tsinghua.edu.cn/debian-security bookworm-security main contrib non-free non-free-firmware")
                    }
                )
                // 快照源留下的 .list 文件会盖掉上面的配置，一并清掉。
                File(etc, "apt/sources.list.d").listFiles()?.forEach { f ->
                    if (f.isFile && f.readText().contains("snapshot.debian.org")) f.delete()
                }
            }

            // 自愈 apt 包装器：装包前发现索引空/过期就自己先 update。
            //
            // rootfs 打包时把 /var/lib/apt/lists 清空了（不然镜像大一截），
            // 于是刚装好的环境里 apt 只认已经解包的那些包：
            // `apt-get install curl wget unzip` 会变成"curl 成功、
            // wget/unzip 报 Unable to locate package"——看着像源坏了，
            // 其实只差一条 update。用户没义务知道这件事，所以这里放一个
            // /usr/local/bin/apt-get（PATH 里排在 /usr/bin 前面）替他做掉。
            //
            // 三个要点：① 只在 install/build-dep 这类需要索引的子命令上触发；
            // ② 自己调 update 时直接走 /usr/bin/apt-get，不然会无限递归；
            // ③ 索引超过 7 天也刷一次，过期索引会给出 404 的包地址。
            val localBin = File(rootfs, "usr/local/bin").apply { mkdirs() }
            for (name in listOf("apt-get", "apt")) {
                val wrapper = File(localBin, name)
                val body = buildString {
                    appendLine("#!/bin/sh")
                    appendLine("# 由青龙客户端写入：装包前自动补 apt 索引。删掉它不影响其它功能。")
                    appendLine("real=/usr/bin/$name")
                    appendLine("[ -x \"\$real\" ] || exec /usr/bin/env $name \"\$@\"")
                    appendLine("need_update=0")
                    appendLine("case \" \$* \" in")
                    appendLine("  *\" install \"*|*\" build-dep \"*|*\" source \"*)")
                    appendLine("    if [ -z \"\$(ls -A /var/lib/apt/lists 2>/dev/null | grep -v -e '^lock\$' -e '^partial\$')\" ]; then")
                    appendLine("      need_update=1")
                    appendLine("    elif [ -z \"\$(find /var/lib/apt/lists -name '*Packages*' -mtime -7 2>/dev/null | head -n 1)\" ]; then")
                    appendLine("      need_update=1")
                    appendLine("    fi")
                    appendLine("    ;;")
                    appendLine("esac")
                    appendLine("# dpkg 上次被中断过（历史版本缺 -l 会必然中断）：先修好再装，")
                    appendLine("# 否则 apt 只会反复叫你手动跑 dpkg --configure -a。")
                    appendLine("if [ \"\$need_update\" != 2 ] && [ -e /var/lib/dpkg/updates ] && [ -n \"\$(ls -A /var/lib/dpkg/updates 2>/dev/null)\" ]; then")
                    appendLine("  echo '[青龙] 检测到上次 dpkg 未完成，正在自动修复…'")
                    appendLine("  dpkg --configure -a >/dev/null 2>&1 || true")
                    appendLine("fi")
                    appendLine("if [ \"\$need_update\" = 1 ]; then")
                    appendLine("  echo '[青龙] 软件包索引为空或已过期，先自动执行 apt-get update…'")
                    appendLine("  /usr/bin/apt-get update || echo '[青龙] update 失败，仍尝试继续安装'")
                    appendLine("fi")
                    appendLine("exec \"\$real\" \"\$@\"")
                }
                // 内容变了要覆盖（升级时修 bug），所以不做"存在即跳过"。
                if (!wrapper.isFile || wrapper.readText() != body) {
                    wrapper.writeText(body)
                }
                wrapper.setExecutable(true, false)
            }

            // apt 在手机上必须完全非交互，且 PRoot 下 sandbox 会失败。
            val aptConf = File(etc, "apt/apt.conf.d/99coomi")
            aptConf.parentFile?.mkdirs()
            if (!aptConf.isFile) {
                aptConf.writeText(
                    buildString {
                        appendLine("APT::Sandbox::User \"root\";")
                        appendLine("Acquire::Retries \"3\";")
                        appendLine("Dpkg::Options { \"--force-confdef\"; \"--force-confold\"; }")
                    }
                )
            }

            prepareGuestColors(rootfs)
        } catch (e: Exception) {
            Log.w("qtermnet", "prepareGuestNetwork failed: ${e.message}")
        }
    }

    /// 让 guest 里的输出真的有颜色。
    ///
    /// 为什么必须做：APP 侧给终端配了整套配色（One Dark 等 16 色 + 光标 + 选区），
    /// 但那只是"画板"——真正决定字是什么颜色的是 **guest 里的程序有没有输出
    /// ANSI 转义序列**。而这个 rootfs 里：
    ///   - /home/coomi 是我们自己造的空目录，没有 .bashrc / .profile，
    ///     所以 PS1 是默认的裸 `\s-\v\$`，一点颜色都没有；
    ///   - Debian 的 /etc/skel/.bashrc 里 `alias ls='ls --color'` 是**注释掉**的，
    ///     不显式打开的话 ls 输出纯白，目录和文件一个色；
    ///   - LS_COLORS 没导出，dircolors 也没人调。
    /// 结果就是用户看到的"背景有颜色，字还是单一色"。
    ///
    /// 这里补三件事：profile.d 里的全局配色脚本、给交互式 bash 的 .bashrc、
    /// 以及让登录 shell 真的去读 .bashrc 的 .bash_profile。
    /// 全部幂等：内容变了就覆盖我们自己那份，用户自己写的行只追加不删除。
    private fun prepareGuestColors(rootfs: File) {
        val marker = "# coomi-color-v1"
        val colorScript = buildString {
            appendLine("#!/bin/sh")
            appendLine(marker)
            appendLine("# 由青龙客户端写入：给终端输出上色。删掉它只会让输出变成单色。")
            appendLine("[ -n \"\$TERM\" ] || TERM=xterm-256color")
            appendLine("export TERM")
            appendLine("# TERM=dumb（管道、某些构建脚本）时不要上色，颜色码会污染输出。")
            appendLine("# 注意这里不能用 return/exit：这个文件是被 login shell source 的，")
            appendLine("# 一个失败的 return 会顺势 exit 掉整个会话，终端直接黑屏。")
            appendLine("if [ \"\$TERM\" != dumb ]; then")
            appendLine("# ls 的目录蓝、可执行绿、压缩包红全靠 LS_COLORS。")
            appendLine("if command -v dircolors >/dev/null 2>&1; then")
            appendLine("  if [ -r \"\$HOME/.dircolors\" ]; then")
            appendLine("    eval \"\$(dircolors -b \"\$HOME/.dircolors\" 2>/dev/null)\"")
            appendLine("  else")
            appendLine("    eval \"\$(dircolors -b 2>/dev/null)\"")
            appendLine("  fi")
            appendLine("fi")
            appendLine("[ -n \"\$LS_COLORS\" ] || export LS_COLORS='di=1;34:ln=1;36:so=1;35:pi=33:ex=1;32:bd=1;33:cd=1;33:su=37;41:sg=30;43:tw=30;42:ow=34;42:st=37;44:*.tar=1;31:*.tgz=1;31:*.zip=1;31:*.gz=1;31:*.xz=1;31:*.zst=1;31:*.bz2=1;31:*.7z=1;31:*.deb=1;31:*.rpm=1;31:*.jpg=1;35:*.png=1;35:*.gif=1;35:*.svg=1;35:*.mp4=1;35:*.mp3=36:*.json=33:*.yml=33:*.yaml=33:*.md=36:*.js=93:*.ts=93:*.py=93:*.sh=1;32'")
            appendLine("export CLICOLOR=1")
            appendLine("# grep/diff/ip 的高亮要显式打开，默认是关的。")
            appendLine("export GREP_COLORS='ms=01;31:mc=01;31:sl=:cx=:fn=35:ln=32:bn=32:se=36'")
            appendLine("# less/man 的加粗与下划线换成有颜色的（读 man 页不再一片白）。")
            appendLine("export LESS='-R'")
            appendLine("export LESS_TERMCAP_mb=\$(printf '\\033[1;31m')")
            appendLine("export LESS_TERMCAP_md=\$(printf '\\033[1;36m')")
            appendLine("export LESS_TERMCAP_me=\$(printf '\\033[0m')")
            appendLine("export LESS_TERMCAP_so=\$(printf '\\033[30;43m')")
            appendLine("export LESS_TERMCAP_se=\$(printf '\\033[0m')")
            appendLine("export LESS_TERMCAP_us=\$(printf '\\033[1;32m')")
            appendLine("export LESS_TERMCAP_ue=\$(printf '\\033[0m')")
            appendLine("# 让常见工具默认带色。alias 只在交互式 shell 里有意义，")
            appendLine("# 但写在这里对 sh/bash 都生效，脚本里用 \\ls 可绕过。")
            appendLine("alias ls='ls --color=auto'")
            appendLine("alias ll='ls -lh --color=auto'")
            appendLine("alias la='ls -lha --color=auto'")
            appendLine("alias l='ls -CF --color=auto'")
            appendLine("alias dir='dir --color=auto'")
            appendLine("alias grep='grep --color=auto'")
            appendLine("alias egrep='egrep --color=auto'")
            appendLine("alias fgrep='fgrep --color=auto'")
            appendLine("alias diff='diff --color=auto'")
            appendLine("alias ip='ip -color=auto'")
            appendLine("fi")
        }
        val profileD = File(rootfs, "etc/profile.d").apply { mkdirs() }
        writeIfChanged(File(profileD, "00-coomi-color.sh"), colorScript, executable = true)

        // 交互式 bash 的配置。PS1 里的转义必须用 \[ \] 包住，
        // 否则 bash 会把颜色码算进行宽，长命令换行时光标位置全乱。
        val bashrc = buildString {
            appendLine(marker)
            appendLine("# 由青龙客户端写入：交互式 shell 的配色与提示符。")
            appendLine("case \$- in *i*) ;; *) return ;; esac")
            appendLine("for f in /etc/profile.d/*.sh; do [ -r \"\$f\" ] && . \"\$f\"; done")
            appendLine("HISTSIZE=2000")
            appendLine("HISTFILESIZE=4000")
            appendLine("HISTCONTROL=ignoreboth")
            appendLine("shopt -s histappend checkwinsize 2>/dev/null")
            appendLine("# 上下键按已输入前缀翻历史，手机上少打很多字。")
            appendLine("bind '\"\\e[A\": history-search-backward' 2>/dev/null")
            appendLine("bind '\"\\e[B\": history-search-forward' 2>/dev/null")
            appendLine("# 提示符：绿色身份 + 蓝色路径 + 上一条命令失败时变红的箭头。")
            appendLine("__coomi_ps1() {")
            appendLine("  local code=\$?")
            appendLine("  local arrow='\\[\\033[38;5;114m\\]❯'")
            appendLine("  [ \$code -ne 0 ] && arrow='\\[\\033[38;5;203m\\]❯'")
            appendLine("  PS1=\"\\[\\033[38;5;114m\\]\\u\\[\\033[38;5;245m\\]@\\[\\033[38;5;180m\\]coomi\\[\\033[0m\\] \\[\\033[38;5;75m\\]\\w\\[\\033[0m\\]\\n\$arrow\\[\\033[0m\\] \"")
            appendLine("}")
            appendLine("PROMPT_COMMAND='__coomi_ps1'")
            appendLine("[ -f \"\$HOME/.bashrc.local\" ] && . \"\$HOME/.bashrc.local\"")
        }
        val profile = buildString {
            appendLine(marker)
            appendLine("# 由青龙客户端写入：登录 shell 也要读 .bashrc。")
            appendLine("[ -f /etc/profile ] && . /etc/profile")
            appendLine("[ -f \"\$HOME/.bashrc\" ] && . \"\$HOME/.bashrc\"")
        }

        // guest 的 /home/coomi 与 root 家目录：两边都放，不管以谁的身份进来都有色。
        val homes = listOf(homeDir(), File(rootfs, "root"))
        for (home in homes) {
            if (!home.exists() && !home.mkdirs()) continue
            appendOurBlock(File(home, ".bashrc"), bashrc, marker)
            appendOurBlock(File(home, ".bash_profile"), profile, marker)
            appendOurBlock(File(home, ".profile"), profile, marker)
        }

        // readline 的补全列表也能上色（colored-stats 用的就是 LS_COLORS），
        // 顺手把手机上最难受的几件事调顺：忽略大小写补全、一次列全、不响铃。
        val inputrc = buildString {
            appendLine(marker)
            appendLine("# 由青龙客户端写入：补全列表上色 + 手机友好的补全行为。")
            appendLine("\$include /etc/inputrc")
            appendLine("set colored-stats on")
            appendLine("set colored-completion-prefix on")
            appendLine("set completion-ignore-case on")
            appendLine("set show-all-if-ambiguous on")
            appendLine("set menu-complete-display-prefix on")
            appendLine("set bell-style none")
        }
        for (home in homes) {
            if (!home.isDirectory) continue
            appendOurBlock(File(home, ".inputrc"), inputrc, marker)
        }
    }

    /// 内容不同才写。避免每次启动都无意义地动文件（也就不会打乱 mtime）。
    private fun writeIfChanged(file: File, body: String, executable: Boolean = false) {
        try {
            if (!file.isFile || file.readText() != body) {
                file.parentFile?.mkdirs()
                file.writeText(body)
            }
            if (executable) file.setExecutable(true, false)
        } catch (e: Exception) {
            Log.w("qtermnet", "write ${file.name} failed: ${e.message}")
        }
    }

    /// 把我们那一段配置写进用户的 rc 文件里。
    ///
    /// 用 begin/end 双标记夹住自己的块：升级时只替换这两行之间的内容，
    /// 用户在块前后自己加的东西一律原样保留。只有一个标记都没有时才追加。
    private fun appendOurBlock(file: File, body: String, marker: String) {
        val begin = "$marker begin"
        val end = "$marker end"
        val block = buildString {
            appendLine(begin)
            append(body)
            if (!body.endsWith("\n")) appendLine()
            appendLine(end)
        }
        try {
            if (!file.isFile) {
                file.parentFile?.mkdirs()
                file.writeText(block)
                return
            }
            val current = file.readText()
            val from = current.indexOf(begin)
            val to = current.indexOf(end)
            if (from < 0 || to < from) {
                // 没有我们的块：追加到末尾，不动原有内容。
                if (current.contains(body.trim())) return
                file.writeText(
                    buildString {
                        append(current)
                        if (!current.endsWith("\n")) appendLine()
                        appendLine()
                        append(block)
                    }
                )
                return
            }
            val tailStart = to + end.length
            val replaced = current.substring(0, from) + block.trimEnd('\n') +
                current.substring(tailStart)
            if (replaced == current) return
            file.writeText(replaced)
        } catch (e: Exception) {
            Log.w("qtermnet", "patch ${file.name} failed: ${e.message}")
        }
    }

    private fun ensureProotExecutable(version: String) {
        val proot = prootBin(version)
        if (!proot.isFile) throw IllegalStateException("PRoot binary missing: ${proot.absolutePath}")
        // 双保险：Java API + chmod，避免 tar 解包/重命名后丢失执行位。
        proot.setExecutable(true, false)
        proot.setReadable(true, false)
        try {
            ProcessBuilder("chmod", "755", proot.absolutePath)
                .redirectErrorStream(true)
                .start()
                .waitFor()
        } catch (e: Exception) {
            // chmod 失败不致命，继续尝试启动。
        }
        repairRootfsExecutable(version)
        if (!proot.canExecute()) {
            throw IllegalStateException("PRoot binary not executable: ${proot.absolutePath}")
        }
    }

    private fun repairRootfsExecutable(version: String) {
        val rootfs = rootfsDir(version)
        val marker = File(versionDir(version), ".perms_fixed_v2")
        if (!rootfs.isDirectory || marker.isFile) return
        Log.i("qtermpty", "repair rootfs executable permissions start")
        // 一次 chmod -R 755：把 rootfs 里所有可执行文件/目录权限全部补齐。
        // 之前用 File.setExecutable 在 symlink 场景下不可靠，统一交给 chmod。
        try {
            val p = ProcessBuilder("chmod", "-R", "755", rootfs.absolutePath)
                .redirectErrorStream(true)
                .start()
            p.waitFor()
            Log.i("qtermpty", "chmod -R exit=${p.exitValue()}")
        } catch (e: Exception) {
            Log.e("qtermpty", "chmod -R failed", e)
        }
        try { marker.createNewFile() } catch (e: Exception) {}
        Log.i("qtermpty", "repair rootfs executable permissions done")
    }

    private fun readManifest(): JSONObject {
        val input: InputStream = context.assets.open("runtime-v2-manifest.json")
        return JSONObject(input.bufferedReader(Charsets.UTF_8).use { it.readText() })
    }

    private fun handleGetStatus(result: MethodChannel.Result) {
        try {
            val manifest = readManifest()
            val version = manifest.getString("runtime_version")
            val versionRoot = versionDir(version)
            val installed = prootBin(version).isFile && File(versionRoot, "rootfs/bin/sh").isFile
            result.success(
                mapOf(
                    "installed" to installed,
                    "version" to version,
                    "runtimeRoot" to runtimeRoot().absolutePath,
                    "workspace" to workspaceDir().absolutePath,
                )
            )
        } catch (e: Exception) {
            result.success(mapOf("installed" to false, "version" to "", "runtimeRoot" to runtimeRoot().absolutePath, "workspace" to workspaceDir().absolutePath))
        }
    }

    private fun handleInstall(call: MethodCall, result: MethodChannel.Result) {
        executor.execute {
            try {
                // clean=true 表示"彻底重装"：连缓存的下载包一起删掉重新拉。
                // 平时重装只需重新解压（快得多），只有怀疑下载包坏了才用 clean。
                val clean = call.argument<Boolean>("clean") ?: false
                val manifest = readManifest()
                val version = manifest.getString("runtime_version")
                val downloads = File(runtimeRoot(), "downloads").apply { mkdirs() }
                if (clean) {
                    emitInstall("清理旧的下载缓存")
                    deleteRecursive(downloads)
                    downloads.mkdirs()
                }
                emitInstall("准备下载")
                val hostFile = downloadArtifact(
                    manifest.getJSONObject("host"),
                    File(downloads, "proot-host-arm64.tar.gz"),
                    "下载 PRoot 主机组件",
                )
                val rootfsFile = downloadArtifact(
                    manifest.getJSONObject("rootfs"),
                    File(downloads, "debian-rootfs-arm64.tar.gz"),
                    "下载 Debian 根文件系统",
                )

                val staging = File(File(runtimeRoot(), "versions"), "$version.staging")
                deleteRecursive(staging)
                staging.mkdirs()

                emitInstall("解压 PRoot 主机组件")
                extractTarGz(hostFile, staging)
                emitInstall("解压 Debian 根文件系统（约 1 分钟）")
                extractTarGz(rootfsFile, File(staging, "rootfs"))

                val proot = File(staging, "bin/proot")
                if (!proot.isFile) throw IllegalStateException("PRoot host archive has no bin/proot")
                proot.setExecutable(true, false)
                if (!File(staging, "rootfs/bin/sh").isFile) throw IllegalStateException("rootfs extraction incomplete")

                val target = File(File(runtimeRoot(), "versions"), version)
                if (target.exists()) deleteRecursive(target)
                if (!staging.renameTo(target)) throw IllegalStateException("cannot activate runtime version")
                emitInstall("配置可执行权限")
                ensureProotExecutable(version)

                emitInstall("安装完成", done = true)
                result.success(mapOf("ok" to true, "version" to version, "rootfs" to File(target, "rootfs").absolutePath))
            } catch (e: Exception) {
                emitInstall("安装失败", done = true, error = e.message ?: e.toString())
                result.error("install_failed", e.message ?: e.toString(), null)
            }
        }
    }

    private fun downloadArtifact(artifact: JSONObject, dest: File, label: String): File {
        val expectedSha256 = artifact.getString("sha256").lowercase()
        val expectedSize = artifact.getLong("size")
        if (dest.isFile) {
            emitInstall("$label · 校验已下载文件", dest.length(), dest.length())
            if (sha256(dest) == expectedSha256) {
                emitInstall("$label · 已就绪", expectedSize, expectedSize)
                return dest
            }
        }

        val url = URL(artifact.getString("url"))
        val tmp = File(dest.parentFile, "${dest.name}.download")
        val connection = url.openConnection() as HttpURLConnection
        connection.setRequestProperty("User-Agent", "qinglong-flutter")
        connection.connectTimeout = 20_000
        connection.readTimeout = 120_000
        connection.instanceFollowRedirects = true
        try {
            connection.connect()
            if (connection.responseCode !in 200..299) {
                throw IOException("下载失败 HTTP ${connection.responseCode}")
            }
            val declared = connection.contentLengthLong
            val total = if (declared > 0) declared else expectedSize
            val input = BufferedInputStream(connection.inputStream)
            val output = BufferedOutputStream(FileOutputStream(tmp))
            val buffer = ByteArray(64 * 1024)
            var read: Int
            var received = 0L
            var lastEmit = 0L
            emitInstall(label, 0, total)
            while (input.read(buffer).also { read = it } != -1) {
                output.write(buffer, 0, read)
                received += read
                // 每 250ms 报一次就够了，别把消息通道刷爆。
                val now = System.currentTimeMillis()
                if (now - lastEmit >= 250) {
                    lastEmit = now
                    emitInstall(label, received, total)
                }
            }
            output.close()
            input.close()
            emitInstall(label, received, total)
        } finally {
            connection.disconnect()
        }
        if (tmp.length() != artifact.getLong("size")) {
            throw IOException("下载大小不匹配：${tmp.length()} != ${artifact.getLong("size")}")
        }
        emitInstall("$label · 校验完整性", tmp.length(), tmp.length())
        if (sha256(tmp) != expectedSha256) {
            throw IOException("SHA-256 校验失败")
        }
        if (dest.exists()) dest.delete()
        if (!tmp.renameTo(dest)) throw IOException("无法移动下载文件")
        return dest
    }

    private fun sha256(file: File): String {
        val digest = MessageDigest.getInstance("SHA-256")
        BufferedInputStream(FileInputStream(file)).use { input ->
            val buffer = ByteArray(64 * 1024)
            var read: Int
            while (input.read(buffer).also { read = it } != -1) {
                digest.update(buffer, 0, read)
            }
        }
        return digest.digest().joinToString("") { "%02x".format(it) }
    }

    private fun extractTarGz(archive: File, destination: File) {
        destination.mkdirs()
        val tar = TarArchiveInputStream(GzipCompressorInputStream(BufferedInputStream(FileInputStream(archive))))
        tar.use { input ->
            var entry = input.nextTarEntry
            while (entry != null) {
                val name = entry.name.trimStart('/').trimStart('.').trimStart('/')
                val target = File(destination, name)
                when {
                    entry.isDirectory -> target.mkdirs()
                    entry.isSymbolicLink -> {
                        target.parentFile?.mkdirs()
                        val link = entry.linkName
                        // Android toybox ln 可用，避免直接使用 java.nio.file（低 API 不保证）。
                        ProcessBuilder("ln", "-s", link, target.absolutePath)
                            .redirectErrorStream(true)
                            .start()
                            .waitFor()
                    }
                    entry.isFile -> {
                        target.parentFile?.mkdirs()
                        BufferedOutputStream(FileOutputStream(target)).use { out ->
                            val buffer = ByteArray(64 * 1024)
                            var read: Int
                            while (input.read(buffer).also { read = it } != -1) {
                                out.write(buffer, 0, read)
                            }
                        }
                        if ((entry.mode and 0x40) != 0) {
                            target.setExecutable(true, false)
                        }
                    }
                    // 设备节点等特殊项跳过。
                    else -> {}
                }
                entry = input.nextTarEntry
            }
        }
    }

    private fun deleteRecursive(file: File) {
        if (file.isDirectory) {
            file.listFiles()?.forEach { deleteRecursive(it) }
        }
        file.delete()
    }

    private fun buildProotArgs(version: String, guestCommand: String, guestArgs: List<String>): List<String> {
        val proot = prootBin(version)
        val rootfs = rootfsDir(version)
        val workspace = workspaceDir()
        val home = homeDir()
        val buildKit = buildKitDir()
        val tmp = tmpDir()
        return buildList {
            // targetSdk 29+ 禁止直接 exec app 私有目录里的 ELF；改由系统 linker 加载，绕开 W^X 限制。
            add("/system/bin/linker64")
            add(proot.absolutePath)
            add("--kill-on-exit")
            // 硬链接转软链接。Android 的 SELinux 不给 app 进程 link 权限，
            // guest 里任何 ln 都是 Permission denied（/tmp、/workspace 也一样），
            // 而 dpkg 每次装包都要 link() 一份 /var/lib/dpkg/status-old 做备份——
            // 于是"apt-get install 装一半就中断、再装报 dpkg was interrupted"。
            // -l 让 proot 把 link() 翻译成符号链接，dpkg 就能正常收尾。
            add("-l")
            add("-0")
            add("-r"); add(rootfs.absolutePath)
            add("-b"); add("${workspace.absolutePath}:/workspace")
            add("-b"); add("${home.absolutePath}:/home/coomi")
            add("-b"); add("${buildKit.absolutePath}:/opt/coomi-dev")
            add("-b"); add("${tmp.absolutePath}:/tmp")
            add("-b"); add("${proot.absolutePath}:/usr/local/bin/proot")
            add("-b"); add("/proc")
            add("-b"); add("/dev")
            add("-w"); add("/workspace")
            add("/usr/bin/env"); add("-i")
            add("HOME=/home/coomi")
            add("PATH=/opt/coomi-dev/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin")
            add("TMPDIR=/tmp")
            add("COOMI_RUNTIME_BACKEND=proot_linux")
            add("COOMI_BUILD_KIT=/opt/coomi-dev")
            add("COOMI_PROOT_HOST=/usr/local/bin/proot")
            add("LANG=C.UTF-8")
            add("SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt")
            // 手机上没法回答 apt 的交互式提问（重启服务？保留配置？），
            // 不掐掉的话装包会卡在一个看不见的问句上，表现为"安装失败/无响应"。
            add("DEBIAN_FRONTEND=noninteractive")
            add("TERM=xterm-256color")
            add(guestCommand)
            addAll(guestArgs)
        }
    }

    private fun processBuilderFor(command: List<String>, version: String): ProcessBuilder {
        val pb = ProcessBuilder(command)
        pb.directory(workspaceDir())
        val env = pb.environment()
        env["PROOT_TMP_DIR"] = tmpDir().absolutePath
        env["LD_LIBRARY_PATH"] = File(versionDir(version), "lib").absolutePath
        // targetSdk 29+ 的 SELinux W^X 禁止 execve app_data_file（rootfs 内的 ELF），
        // 且 PRoot 默认把内置 loader 解压到 files 目录后同样被拒绝。
        // 解法：用 PROOT_LOADER 指向 nativeLibraryDir 里的 loader（apk_data_file，允许 execve）。
        env["PROOT_LOADER"] = prootLoaderPath()
        env["PROOT_NO_SECCOMP"] = "1"
        return pb
    }

    /// guest 路径 → 宿主真实目录。终端里看到的 /workspace 等挂载点，
    /// 在 APP 文件管理里用同一套路径表示，保证两侧看到的是同一份文件。
    /// 注意顺序：具体挂载点必须排在 "/" 之前，否则前缀匹配会先命中根。
    private val guestMounts: List<Pair<String, () -> File>>
        get() = listOf(
            "/workspace" to { workspaceDir() },
            "/home/coomi" to { homeDir() },
            "/opt/coomi-dev" to { buildKitDir() },
            "/cache" to { context.cacheDir.apply { mkdirs() } },
            "/tmp" to { tmpDir() },
            // rootfs 根：装好 Runtime 后可以一路浏览到 /etc、/usr、/var，
            // 用户要"管理到根目录级别"就是这个。没装则不暴露。
            "/" to { installedRootfs() },
        )

    /// 当前已安装版本的 rootfs 目录；没装就抛，调用方会得到明确错误。
    private fun installedRootfs(): File {
        val version = readManifest().getString("runtime_version")
        val dir = rootfsDir(version)
        if (!File(dir, "bin/sh").isFile) {
            throw IllegalStateException("Runtime 未安装，无法浏览根目录")
        }
        return dir
    }

    /// 根目录是否可用（用于列表里决定是否给出 "/" 这个根入口）。
    private fun rootfsAvailable(): Boolean = try {
        installedRootfs()
        true
    } catch (e: Exception) {
        false
    }

    /// 对外暴露的根入口列表：Runtime 没装时不给 "/"，免得点进去就报错。
    private fun visibleRoots(): List<String> =
        guestMounts.map { it.first }.filter { it != "/" || rootfsAvailable() }

    private fun resolveGuestPath(rawPath: String): File {
        val path = rawPath.trim().ifEmpty { "/workspace" }
        if (!path.startsWith("/")) throw IllegalArgumentException("路径必须以 / 开头：$path")
        val normalized = path.trimEnd('/').ifEmpty { "/" }
        for ((mount, hostDir) in guestMounts) {
            // mount == "/" 时 "$mount/" 会变成 "//"，前缀匹配永远不成立，
            // 所以根挂载单独判：任何以 / 开头的路径都落在它下面。
            val matches = if (mount == "/") true
            else normalized == mount || normalized.startsWith("$mount/")
            if (matches) {
                val relative = normalized.removePrefix(mount).trimStart('/')
                val root = hostDir()
                val target = if (relative.isEmpty()) root else File(root, relative)
                val rootPath = root.canonicalPath
                val targetPath = target.canonicalFile.path
                if (targetPath != rootPath && !targetPath.startsWith("$rootPath/")) {
                    throw IllegalArgumentException("路径越界：$path")
                }
                return target
            }
        }
        throw IllegalArgumentException("非法路径：$path")
    }

    private fun guestPathOf(file: File): String {
        val canonical = file.canonicalFile.path
        for ((mount, hostDir) in guestMounts) {
            // Runtime 没装时根挂载会抛，跳过即可，别让整个列目录失败。
            val rootPath = try {
                hostDir().canonicalPath
            } catch (e: Exception) {
                continue
            }
            if (canonical == rootPath) return mount
            if (canonical.startsWith("$rootPath/")) {
                val rest = canonical.removePrefix(rootPath)
                return if (mount == "/") rest else mount + rest
            }
        }
        return canonical
    }

    private fun fileEntry(file: File): Map<String, Any?> = mapOf(
        "name" to file.name,
        "path" to guestPathOf(file),
        "isDirectory" to file.isDirectory,
        "size" to if (file.isDirectory) 0L else file.length(),
        "modified" to file.lastModified(),
        // Android 上没有 chmod 的完整语义（拿不到组/其他位），
        // 只暴露 owner 的 rwx —— 这是 app 沙箱里唯一真正可控的部分。
        "readable" to file.canRead(),
        "writable" to file.canWrite(),
        "executable" to file.canExecute(),
        "hidden" to file.name.startsWith("."),
    )

    private fun handleListFiles(call: MethodCall, result: MethodChannel.Result) {
        executor.execute {
            try {
                val dir = resolveGuestPath(call.argument<String>("path") ?: "/workspace")
                if (!dir.exists()) dir.mkdirs()
                if (!dir.isDirectory) throw IllegalArgumentException("不是目录：${guestPathOf(dir)}")
                val children = (dir.listFiles() ?: emptyArray())
                    .sortedWith(compareByDescending<File> { it.isDirectory }.thenBy { it.name.lowercase() })
                    .map(::fileEntry)
                result.success(
                    mapOf(
                        "path" to guestPathOf(dir),
                        "roots" to visibleRoots(),
                        "entries" to children,
                    )
                )
            } catch (e: Exception) {
                result.error("list_failed", e.message ?: e.toString(), null)
            }
        }
    }

    /// 按作用域解析路径。
    ///
    /// 为什么不能只靠路径本身判断：guest 的 /workspace 物理上就在 filesDir 下，
    /// 两套树在磁盘上是嵌套的，光看字符串分不出调用方指的是哪一套。
    /// 所以谁调用谁带 scope。
    private fun resolveScoped(raw: String, scope: String?): File =
        if (scope == "app") resolveAppPath(raw) else resolveGuestPath(raw)

    /// 回报路径时也要跟着作用域：app 树报宿主绝对路径，guest 树报挂载点路径。
    private fun pathOf(file: File, scope: String?): String =
        if (scope == "app") file.canonicalPath else guestPathOf(file)

    private fun entryOf(file: File, scope: String?): Map<String, Any?> =
        if (scope == "app") appFileEntry(file) else fileEntry(file)

    private fun handleReadFile(call: MethodCall, result: MethodChannel.Result) {
        executor.execute {
            try {
                val scope = call.argument<String>("scope")
                val file = resolveScoped(call.argument<String>("path") ?: "", scope)
                if (!file.isFile) throw IllegalArgumentException("文件不存在：${pathOf(file, scope)}")
                val maxBytes = (call.argument<Number>("maxBytes")?.toLong() ?: 1_048_576L)
                if (file.length() > maxBytes) {
                    throw IllegalArgumentException("文件过大（${file.length()} 字节），请在终端里处理")
                }
                result.success(
                    mapOf(
                        "path" to pathOf(file, scope),
                        "content" to file.readText(Charsets.UTF_8),
                        "size" to file.length(),
                    )
                )
            } catch (e: Exception) {
                result.error("read_failed", e.message ?: e.toString(), null)
            }
        }
    }

    private fun handleWriteFile(call: MethodCall, result: MethodChannel.Result) {
        executor.execute {
            try {
                val scope = call.argument<String>("scope")
                val file = resolveScoped(call.argument<String>("path") ?: "", scope)
                val content = call.argument<String>("content") ?: ""
                file.parentFile?.mkdirs()
                file.writeText(content, Charsets.UTF_8)
                result.success(entryOf(file, scope))
            } catch (e: Exception) {
                result.error("write_failed", e.message ?: e.toString(), null)
            }
        }
    }

    private fun handleAppendFile(call: MethodCall, result: MethodChannel.Result) {
        executor.execute {
            try {
                val scope = call.argument<String>("scope")
                val file = resolveScoped(call.argument<String>("path") ?: "", scope)
                val content = call.argument<String>("content") ?: ""
                file.parentFile?.mkdirs()
                // 追加大文件的分块写入：不经过 shell 命令，不会撞“命令过长”。
                file.appendText(content, Charsets.UTF_8)
                result.success(entryOf(file, scope))
            } catch (e: Exception) {
                result.error("append_failed", e.message ?: e.toString(), null)
            }
        }
    }

    private fun handleCopyPath(call: MethodCall, result: MethodChannel.Result) {
        executor.execute {
            try {
                val scope = call.argument<String>("scope")
                val from = resolveScoped(call.argument<String>("from") ?: "", scope)
                val to = resolveScoped(call.argument<String>("to") ?: "", scope)
                if (!from.exists()) throw IllegalArgumentException("源不存在：${pathOf(from, scope)}")
                if (to.exists()) throw IllegalArgumentException("目标已存在：${pathOf(to, scope)}")
                // 防止把目录复制到自己内部造成无限递归。
                if (from.isDirectory && to.canonicalPath.startsWith(from.canonicalPath + "/")) {
                    throw IllegalArgumentException("不能把目录复制到它自己里面")
                }
                from.copyRecursively(to, overwrite = false)
                result.success(entryOf(to, scope))
            } catch (e: Exception) {
                result.error("copy_failed", e.message ?: e.toString(), null)
            }
        }
    }

    private fun handleSetPermissions(call: MethodCall, result: MethodChannel.Result) {
        executor.execute {
            try {
                val scope = call.argument<String>("scope")
                val file = resolveScoped(call.argument<String>("path") ?: "", scope)
                if (!file.exists()) throw IllegalArgumentException("不存在：${pathOf(file, scope)}")
                val readable = call.argument<Boolean>("readable")
                val writable = call.argument<Boolean>("writable")
                val executable = call.argument<Boolean>("executable")
                // ownerOnly=false：连带设置组/其他位，PRoot guest 里跑脚本才有意义。
                readable?.let { if (!file.setReadable(it, false)) throw IOException("设置读权限失败") }
                writable?.let { if (!file.setWritable(it, false)) throw IOException("设置写权限失败") }
                executable?.let { if (!file.setExecutable(it, false)) throw IOException("设置执行权限失败") }
                result.success(entryOf(file, scope))
            } catch (e: Exception) {
                result.error("chmod_failed", e.message ?: e.toString(), null)
            }
        }
    }

    private fun handleStatPath(call: MethodCall, result: MethodChannel.Result) {
        executor.execute {
            try {
                val scope = call.argument<String>("scope")
                val file = resolveScoped(call.argument<String>("path") ?: "", scope)
                if (!file.exists()) throw IllegalArgumentException("不存在：${pathOf(file, scope)}")
                val entry = entryOf(file, scope).toMutableMap()
                if (file.isDirectory) {
                    // 目录递归统计：大目录也要给个数字，否则用户不知道占多少。
                    var bytes = 0L
                    var files = 0
                    var dirs = 0
                    file.walkTopDown().forEach {
                        if (it == file) return@forEach
                        if (it.isDirectory) dirs++ else { files++; bytes += it.length() }
                    }
                    entry["totalBytes"] = bytes
                    entry["fileCount"] = files
                    entry["dirCount"] = dirs
                } else {
                    entry["totalBytes"] = file.length()
                }
                entry["hostPath"] = file.absolutePath
                result.success(entry)
            } catch (e: Exception) {
                result.error("stat_failed", e.message ?: e.toString(), null)
            }
        }
    }

    private fun handleSearchFiles(call: MethodCall, result: MethodChannel.Result) {
        executor.execute {
            try {
                val scope = call.argument<String>("scope")
                val root = resolveScoped(call.argument<String>("path") ?: "/workspace", scope)
                val keyword = (call.argument<String>("keyword") ?: "").trim()
                if (keyword.isEmpty()) throw IllegalArgumentException("搜索关键词不能为空")
                val matchContent = call.argument<Boolean>("matchContent") == true
                val limit = call.argument<Number>("limit")?.toInt() ?: 200
                val lower = keyword.lowercase()
                val hits = ArrayList<Map<String, Any?>>()
                root.walkTopDown().forEach { file ->
                    if (hits.size >= limit) return@forEach
                    val nameHit = file.name.lowercase().contains(lower)
                    var contentHit = false
                    if (!nameHit && matchContent && file.isFile && file.length() <= 512 * 1024) {
                        contentHit = try {
                            file.readText(Charsets.UTF_8).lowercase().contains(lower)
                        } catch (e: Exception) {
                            false
                        }
                    }
                    if (nameHit || contentHit) {
                        val entry = entryOf(file, scope).toMutableMap()
                        entry["matchedContent"] = contentHit
                        hits.add(entry)
                    }
                }
                result.success(mapOf("path" to pathOf(root, scope), "entries" to hits))
            } catch (e: Exception) {
                result.error("search_failed", e.message ?: e.toString(), null)
            }
        }
    }

    /// guest 路径 → 宿主绝对路径。图片查看器和"用其它 APP 打开"都需要真实路径：
    /// /workspace/a.png 这种 guest 路径 Android 的 Intent 和 Image.file 都不认。
    ///
    /// [scope] = "app" 时路径本来就是宿主路径，只做越界校验。
    private fun handleHostPath(call: MethodCall, result: MethodChannel.Result) {
        executor.execute {
            try {
                val raw = call.argument<String>("path") ?: ""
                val scope = call.argument<String>("scope") ?: "shell"
                val file = if (scope == "app") resolveAppPath(raw) else resolveGuestPath(raw)
                if (!file.exists()) throw IllegalArgumentException("路径不存在：$raw")
                result.success(
                    mapOf(
                        "hostPath" to file.canonicalPath,
                        "size" to if (file.isDirectory) 0L else file.length(),
                    )
                )
            } catch (e: Exception) {
                result.error("host_path_failed", e.message ?: e.toString(), null)
            }
        }
    }

    /// 把文件交给系统里能打开它的 APP（图片看图、压缩包解压、PDF 阅读器……）。
    ///
    /// 必须走 FileProvider：app 私有目录的 file:// URI 从 Android 7 起
    /// 直接抛 FileUriExposedException，而且别的 APP 也没有权限读我们的沙箱。
    /// content:// + FLAG_GRANT_READ_URI_PERMISSION 是唯一合法路径。
    private fun handleOpenExternal(call: MethodCall, result: MethodChannel.Result) {
        executor.execute {
            try {
                val raw = call.argument<String>("path") ?: ""
                val scope = call.argument<String>("scope") ?: "shell"
                val mime = call.argument<String>("mime")?.takeIf { it.isNotBlank() }
                    ?: "application/octet-stream"
                val share = call.argument<Boolean>("share") ?: false
                val source = if (scope == "app") resolveAppPath(raw) else resolveGuestPath(raw)
                if (!source.isFile) throw IllegalArgumentException("不是文件：$raw")

                // 私有目录未必在 FileProvider 声明的树里（rootfs 在 filesDir 下、
                // 外部文件在 external-files-path 下），统一复制到 cache/share 再分享：
                // 这样只需声明一条 cache-path，且不会把整个沙箱暴露出去。
                val shareDir = File(context.cacheDir, "share").apply { mkdirs() }
                // 每次清掉上一批，别让缓存无限长大。
                shareDir.listFiles()?.forEach { it.delete() }
                val target = File(shareDir, source.name)
                source.copyTo(target, overwrite = true)

                val uri = androidx.core.content.FileProvider.getUriForFile(
                    context,
                    "${context.packageName}.fileprovider",
                    target,
                )
                val intent = if (share) {
                    android.content.Intent(android.content.Intent.ACTION_SEND).apply {
                        type = mime
                        putExtra(android.content.Intent.EXTRA_STREAM, uri)
                    }
                } else {
                    android.content.Intent(android.content.Intent.ACTION_VIEW).apply {
                        setDataAndType(uri, mime)
                    }
                }
                intent.addFlags(android.content.Intent.FLAG_GRANT_READ_URI_PERMISSION)
                val chooser = android.content.Intent.createChooser(
                    intent,
                    if (share) "分享 ${source.name}" else "打开 ${source.name}",
                ).apply {
                    // 从 Service/非 Activity 上下文启动必须带 NEW_TASK。
                    addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK)
                    addFlags(android.content.Intent.FLAG_GRANT_READ_URI_PERMISSION)
                }
                mainHandler.post {
                    try {
                        context.startActivity(chooser)
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("open_failed", e.message ?: e.toString(), null)
                    }
                }
            } catch (e: Exception) {
                result.error("open_failed", e.message ?: e.toString(), null)
            }
        }
    }

    /// APP 沙箱路径的越界校验（宿主绝对路径）。
    private fun resolveAppPath(raw: String): File {
        val file = File(raw)
        val canonical = file.canonicalPath
        val allowed = appRoots().any { (_, root) ->
            val rp = root.canonicalPath
            canonical == rp || canonical.startsWith("$rp/")
        }
        if (!allowed) throw IllegalArgumentException("只允许访问 APP 自身目录")
        return file
    }

    /// APP 自身可访问的目录（沙箱内），与 PRoot guest 挂载点分开一套根。
    /// 这些路径不经过 guestMounts 转换，直接用宿主绝对路径。
    private fun appRoots(): List<Pair<String, File>> = listOfNotNull(
        "内部文件" to context.filesDir,
        "缓存" to context.cacheDir,
        ("外部文件" to context.getExternalFilesDir(null)).takeIf { it.second != null }
            ?.let { it.first to it.second!! },
    )

    private fun handleListAppFiles(call: MethodCall, result: MethodChannel.Result) {
        executor.execute {
            try {
                val roots = appRoots()
                val raw = call.argument<String>("path")?.trim().orEmpty()
                val dir = if (raw.isEmpty()) roots.first().second else File(raw)
                // 越界保护：必须落在某个 app 根之下。
                val canonical = dir.canonicalPath
                val allowed = roots.any { (_, root) ->
                    val rp = root.canonicalPath
                    canonical == rp || canonical.startsWith("$rp/")
                }
                if (!allowed) throw IllegalArgumentException("只允许访问 APP 自身目录")
                if (!dir.exists()) dir.mkdirs()
                if (!dir.isDirectory) throw IllegalArgumentException("不是目录：$canonical")
                val children = (dir.listFiles() ?: emptyArray())
                    .sortedWith(compareByDescending<File> { it.isDirectory }.thenBy { it.name.lowercase() })
                    .map { appFileEntry(it) }
                result.success(
                    mapOf(
                        "path" to canonical,
                        "roots" to roots.map { it.second.canonicalPath },
                        "rootLabels" to roots.map { it.first },
                        "entries" to children,
                    )
                )
            } catch (e: Exception) {
                result.error("list_failed", e.message ?: e.toString(), null)
            }
        }
    }

    /// 一次导入请求的现场：等 SAF 回来时要用。
    /// 同时只允许一个（选择器本身也是模态的），第二次调用直接报错而不是覆盖，
    /// 否则前一个 Result 永远不回、Dart 侧的 await 就挂死了。
    private var importResult: MethodChannel.Result? = null
    private var importTargetDir: File? = null
    /// 这次导入是哪套目录树。不能靠"落地路径在不在 filesDir 下"反推：
    /// guest 的 /workspace 本身就在 filesDir 里，反推的话 guest 文件会被
    /// 报成宿主绝对路径，Dart 侧再拿去 readFile 就成了"文件不存在"。
    private var importAppScope = false

    /// 从别的 APP 导入文件：拉起系统文件选择器（SAF），把选中的文件复制进来。
    ///
    /// 为什么必须走 SAF：Android 10 之后应用拿不到别人的私有目录，
    /// 连 /sdcard 的读权限也只能覆盖媒体文件。系统选择器是唯一
    /// 既不用申请存储权限、又能让用户从任意来源（下载、网盘、QQ、微信）
    /// 交出文件的通道，而且授权范围只限用户亲手点的那几个文件。
    private fun handleImportFiles(call: MethodCall, result: MethodChannel.Result) {
        val act = activity
        if (act == null) {
            result.error("no_activity", "当前没有可用的界面，无法拉起文件选择器", null)
            return
        }
        if (importResult != null) {
            result.error("import_busy", "已经有一个导入在进行中", null)
            return
        }
        try {
            val raw = call.argument<String>("path")?.trim().orEmpty()
            val scope = call.argument<String>("scope") ?: "shell"
            // 目标目录先解析好：路径越界/不是目录要在弹选择器**之前**就报错，
            // 不能等用户挑完文件才告诉他没地方放。
            val dir = if (scope == "app") resolveAppPath(raw) else resolveGuestPath(raw)
            if (!dir.exists()) dir.mkdirs()
            if (!dir.isDirectory) throw IllegalArgumentException("不是目录：$raw")
            importTargetDir = dir
            importAppScope = scope == "app"
            importResult = result
            val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                type = "*/*"
                addCategory(Intent.CATEGORY_OPENABLE)
                // 允许多选：用户往往一次要传一整批脚本。
                putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            act.startActivityForResult(intent, REQUEST_IMPORT)
        } catch (e: Exception) {
            importResult = null
            importTargetDir = null
            importAppScope = false
            result.error("import_failed", e.message ?: e.toString(), null)
        }
    }

    /// SAF 回调。返回 true 表示这个 requestCode 已被消费。
    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != REQUEST_IMPORT) return false
        val result = importResult ?: return true
        val dir = importTargetDir
        val appScope = importAppScope
        importResult = null
        importTargetDir = null
        importAppScope = false
        if (resultCode != Activity.RESULT_OK || data == null || dir == null) {
            // 用户按了返回：这不是错误，回一个"取消"让 UI 静静收场。
            result.success(mapOf("canceled" to true, "files" to emptyList<Any>()))
            return true
        }
        val uris = ArrayList<Uri>()
        data.clipData?.let { clip ->
            for (i in 0 until clip.itemCount) uris.add(clip.getItemAt(i).uri)
        }
        if (uris.isEmpty()) data.data?.let { uris.add(it) }
        executor.execute {
            val done = ArrayList<Map<String, Any?>>()
            val failed = ArrayList<Map<String, Any?>>()
            for (uri in uris) {
                try {
                    done.add(importOne(uri, dir, appScope))
                } catch (e: Exception) {
                    failed.add(
                        mapOf(
                            "name" to (displayNameOf(uri) ?: uri.lastPathSegment.orEmpty()),
                            "error" to (e.message ?: e.toString()),
                        )
                    )
                }
            }
            result.success(
                mapOf("canceled" to false, "files" to done, "failed" to failed)
            )
        }
        return true
    }

    /// 复制一个 SAF URI 到目标目录，返回落地后的文件条目。
    private fun importOne(uri: Uri, dir: File, appScope: Boolean): Map<String, Any?> {
        val name = sanitizeName(displayNameOf(uri) ?: "import-${System.currentTimeMillis()}")
        val target = uniqueTarget(dir, name)
        val input = context.contentResolver.openInputStream(uri)
            ?: throw IOException("无法读取所选文件")
        input.use { src ->
            FileOutputStream(target).use { out ->
                BufferedOutputStream(out).use { sink -> src.copyTo(sink, 64 * 1024) }
            }
        }
        // guest 树里报 guest 路径，app 树里报宿主绝对路径——和两套 list 保持一致。
        // 用请求带来的 scope，不做路径反推：guest 的 /workspace 物理上就在
        // filesDir 下面，反推会把它误判成 app 树。
        return if (appScope) appFileEntry(target) else fileEntry(target)
    }

    /// SAF 只保证 DISPLAY_NAME 这一列，拿不到就退回 URI 末段。
    private fun displayNameOf(uri: Uri): String? {
        return try {
            context.contentResolver.query(uri, null, null, null, null)?.use { cursor ->
                val idx = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                if (idx >= 0 && cursor.moveToFirst()) cursor.getString(idx) else null
            }
        } catch (e: Exception) {
            null
        }
    }

    /// 文件名消毒：来源 APP 给的名字不可信，路径分隔符会把文件写到目标目录之外。
    private fun sanitizeName(raw: String): String {
        val cleaned = raw.replace('\\', '_')
            .substringAfterLast('/')
            .replace(Regex("[\u0000-\u001f]"), "")
            .trim()
            .trimStart('.')
        // 全被清掉（比如名字就叫 "../"）时给个兜底名，不要写出空文件名。
        return cleaned.ifEmpty { "import-${System.currentTimeMillis()}" }.take(180)
    }

    /// 同名不覆盖：追加 (1)(2)……用户传两个同名文件时两份都留着。
    private fun uniqueTarget(dir: File, name: String): File {
        var candidate = File(dir, name)
        if (!candidate.exists()) return candidate
        val dot = name.lastIndexOf('.')
        val stem = if (dot > 0) name.substring(0, dot) else name
        val ext = if (dot > 0) name.substring(dot) else ""
        var i = 1
        while (candidate.exists() && i < 1000) {
            candidate = File(dir, "$stem($i)$ext")
            i++
        }
        return candidate
    }

    private fun appFileEntry(file: File): Map<String, Any?> = mapOf(
        "name" to file.name,
        "path" to file.absolutePath,
        "isDirectory" to file.isDirectory,
        "size" to if (file.isDirectory) 0L else file.length(),
        "modified" to file.lastModified(),
        "readable" to file.canRead(),
        "writable" to file.canWrite(),
        "executable" to file.canExecute(),
        "hidden" to file.name.startsWith("."),
    )

    private fun handleDeletePath(call: MethodCall, result: MethodChannel.Result) {
        executor.execute {
            try {
                val scope = call.argument<String>("scope")
                val file = resolveScoped(call.argument<String>("path") ?: "", scope)
                if (guestMounts.any { guestPathOf(file) == it.first }) {
                    throw IllegalArgumentException("挂载点根目录不允许删除")
                }
                if (appRoots().any { it.second.canonicalPath == file.canonicalPath }) {
                    throw IllegalArgumentException("APP 根目录不允许删除")
                }
                if (!file.exists()) throw IllegalArgumentException("路径不存在")
                deleteRecursive(file)
                result.success(true)
            } catch (e: Exception) {
                result.error("delete_failed", e.message ?: e.toString(), null)
            }
        }
    }

    private fun handleMakeDirectory(call: MethodCall, result: MethodChannel.Result) {
        executor.execute {
            try {
                val scope = call.argument<String>("scope")
                val dir = resolveScoped(call.argument<String>("path") ?: "", scope)
                if (!dir.exists() && !dir.mkdirs()) throw IOException("创建目录失败")
                result.success(entryOf(dir, scope))
            } catch (e: Exception) {
                result.error("mkdir_failed", e.message ?: e.toString(), null)
            }
        }
    }

    private fun handleMovePath(call: MethodCall, result: MethodChannel.Result) {
        executor.execute {
            try {
                val scope = call.argument<String>("scope")
                val from = resolveScoped(call.argument<String>("from") ?: "", scope)
                val to = resolveScoped(call.argument<String>("to") ?: "", scope)
                if (!from.exists()) throw IllegalArgumentException("源路径不存在")
                if (to.exists()) throw IllegalArgumentException("目标已存在：${pathOf(to, scope)}")
                to.parentFile?.mkdirs()
                if (!from.renameTo(to)) throw IOException("移动失败")
                result.success(entryOf(to, scope))
            } catch (e: Exception) {
                result.error("move_failed", e.message ?: e.toString(), null)
            }
        }
    }

    private fun handleExec(call: MethodCall, result: MethodChannel.Result) {
        execExecutor.execute {
            runningExecs.incrementAndGet()
            try {
                val manifest = readManifest()
                val version = manifest.getString("runtime_version")
                if (!prootBin(version).isFile) {
                    result.error("runtime_not_installed", "请先安装 Runtime V2", null)
                    return@execute
                }
                val command = call.argument<String>("command") ?: "/bin/true"
                val args = call.argument<List<String>>("args") ?: emptyList()
                // 上限 30 分钟：再长基本都是脚本自己挂了（等输入、死循环、
                // 网络黑洞），继续等只是把资源占着。
                val timeoutSeconds =
                    (call.argument<Number>("timeoutSeconds")?.toLong() ?: 60L)
                        .coerceIn(1L, 1800L)
                val cwd = call.argument<String>("cwd")?.let(::File) ?: workspaceDir()
                ensureProotExecutable(version)
                prepareGuestNetwork(version)
                val pb = processBuilderFor(buildProotArgs(version, command, args), version)
                pb.directory(cwd)
                pb.redirectErrorStream(false)
                val process = pb.start()

                val stdoutQueue = ArrayBlockingQueue<String>(1)
                val stderrQueue = ArrayBlockingQueue<String>(1)
                // 读管道的线程**必须**自己吞掉异常。
                //
                // 超时后 destroyForcibly() 会让这两个 read 抛
                // InterruptedIOException；裸 Thread 里抛出去 = 整个 APP
                // FATAL EXCEPTION 直接闪退（现场就是这么崩的）。
                // 另外用 offer 而不是 put：容量 1 的队列在没人取时 put 会
                // 永久阻塞，那样线程就再也回收不了。
                // daemon 线程：万一 proot 卡在内核里读不动，也不拖着进程不退。
                val stdoutThread = Thread {
                    val text = try {
                        readAll(process.inputStream).trim()
                    } catch (t: Throwable) {
                        ""
                    }
                    stdoutQueue.offer(text)
                }
                val stderrThread = Thread {
                    val text = try {
                        readAll(process.errorStream).trim()
                    } catch (t: Throwable) {
                        ""
                    }
                    stderrQueue.offer(text)
                }
                stdoutThread.isDaemon = true
                stderrThread.isDaemon = true
                stdoutThread.start()
                stderrThread.start()

                val startedAt = System.currentTimeMillis()
                val finished = process.waitFor(timeoutSeconds, TimeUnit.SECONDS)
                if (!finished) {
                    process.destroyForcibly()
                    // 不再无限 waitFor：proot 偶尔会连 SIGKILL 都收不干净，
                    // 那样这个线程就永远回不来，Dart 那边也永远等不到回复。
                    process.waitFor(3, TimeUnit.SECONDS)
                    val spent = (System.currentTimeMillis() - startedAt) / 1000
                    // 超时也把已经吐出来的内容带回去：卡住前打印的那几行
                    // 往往就是卡在哪儿的唯一线索。
                    val partialOut = stdoutQueue.poll(1, TimeUnit.SECONDS).orEmpty()
                    val partialErr = stderrQueue.poll(1, TimeUnit.SECONDS).orEmpty()
                    result.success(
                        mapOf(
                            "code" to -1,
                            "stdout" to partialOut,
                            "stderr" to buildString {
                                append("执行超时：跑了 ${spent}s 仍未结束，已强制杀掉。")
                                append("常见原因：命令在等输入（加 -y/--yes 或重定向 </dev/null）、")
                                append("死循环、网络卡住（加 --timeout）。")
                                if (partialErr.isNotEmpty()) {
                                    append("\n卡住前的 stderr：\n")
                                    append(partialErr)
                                }
                            },
                        )
                    )
                } else {
                    result.success(
                        mapOf(
                            "code" to process.exitValue(),
                            "stdout" to stdoutQueue.poll(1, TimeUnit.SECONDS).orEmpty(),
                            "stderr" to stderrQueue.poll(1, TimeUnit.SECONDS).orEmpty(),
                        )
                    )
                }
            } catch (e: Exception) {
                result.error("exec_failed", e.message ?: e.toString(), null)
            } finally {
                runningExecs.decrementAndGet()
            }
        }
    }

    private fun handleSpawnTerminal(result: MethodChannel.Result) {
        executor.execute {
            try {
                val manifest = readManifest()
                val version = manifest.getString("runtime_version")
                if (!prootBin(version).isFile) {
                    result.error("runtime_not_installed", "请先安装 Runtime V2", null)
                    return@execute
                }
                if (running.get()) {
                    result.success(true)
                    return@execute
                }
                ensureProotExecutable(version)
                prepareGuestNetwork(version)
                val command = buildProotArgs(version, "/bin/bash", listOf("--login", "-i"))
                val pb = processBuilderFor(command, version)
                val env = pb.environment().entries.map { "${it.key}=${it.value}" }.toTypedArray()
                val handle = ptySpawn(command.toTypedArray(), env, workspaceDir().absolutePath)
                if (handle <= 0) throw IllegalStateException("PTY spawn failed: $handle")
                terminalHandle = handle
                running.set(true)
                pendingTerminalEvents.clear()

                val inputThread = Thread {
                    val buffer = ByteArray(8192)
                    while (running.get()) {
                        // 循环体自己就 try 住了 ptyRead，这里不再包一层。
                        val n = try {
                            ptyRead(handle, buffer, 0, buffer.size)
                        } catch (e: Exception) {
                            Log.e("qtermpty", "read error", e)
                            -1
                        }
                        if (n <= 0) break
                        val data = String(buffer, 0, n, Charsets.UTF_8)
                        emitTerminal("output", data)
                    }
                }
                inputThread.start()
                Thread {
                    // 同理：这条线程里抛异常也会整个 APP 闪退，全兜住。
                    try {
                        val code = ptyWait(handle)
                        try { ptyClose(handle) } catch (e: Exception) {}
                        running.set(false)
                        terminalProcess = null
                        terminalHandle = 0L
                        emitTerminal("exit", code.toString())
                    } catch (t: Throwable) {
                        Log.e("qtermpty", "pty wait thread crashed", t)
                        running.set(false)
                        terminalProcess = null
                        terminalHandle = 0L
                    }
                }.start()
                result.success(true)
            } catch (e: Exception) {
                result.error("spawn_failed", e.message ?: e.toString(), null)
            }
        }
    }

    private fun handleWriteTerminal(call: MethodCall, result: MethodChannel.Result) {
        val data = call.argument<String>("data") ?: ""
        val handle = terminalHandle
        if (handle <= 0L || !running.get()) {
            result.success(false)
            return
        }
        try {
            val bytes = data.toByteArray(Charsets.UTF_8)
            ptyWrite(handle, bytes, 0, bytes.size)
            result.success(true)
        } catch (e: Exception) {
            result.error("write_failed", e.message ?: e.toString(), null)
        }
    }

    /// 把 TerminalView 的行列数告诉 pty。
    ///
    /// 不做这件事的话内核里的 winsize 一直是 0x0：bash 以为终端零宽，
    /// ls 不分列、top/less 画不出界面、长命令的换行位置也是错的。
    private fun handleResizeTerminal(call: MethodCall, result: MethodChannel.Result) {
        val cols = call.argument<Number>("cols")?.toInt() ?: 0
        val rows = call.argument<Number>("rows")?.toInt() ?: 0
        val handle = terminalHandle
        if (handle <= 0L || !running.get() || cols <= 0 || rows <= 0) {
            result.success(false)
            return
        }
        try {
            result.success(ptyResize(handle, cols, rows) == 0)
        } catch (e: Exception) {
            result.success(false)
        }
    }

    private fun handleStopTerminal(result: MethodChannel.Result) {
        val handle = terminalHandle
        if (handle > 0L) {
            try { ptyKill(handle) } catch (e: Exception) {}
            running.set(false)
        }
        result.success(true)
    }

    /// 安装进度上报：stage 是人话阶段名，received/total 为字节数（total<=0 表示未知）。
    private fun emitInstall(
        stage: String,
        received: Long = 0,
        total: Long = 0,
        done: Boolean = false,
        error: String? = null,
    ) {
        val event = mapOf(
            "stage" to stage,
            "received" to received,
            "total" to total,
            "done" to done,
            "error" to error,
        )
        lastInstallEvent = event
        mainHandler.post {
            try {
                installSink?.success(event)
            } catch (e: Exception) {
                Log.e("qtermpty", "install sink failed", e)
            }
        }
    }

    private fun emitTerminal(type: String, data: String) {
        val event = mapOf("type" to type, "data" to data)
        // Flutter 的 EventSink 只能在主线程调用；PTY 读线程直接调用会被丢弃，导致终端一片空白。
        mainHandler.post {
            val sink = terminalSink
            if (sink != null) {
                try {
                    sink.success(event)
                } catch (e: Exception) {
                    Log.e("qtermpty", "sink.success failed", e)
                    pendingTerminalEvents.offer(event)
                }
            } else {
                if (!pendingTerminalEvents.offer(event)) {
                    pendingTerminalEvents.clear()
                    pendingTerminalEvents.offer(event)
                }
            }
        }
    }

    private fun drainPending(events: EventChannel.EventSink?) {
        mainHandler.post {
            while (true) {
                val event = pendingTerminalEvents.poll() ?: break
                try {
                    events?.success(event)
                } catch (e: Exception) {
                    Log.e("qtermpty", "drainPending failed", e)
                    break
                }
            }
        }
    }

    private fun readAll(input: InputStream): String {
        val reader = BufferedReader(InputStreamReader(input, Charsets.UTF_8))
        val sb = StringBuilder()
        val buffer = CharArray(4096)
        while (true) {
            val read = reader.read(buffer)
            if (read <= 0) break
            sb.append(buffer, 0, read)
        }
        return sb.toString()
    }
}
