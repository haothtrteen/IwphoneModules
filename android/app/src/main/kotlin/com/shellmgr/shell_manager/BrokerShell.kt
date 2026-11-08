package com.shellmgr.shell_manager

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import java.io.BufferedReader
import java.io.File
import java.io.InputStreamReader
import java.net.HttpURLConnection
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.net.URL
import java.net.URLEncoder
import java.security.SecureRandom
import java.util.concurrent.ConcurrentHashMap

/**
 * rish 式终端入口的服务端（App 进程内）。
 *
 * ## 为什么不是 Binder 回传
 *
 * Shizuku 的 rish 由 app_process 起 dex，再用广播把 Binder 回给客户端。
 * 但本机实测两条前置都不成立：
 *   - `ActivityThread.systemMain()` 在 MIUI 上会初始化主题资源并崩溃；
 *   - 从 app uid 用 `am start` 会被 `assertPackageMatchesCallingUid` 拒绝。
 *
 * 而 `app_process` 加载 dex、`am broadcast --user 0`、回环 TCP 均实测可用。
 * 所以这里改成：dex 发广播请求 → 本类用悬浮窗让用户确认 → 签发**一次性会话
 * token**（写到公共目录供 dex 读取）→ dex 连 127.0.0.1:8539 执行命令。
 *
 * ## 安全边界（必须如实理解）
 *
 * 广播拿不到发送方 uid（接收器里是 system_server），因此**不做按应用授权**。
 * 权限来自「用户当场确认的这一次会话」：token 一次性、60 秒 TTL，
 * 且 WebUI 访问密钥始终只在 App 内部，不下发给终端。
 * 这与 Shizuku 的「用户确认一次会话」等价，但不等价于 Binder.getCallingUid
 * 的按应用授权。需要按应用授权时应走 ContentProvider 通道。
 */
object BrokerShell {

    const val ACTION_REQUEST = "com.shellmgr.action.REQUEST_SHELL"
    const val PORT = 8539

    private const val TTL_MS = 60_000L
    private val tokens = ConcurrentHashMap<String, Long>()
    private val rng = SecureRandom()
    private var server: ServerSocket? = null

    fun startServer() {
        if (server != null) return
        Thread {
            try {
                val ss = ServerSocket(PORT, 16, InetAddress.getByName("127.0.0.1"))
                server = ss
                while (true) {
                    val s = ss.accept()
                    Thread { handle(s) }.start()
                }
            } catch (_: Exception) {
                server = null
            }
        }.apply { isDaemon = true; start() }
    }

    /** 用户确认后签发 token，并写到双方都能读的公共目录供 dex 轮询。 */
    fun issue(ctx: Context, nonce: String): Boolean {
        val token = ByteArray(24).also { rng.nextBytes(it) }
            .joinToString("") { "%02x".format(it) }
        tokens[token] = System.currentTimeMillis() + TTL_MS
        startServer()

        val dirs = listOf(
            File("/sdcard/iwphone/broker"),
            File(ctx.getExternalFilesDir(null) ?: ctx.filesDir, "broker"),
        )
        var written: File? = null
        for (d in dirs) {
            try {
                if (!d.exists()) d.mkdirs()
                val f = File(d, "$nonce.token")
                f.writeText(token)
                f.setReadable(true, false)
                written = f
                break
            } catch (_: Exception) {
            }
        }
        return written != null
    }

    private fun valid(token: String): Boolean {
        val exp = tokens[token] ?: return false
        if (System.currentTimeMillis() > exp) {
            tokens.remove(token)
            return false
        }
        return true
    }

    private fun handle(s: Socket) {
        try {
            s.soTimeout = 70_000
            val reader = BufferedReader(InputStreamReader(s.getInputStream()))
            val line = reader.readLine() ?: return
            val parts = line.split(" ")
            if (parts.size < 2) return
            val q = parts[1]
            if (!q.startsWith("/exec?")) {
                reply(s, 404, """{"ok":false,"code":"NO_METHOD"}""")
                return
            }
            val params = HashMap<String, String>()
            for (kv in q.substringAfter("?").split("&")) {
                val i = kv.indexOf('=')
                if (i < 0) continue
                try {
                    params[kv.substring(0, i)] =
                        java.net.URLDecoder.decode(kv.substring(i + 1), "UTF-8")
                } catch (_: Exception) {
                }
            }
            val token = params["token"] ?: ""
            val cmd = params["cmd"] ?: ""
            if (!valid(token) || cmd.isBlank() || cmd.length > 4096) {
                reply(s, 403, """{"ok":false,"code":"INVALID_TOKEN"}""")
                return
            }
            // 一次性：用过即废，避免同设备其它应用复用
            tokens.remove(token)

            val ctx = AppGlobals.appContext
                ?: return reply(s, 500, """{"ok":false,"code":"NO_CONTEXT"}""")
            val body = callFramework(ctx, cmd,
                (params["timeout"]?.toIntOrNull() ?: 15).coerceIn(1, 60))
            reply(s, 200, body)
        } catch (_: Exception) {
        } finally {
            try { s.close() } catch (_: Exception) {}
        }
    }

    /** App 内部持有 WebUI 密钥，终端永远拿不到。 */
    private fun callFramework(ctx: Context, cmd: String, timeout: Int): String {
        val token = AutostartPrefs.webuiToken(ctx)
        if (token.isEmpty()) return """{"ok":false,"code":"NO_TOKEN"}"""
        var c: HttpURLConnection? = null
        return try {
            val url = URL(
                "http://127.0.0.1:8537/api/shell?cmd=" +
                    URLEncoder.encode(cmd, "UTF-8") + "&timeout=" + timeout
            )
            c = url.openConnection() as HttpURLConnection
            c.requestMethod = "POST"
            c.connectTimeout = 3000
            c.readTimeout = (timeout + 8) * 1000
            c.setRequestProperty("X-Token", token)
            if (c.responseCode != 200) return """{"ok":false,"code":"HTTP_${c.responseCode}"}"""
            c.inputStream.bufferedReader().use { it.readText() }
        } catch (_: Exception) {
            """{"ok":false,"code":"IO_ERROR"}"""
        } finally {
            try { c?.disconnect() } catch (_: Exception) {}
        }
    }

    private fun reply(s: Socket, code: Int, body: String) {
        val bytes = body.toByteArray(Charsets.UTF_8)
        val out = s.getOutputStream()
        val status = when (code) { 200 -> "200 OK"; 403 -> "403 Forbidden"; 404 -> "404 Not Found"; else -> "500 Error" }
        out.write(("HTTP/1.1 $status\r\nContent-Type: application/json; charset=utf-8\r\n" +
            "Content-Length: ${bytes.size}\r\nConnection: close\r\n\r\n").toByteArray())
        out.write(bytes)
        out.flush()
    }
}

/** 轻量全局 Context 引用，供非组件类使用（App 进程生命周期内有效）。 */
object AppGlobals {
    @Volatile
    var appContext: Context? = null
}

/**
 * 接收 dex 发来的显式广播。
 *
 * 广播本身**不携带可信身份**，这里只负责触发用户确认；
 * 真正的授权决定由悬浮窗产生，token 是「用户确认的一次会话」的凭据。
 */
class BrokerShellReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent?) {
        if (intent?.action != BrokerShell.ACTION_REQUEST) return
        val nonce = intent.getStringExtra("nonce") ?: return
        if (nonce.length !in 8..64 || !nonce.all { it.isLetterOrDigit() || it == '-' }) return
        val pending = goAsync()
        Thread {
            val ctx = context.applicationContext
            AppGlobals.appContext = ctx
            try {
                // 无悬浮窗权限时 askTerminal 返回 false → 不签发 token，
                // 终端会超时并提示用户先在 App 里开启（可由 adb 自授权完成）。
                if (BrokerPrompt.askTerminal(ctx)) BrokerShell.issue(ctx, nonce)
            } catch (_: Exception) {
            } finally {
                try { pending.finish() } catch (_: Exception) {}
            }
        }.start()
    }
}
