package com.shellmgr.shell_manager

import android.content.ContentProvider
import android.content.ContentValues
import android.content.Context
import android.database.Cursor
import android.net.Uri
import android.os.Binder
import android.os.Bundle
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLEncoder
import java.util.concurrent.ConcurrentHashMap

/**
 * 对外授权通道：让**其它应用**经本应用以 shell 身份执行命令（Shizuku 那类能力）。
 *
 * ## 为什么不用 Unix domain socket
 *
 * 框架本身就跑在 shell(2000) 身份下，看起来「框架开个 socket，客户端连上来，
 * 用 SO_PEERCRED 拿 uid」最直接。但这条路走不通，两个原因：
 *
 *   1. **SELinux**：客户端是 untrusted_app 域，socket 的服务端是 shell 域。
 *      untrusted_app 连 shell 域 socket 需要 `allow untrusted_app shell:unix_stream_socket connectto`，
 *      AOSP 默认策略里没有这条 —— 直接 EACCES。
 *   2. **就算连通也解决不了问题**：授权需要「弹窗问用户」，而框架是 shell 脚本，
 *      没有界面。最终还是要转回本应用来问，多绕一层没有任何收益。
 *
 * ## 为什么用 ContentProvider 而不是 Service / Activity
 *
 * - `ContentResolver.call()` 是**同步**的：一次往返拿到 stdout/exitCode，
 *   客户端不需要自己管理回调、连接、超时。
 * - `call()` 在 Binder 线程上执行，`Binder.getCallingUid()` 在这里是**真实调用方**的 uid。
 *   （对比：如果走 Service + Messenger，Handler 里已经拿不到调用方 uid 了。）
 * - 客户端接入成本极低：一行 `getContentResolver().call(...)`，不需要 AIDL、不需要依赖库。
 * - 跨应用 ContentProvider 调用走的是标准 Binder，不受 SELinux 域限制影响，
 *   这是 Android 上最稳的跨应用通道。
 *
 * ## 授权模型
 *
 * 身份 = (包名, uid, 签名哈希) 三元组，见 [BrokerStore]。
 * 未授权的调用**不会弹窗**（Android 10+ 后台进程禁止启动 Activity，
 * 弹窗根本弹不出来），而是记进「待授权」列表并返回 NEED_APPROVAL，
 * 由用户打开本应用「应用授权」页手动批准 —— 与 Shizuku 的做法一致。
 */
class BrokerProvider : ContentProvider() {

    companion object {
        /** 客户端使用的 authority。 */
        const val AUTHORITY = "com.shellmgr.shell_manager.broker"

        /** 协议版本。客户端可先探一次，版本不匹配时好给出明确提示。 */
        const val API_VERSION = 1

        private const val WEBUI_PORT = 8537

        /** 未授权调用提醒的节流窗口 —— 防止恶意应用刷爆 prefs。 */
        private const val NOTE_THROTTLE_MS = 10_000L
    }

    /** 每个包的待授权记录上次落盘时间，纯内存，重启清零。 */
    private val lastNote = ConcurrentHashMap<String, Long>()

    override fun onCreate(): Boolean = true

    override fun query(
        uri: Uri,
        projection: Array<out String>?,
        selection: String?,
        selectionArgs: Array<out String>?,
        sortOrder: String?,
    ): Cursor? = null

    override fun getType(uri: Uri): String? = null

    override fun insert(uri: Uri, values: ContentValues?): Uri? = null

    override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?): Int = 0

    override fun update(
        uri: Uri,
        values: ContentValues?,
        selection: String?,
        selectionArgs: Array<out String>?,
    ): Int = 0

    // ------------------------------------------------------------------
    // 入口
    // ------------------------------------------------------------------

    override fun call(method: String, arg: String?, extras: Bundle?): Bundle {
        val ctx = context ?: return fail("PROVIDER_DOWN", "服务未初始化")
        return when (method) {
            "version" -> ok(mapOf(
                "version" to API_VERSION,
                "authority" to AUTHORITY,
            ))
            "ping" -> ping(ctx)
            "exec" -> exec(ctx, arg ?: "", extras)
            // 未实现的方法明确报错，不静默返回空，免得客户端以为调用成功了
            else -> fail("NO_METHOD", "未知方法：$method")
        }
    }

    // ------------------------------------------------------------------
    // ping：不执行任何命令，只回答「你是谁、框架在跑吗」
    // ------------------------------------------------------------------

    private fun ping(ctx: Context): Bundle {
        val uid = Binder.getCallingUid()
        val pkg = pkgOf(ctx, uid)
        val sig = pkg?.let { BrokerStore.sigHashOf(ctx, it) }
        val granted = pkg != null && sig != null &&
            BrokerStore.find(ctx, pkg, uid, sig) != null
        return ok(mapOf(
            "version" to API_VERSION,
            "uid" to uid,
            "package" to (pkg ?: ""),
            "granted" to granted,
            "frameworkUp" to frameworkAlive(),
        ))
    }

    // ------------------------------------------------------------------
    // exec：核心
    // ------------------------------------------------------------------

    private fun exec(ctx: Context, cmd: String, extras: Bundle?): Bundle {
        val uid = Binder.getCallingUid()
        val t0 = System.currentTimeMillis()

        if (cmd.isBlank()) return fail("EMPTY_CMD", "命令为空")
        if (cmd.length > 4096) return fail("TOO_LONG", "命令过长（上限 4096 字符）")

        // ---- 1. 识别调用方 ----
        // 自己人 / system / root：视为可信，不查授权表。
        // 否则客户端自己调不通、系统调试也会被拦，反而不好排查。
        val trusted = uid == android.os.Process.myUid() ||
            uid == android.os.Process.SYSTEM_UID ||
            uid == 0

        val pkg = if (trusted) (ctx.packageName) else pkgOf(ctx, uid)
        val sig = pkg?.let { BrokerStore.sigHashOf(ctx, it) }
        if (!trusted && (pkg == null || sig == null)) {
            return fail("UNKNOWN_CALLER", "无法识别调用方（uid=$uid）")
        }

        // ---- 2. 校验授权 ----
        var denyCode: String? = null
        var denyMsg: String? = null
        if (!trusted) {
            val g = BrokerStore.find(ctx, pkg!!, uid, sig!!)
            if (g == null) {
                // 记进待授权列表（带节流），然后让用户去应用里批准
                notePendingOnce(ctx, pkg, uid, sig)
                denyCode = "NEED_APPROVAL"
                denyMsg = "未授权：请在 Shell Manager → 设置 → 应用授权 中允许「" +
                    BrokerStore.labelOf(ctx, pkg) + "」执行命令"
            }
        }

        if (denyCode != null) {
            auditOnce(ctx, pkg ?: "?", uid, cmd, denyCode, -1, System.currentTimeMillis() - t0, 0)
            return fail(denyCode, denyMsg ?: "未授权")
        }

        // ---- 3. 框架必须活着：授权通过但框架停了，也要给出可行动的提示 ----
        if (!frameworkAlive()) {
            auditOnce(ctx, pkg ?: "?", uid, cmd, "FRAMEWORK_DOWN", -1,
                System.currentTimeMillis() - t0, 0)
            return fail("FRAMEWORK_DOWN", "iwphone 框架未运行，无法执行命令")
        }

        // ---- 4. 转发给框架 ----
        val token = AutostartPrefs.webuiToken(ctx)
        val timeout = ((extras?.getInt("timeout", 15) ?: 15)).coerceIn(1, 60)
        val cwd = extras?.getString("cwd") ?: ""

        val (code, body) = httpShell(token, cmd, cwd, timeout)
        val elapsed = System.currentTimeMillis() - t0
        if (body == null) {
            auditOnce(ctx, pkg ?: "?", uid, cmd, code, -1, elapsed, 0)
            return fail(code, if (code == "NO_TOKEN") {
                "本应用未配置访问密钥，无法调用框架。请到 设置 → 访问密钥 补上"
            } else {
                "调用框架失败（$code）"
            })
        }

        val ok = body.optBoolean("ok", false)
        val exit = body.optInt("exitCode", -1)
        val stdout = body.optString("stdout", "")
        val stderr = body.optString("stderr", "")
        val msg = body.optString("msg", "")

        if (body.has("msg") && !body.has("exitCode")) {
            // 框架侧拒绝执行（黑名单 / 超时 / 空命令）
            auditOnce(ctx, pkg ?: "?", uid, cmd, "REJECTED", -1, elapsed, 0)
            return fail("REJECTED", msg.ifEmpty { "框架拒绝执行" })
        }

        if (!trusted) BrokerStore.touch(ctx, pkg!!)
        auditOnce(ctx, pkg ?: "?", uid, cmd, "OK", exit, elapsed, stdout.length)

        return ok(mapOf(
            "exitCode" to exit,
            "stdout" to stdout,
            "stderr" to stderr,
            "msg" to msg,
            "elapsedMs" to elapsed.toInt(),
            "ok" to ok,
        ))
    }

    // ------------------------------------------------------------------
    // 框架 HTTP
    // ------------------------------------------------------------------

    /** 轻量探活：只连 127.0.0.1:8537，1 秒超时。连不上就是没跑。 */
    private fun frameworkAlive(): Boolean = try {
        val s = java.net.Socket()
        s.connect(java.net.InetSocketAddress("127.0.0.1", WEBUI_PORT), 1000)
        s.close()
        true
    } catch (_: Exception) {
        false
    }

    /**
     * 调框架的 `/api/shell`。
     *
     * 返回 (结果码, JSON)。结果码只用于把失败原因说清楚：
     *   NO_TOKEN       —— 本应用没有密钥，调不动框架
     *   HTTP_xxx       —— 框架返回非 200
     *   IO_ERROR       —— 连不上 / 读超时
     */
    private fun httpShell(
        token: String,
        cmd: String,
        cwd: String,
        timeoutSec: Int,
    ): Pair<String, JSONObject?> {
        if (token.isEmpty()) return "NO_TOKEN" to null
        var conn: HttpURLConnection? = null
        return try {
            val q = buildString {
                append("/api/shell?cmd=").append(URLEncoder.encode(cmd, "UTF-8"))
                append("&timeout=").append(timeoutSec)
                if (cwd.isNotEmpty()) {
                    append("&cwd=").append(URLEncoder.encode(cwd, "UTF-8"))
                }
            }
            val url = URL("http://127.0.0.1:$WEBUI_PORT$q")
            val c = url.openConnection() as HttpURLConnection
            conn = c
            c.requestMethod = "POST"
            c.connectTimeout = 3000
            // 读超时要盖住框架那边的命令超时，否则命令还在跑我们先断了
            c.readTimeout = (timeoutSec + 8) * 1000
            c.doInput = true
            c.setRequestProperty("X-Token", token)
            val code = c.responseCode
            if (code != 200) return "HTTP_$code" to null
            val text = c.inputStream.bufferedReader().use { it.readText() }
            "OK" to JSONObject(text)
        } catch (_: Exception) {
            "IO_ERROR" to null
        } finally {
            try {
                conn?.disconnect()
            } catch (_: Exception) {
            }
        }
    }

    // ------------------------------------------------------------------
    // 工具
    // ------------------------------------------------------------------

    /**
     * uid → 包名。
     *
     * 一个 uid 可能对应多个包（sharedUserId 的老玩法，新应用基本不用），
     * 这里取第一个即可 —— 授权是按「单个包」发的，多包同 uid 属于历史遗留场景，
     * 真遇到时用户会在授权页看到第一个包名，语义仍然清楚。
     */
    private fun pkgOf(ctx: Context, uid: Int): String? = try {
        ctx.packageManager.getPackagesForUid(uid)?.firstOrNull()
    } catch (_: Exception) {
        null
    }

    private fun notePendingOnce(ctx: Context, pkg: String, uid: Int, sig: String) {
        val now = System.currentTimeMillis()
        val last = lastNote[pkg] ?: 0L
        if (now - last < NOTE_THROTTLE_MS) return
        lastNote[pkg] = now
        BrokerStore.notePending(ctx, pkg, uid, sig)
    }

    private fun auditOnce(
        ctx: Context,
        pkg: String,
        uid: Int,
        cmd: String,
        code: String,
        exit: Int,
        ms: Long,
        outLen: Int,
    ) {
        BrokerStore.appendAudit(ctx, pkg, uid, cmd, code, exit, ms, outLen)
    }

    private fun ok(map: Map<String, Any>): Bundle = Bundle().apply {
        putBoolean("ok", map["ok"] as? Boolean ?: true)
        map.forEach { (k, v) ->
            when (v) {
                is Boolean -> putBoolean(k, v)
                is Int -> putInt(k, v)
                is Long -> putLong(k, v)
                is String -> putString(k, v)
                else -> putString(k, v.toString())
            }
        }
    }

    private fun fail(code: String, msg: String): Bundle = Bundle().apply {
        putBoolean("ok", false)
        putString("code", code)
        putString("msg", msg)
    }
}
