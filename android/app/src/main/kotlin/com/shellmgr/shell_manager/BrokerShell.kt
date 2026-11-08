package com.shellmgr.shell_manager

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import org.json.JSONArray
import org.json.JSONObject
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
 * iwsh 终端入口的服务端（App 进程内）。
 *
 * ## 授权模型（v1.3.19：从「一次会话」改为「整个应用」）
 *
 * 客户端 `iwsh.sh` 把终端应用包名（`IWPHONE_APPLICATION_ID`，对齐 Shizuku 的
 * application id 做法）随广播传过来。App 侧用 PackageManager 查该包的 uid 与签名，
 * 生成一条**持久授权记录**，并签发与该记录绑定的 token。token 缓存在终端工具包目录，
 * 之后每次调用直接复用，不再弹窗 —— 授权的是整个应用，不是一次进程。
 *
 * 每次执行都会重新校验 (pkg, uid, sig)：应用卸载、重装换签名、uid 被回收，
 * 授权自动失效。用户也可在授权页手动撤销。
 *
 * ## 为什么不是 Binder.getCallingUid()
 *
 * 广播由 system_server 转发，接收器拿不到发送方 uid；真机实测
 * `ActivityThread.systemMain()` 在 MIUI 崩、`am start` 从 app uid 被拒。
 * 因此这里的可信根是「用户在弹窗里确认的那个应用」+ 后续 PackageManager 三元组校验，
 * 不是 Binder 身份。按应用授权仍可走 BrokerProvider（ContentProvider 通道）。
 *
 * WebUI 访问密钥始终只在 App 内部，不下发终端。
 */
object BrokerShell {

    const val ACTION_REQUEST = "com.shellmgr.action.REQUEST_SHELL"
    const val PORT = 8539

    private var server: ServerSocket? = null

    /** 当前进程内已签发的 token → 包名，用于快速拒绝无效 token。 */
    private val liveTokens = ConcurrentHashMap<String, String>()

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

    /** 用户确认后：签发持久 token 并写到双方都能读的公共目录供 dex 轮询。 */
    fun issue(ctx: Context, nonce: String, pkg: String): Boolean {
        val token = IwshGrantStore.grant(ctx, pkg) ?: return false
        liveTokens[token] = pkg
        startServer()

        val dirs = listOf(
            File("/sdcard/iwphone/broker"),
            File(ctx.getExternalFilesDir(null) ?: ctx.filesDir, "broker"),
        )
        for (d in dirs) {
            try {
                if (!d.exists()) d.mkdirs()
                val f = File(d, "$nonce.token")
                f.writeText(token)
                f.setReadable(true, false)
                return true
            } catch (_: Exception) {
            }
        }
        return false
    }

    private fun handle(s: Socket) {
        try {
            s.soTimeout = 70_000
            val line = BufferedReader(InputStreamReader(s.getInputStream())).readLine() ?: return
            val parts = line.split(" ")
            if (parts.size < 2 || !parts[1].startsWith("/exec?")) {
                reply(s, 404, """{"ok":false,"code":"NO_METHOD"}""")
                return
            }
            val params = HashMap<String, String>()
            for (kv in parts[1].substringAfter("?").split("&")) {
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
            if (cmd.isBlank() || cmd.length > 4096) {
                reply(s, 400, """{"ok":false,"code":"BAD_CMD"}""")
                return
            }
            val ctx = AppGlobals.appContext
                ?: return reply(s, 500, """{"ok":false,"code":"NO_CONTEXT"}""")

            // ★ token 不再「用过即废」：查持久授权记录并重新校验三元组
            val g = IwshGrantStore.findByToken(ctx, token)
            if (g == null) {
                reply(s, 403, """{"ok":false,"code":"INVALID_TOKEN"}""")
                return
            }
            if (!IwshGrantStore.valid(ctx, g)) {
                liveTokens.remove(token)
                reply(s, 403, """{"ok":false,"code":"GRANT_REVOKED"}""")
                return
            }

            // cwd 由交互式客户端维护：cd 后每条命令带上工作目录
            val cwd = params["cwd"] ?: ""
            val body = callFramework(ctx, cmd, cwd,
                (params["timeout"]?.toIntOrNull() ?: 15).coerceIn(1, 60))
            reply(s, 200, body)
        } catch (_: Exception) {
        } finally {
            try { s.close() } catch (_: Exception) {}
        }
    }

    /** App 内部持有 WebUI 密钥，终端永远拿不到。 */
    private fun callFramework(
        ctx: Context,
        cmd: String,
        cwd: String,
        timeout: Int,
    ): String {
        val token = AutostartPrefs.webuiToken(ctx)
        if (token.isEmpty()) return """{"ok":false,"code":"NO_TOKEN"}"""
        var c: HttpURLConnection? = null
        return try {
            val q = buildString {
                append("/api/shell?cmd=").append(URLEncoder.encode(cmd, "UTF-8"))
                append("&timeout=").append(timeout)
                if (cwd.isNotEmpty()) {
                    append("&cwd=").append(URLEncoder.encode(cwd, "UTF-8"))
                }
            }
            val url = URL("http://127.0.0.1:8537$q")
            c = url.openConnection() as HttpURLConnection
            c.requestMethod = "POST"
            c.connectTimeout = 3000
            c.readTimeout = (timeout + 8) * 1000
            c.setRequestProperty("X-Token", token)
            if (c.responseCode != 200) {
                return """{"ok":false,"code":"HTTP_${c.responseCode}"}"""
            }
            c.inputStream.bufferedReader().use { it.readText() }
        } catch (_: Exception) {
            """{"ok":false,"code":"IO_ERROR"}"""
        } finally {
            try { c?.disconnect() } catch (_: Exception) {}
        }
    }

    private fun reply(s: Socket, code: Int, body: String) {
        val bytes = body.toByteArray(Charsets.UTF_8)
        val status = when (code) {
            200 -> "200 OK"; 400 -> "400 Bad Request"; 403 -> "403 Forbidden"
            404 -> "404 Not Found"; else -> "500 Error"
        }
        val out = s.getOutputStream()
        out.write(("HTTP/1.1 $status\r\nContent-Type: application/json; charset=utf-8\r\n" +
            "Content-Length: ${bytes.size}\r\nConnection: close\r\n\r\n").toByteArray())
        out.write(bytes)
        out.flush()
    }
}

/**
 * 「整个应用」授权表：与 BrokerStore 的按应用授权模型一致（包名 + uid + 签名）。
 * 用 SharedPreferences 存 JSON 数组，数据量是几十条级别，不需要数据库。
 */
object IwshGrantStore {

    private const val FILE = "iwsh_grants"
    private const val KEY = "items"

    data class Grant(
        val pkg: String,
        val uid: Int,
        val sig: String,
        val token: String,
        val at: Long,
    )

    private fun sp(ctx: Context) = ctx.getSharedPreferences(FILE, Context.MODE_PRIVATE)

    private fun read(ctx: Context): List<JSONObject> {
        val raw = sp(ctx).getString(KEY, null) ?: return emptyList()
        return try {
            val arr = JSONArray(raw)
            (0 until arr.length()).mapNotNull { arr.optJSONObject(it) }
        } catch (_: Exception) {
            emptyList()
        }
    }

    private fun write(ctx: Context, items: List<JSONObject>) {
        val arr = JSONArray()
        items.forEach { arr.put(it) }
        sp(ctx).edit().putString(KEY, arr.toString()).apply()
    }

    private fun toJson(g: Grant) = JSONObject()
        .put("pkg", g.pkg).put("uid", g.uid).put("sig", g.sig)
        .put("token", g.token).put("at", g.at)

    private fun fromJson(o: JSONObject) = Grant(
        o.optString("pkg"), o.optInt("uid", -1), o.optString("sig"),
        o.optString("token"), o.optLong("at", 0L),
    )

    /**
     * 为整个应用签发授权。包名来自客户端声明，但 App 侧会：
     * ① 用 PackageManager 确认它真实存在；② 取 uid 与签名做绑定；
     * ③ 授权前弹窗把应用名/包名显示给用户确认。
     * 因此伪造包名只能让弹窗显示别的应用，用户看得见并可以拒绝。
     */
    fun grant(ctx: Context, pkg: String): String? {
        if (!pkg.matches(Regex("[A-Za-z0-9_.]+"))) return null
        val uid = try {
            ctx.packageManager.getApplicationInfo(pkg, 0).uid
        } catch (_: Exception) {
            return null
        }
        val sig = BrokerStore.sigHashOf(ctx, pkg) ?: return null
        val token = ByteArray(24).also { SecureRandom().nextBytes(it) }
            .joinToString("") { "%02x".format(it) }
        val g = Grant(pkg, uid, sig, token, System.currentTimeMillis())
        write(ctx, read(ctx).filterNot { it.optString("pkg") == pkg } + toJson(g))
        return token
    }

    fun findByToken(ctx: Context, token: String): Grant? {
        if (token.isEmpty()) return null
        return read(ctx).firstOrNull { it.optString("token") == token }?.let { fromJson(it) }
    }

    /** 每次执行都重验：卸载 / 换签名 / uid 被回收 → 自动撤销。 */
    fun valid(ctx: Context, g: Grant): Boolean {
        val uid = try {
            ctx.packageManager.getApplicationInfo(g.pkg, 0).uid
        } catch (_: Exception) {
            revoke(ctx, g.pkg)
            return false
        }
        val sig = BrokerStore.sigHashOf(ctx, g.pkg)
        if (uid != g.uid || sig == null || sig != g.sig) {
            revoke(ctx, g.pkg)
            return false
        }
        return true
    }

    fun list(ctx: Context): List<Grant> = read(ctx).map { fromJson(it) }

    fun revoke(ctx: Context, pkg: String) {
        write(ctx, read(ctx).filterNot { it.optString("pkg") == pkg })
    }
}

/** 轻量全局 Context 引用，供非组件类使用（App 进程生命周期内有效）。 */
object AppGlobals {
    @Volatile
    var appContext: Context? = null
}

/**
 * 接收 iwsh 发来的显式广播。
 *
 * 广播本身不携带可信身份，这里只负责：确认包名对应真实应用 → 把应用名/包名
 * 交给用户确认 → 确认后签发「整个应用」的持久授权。
 */
class BrokerShellReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent?) {
        if (intent?.action != BrokerShell.ACTION_REQUEST) return
        val nonce = intent.getStringExtra("nonce") ?: return
        val pkg = intent.getStringExtra("pkg") ?: return
        if (nonce.length !in 8..64 || !nonce.all { it.isLetterOrDigit() || it == '-' }) return
        if (!pkg.matches(Regex("[A-Za-z0-9_.]+"))) return

        val pending = goAsync()
        Thread {
            val ctx = context.applicationContext
            AppGlobals.appContext = ctx
            try {
                val pm: PackageManager = ctx.packageManager
                val info = try {
                    pm.getApplicationInfo(pkg, 0)
                } catch (_: Exception) {
                    null
                }
                if (info == null) {
                    System.err.println("[iwsh] 包名不存在，拒绝授权：$pkg")
                } else {
                    val label = pm.getApplicationLabel(info).toString()
                    // 悬浮窗权限由授权页「去开启」按钮（adb 自授权）负责；
                    // 这里只管确认，避免在请求回调里再跑一遍 adb 通道。
                    // 无权限时 askTerminal 返回 false → 不签发，终端会明确超时。
                    val ok = BrokerPrompt.askTerminal(
                        ctx, label, "$pkg · 授权后该应用的所有终端调用免确认",
                    )
                    if (ok) BrokerShell.issue(ctx, nonce, pkg)
                }
            } catch (_: Exception) {
            } finally {
                try { pending.finish() } catch (_: Exception) {}
            }
        }.start()
    }
}
