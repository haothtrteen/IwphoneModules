package com.shellmgr.shell_manager

import android.content.ContentProvider
import android.content.ContentValues
import android.content.Context
import android.database.Cursor
import android.net.Uri
import android.os.Binder
import android.os.Bundle
import android.os.ParcelFileDescriptor
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLEncoder
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicInteger

/**
 * 对外授权通道：让**其它应用**经本应用以 shell 身份执行命令（Shizuku 那类能力）。
 *
 * ## 为什么用 ContentProvider
 *
 * - `ContentResolver.call()` 同步，一次往返拿到 stdout/exitCode，客户端不用管回调；
 * - `call()` 跑在 Binder 线程上，`Binder.getCallingUid()` 是**真实调用方** uid
 *   （Service + Messenger 的 Handler 里已经拿不到了）；
 * - 跨应用 provider 调用走标准 Binder，绕开 untrusted_app 与 shell 的 SELinux 域限制。
 *
 * ## 授权触发（v2：请求即确认）
 *
 * 未授权应用发起 `exec` 或 `request` 时，由 [BrokerPrompt] 弹悬浮窗让用户当场
 * 「允许 / 拒绝」，Binder 线程同步等待决定 —— 和 su 卡住等用户点允许是同一体验。
 * 悬浮窗权限未开启时自动降级为原来的「待授权列表 + NEED_APPROVAL」。
 *
 * 身份 = (包名, uid, 签名哈希) 三元组，见 [BrokerStore]。
 * provider **不暴露 grant**：写授权表只能经本应用界面，第三方无法给自己发权限。
 *
 * ## 流式命令（v3：getevent / logcat 这类不结束的命令）
 *
 * `call()` 的返回值是**一个** Bundle，天生装不下"源源不断的输出"。
 * 所以流式走两步，把「授权」和「传数据」分开：
 *
 * ```
 * // 1) 授权 + 登记一条流（同步，可能弹窗）
 * Bundle r = resolver.call(uri, "stream.open", cmd, extras);   // extras: cwd / idle
 * String sid = r.getString("streamId");
 * // 2) 拿管道读端，之后就是普通 InputStream
 * InputStream in = resolver.openInputStream(
 *         Uri.parse("content://com.shellmgr.shell_manager.broker/stream/" + sid));
 * ```
 *
 * 读完每条 NDJSON：`{"type":"out","data":"…"}` / `{"type":"exit","code":0,…}`。
 * 不想读了就 `in.close()`；要立即让远端进程停下，调 `call("stream.kill", sid, null)`。
 *
 * 安全性：sid 是 96 位随机数（猜不到），且 [openFile] 会重新校验
 * `Binder.getCallingUid()` 与登记时的 uid 一致 —— 别的应用即便拿到 sid 也打不开。
 */
class BrokerProvider : ContentProvider() {

    companion object {
        const val AUTHORITY = "com.shellmgr.shell_manager.broker"
        const val API_VERSION = 3
        private const val WEBUI_PORT = 8537
        private const val NOTE_THROTTLE_MS = 10_000L

        /** 流登记后多久没被 openFile 打开就作废（防"开了不读"把登记表撑大）。 */
        private const val STREAM_TTL_MS = 30_000L

        /** 同时在用的管道流上限。每条占一个线程 + 一个子进程组。 */
        private const val MAX_STREAMS = 8
    }

    /** 已登记、等待 openFile 打开的流。 */
    private class PendingStream(
        val uid: Int,
        val pkg: String,
        val cmd: String,
        val cwd: String,
        val idle: Int,
        val at: Long,
    )

    private val pending = ConcurrentHashMap<String, PendingStream>()

    /** 已打开的流：sid → 框架侧的流 id（用于主动 kill）。 */
    private val runningIds = ConcurrentHashMap<String, String>()

    /** 已打开的流：sid → 登记人 uid（kill 时校验归属）。 */
    private val owners = ConcurrentHashMap<String, Int>()
    private val liveStreams = AtomicInteger(0)

    private val lastNote = ConcurrentHashMap<String, Long>()

    override fun onCreate(): Boolean = true

    override fun query(
        uri: Uri,
        projection: Array<out String>?,
        selection: String?,
        selectionArgs: Array<out String>?,
        sortOrder: String?,
    ): Cursor? = null

    override fun getType(uri: Uri): String? =
        if (uri.pathSegments.firstOrNull() == "stream") {
            "application/x-ndjson"
        } else {
            null
        }

    override fun insert(uri: Uri, values: ContentValues?): Uri? = null

    override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?): Int = 0

    override fun update(
        uri: Uri,
        values: ContentValues?,
        selection: String?,
        selectionArgs: Array<out String>?,
    ): Int = 0

    /**
     * 流式管道：`content://…/stream/<sid>` → 读端 ParcelFileDescriptor。
     *
     * 这里**不做授权弹窗**（Binder 线程上已经弹过一次了，见 `stream.open`），
     * 只校验 sid 存在且调用方 uid 与登记时一致。
     */
    override fun openFile(uri: Uri, mode: String): ParcelFileDescriptor? {
        if (mode != "r") throw SecurityException("流只能以只读方式打开")
        val segs = uri.pathSegments
        if (segs.size != 2 || segs[0] != "stream") {
            throw java.io.FileNotFoundException("未知路径：$uri")
        }
        val sid = segs[1]
        val p = pending.remove(sid)
            ?: throw java.io.FileNotFoundException("流不存在或已过期（重新调 stream.open）")

        val caller = Binder.getCallingUid()
        // 登记人与打开人必须是同一个 uid：否则 A 应用登记、B 应用来读
        if (caller != p.uid) {
            throw SecurityException("流不属于当前调用方")
        }
        if (System.currentTimeMillis() - p.at > STREAM_TTL_MS) {
            throw java.io.FileNotFoundException("流登记已过期")
        }
        if (liveStreams.get() >= MAX_STREAMS) {
            throw java.io.IOException("同时打开的流已达上限（$MAX_STREAMS）")
        }

        val ctx = context ?: throw java.io.IOException("服务未初始化")
        if (!frameworkAlive()) throw java.io.IOException("iwphone 框架未运行")

        val pipe = ParcelFileDescriptor.createPipe()
        val readEnd = pipe[0]
        val writeEnd = pipe[1]
        liveStreams.incrementAndGet()

        // Binder 线程不能在这里等数据，开一条独立线程往管道里灌
        Thread {
            pump(ctx, sid, p, writeEnd)
        }.apply { isDaemon = true; start() }

        return readEnd
    }

    // ------------------------------------------------------------------
    // 入口
    // ------------------------------------------------------------------

    override fun call(method: String, arg: String?, extras: Bundle?): Bundle {
        val ctx = context ?: return fail("PROVIDER_DOWN", "服务未初始化")
        return when (method) {
            "version" -> ok(mapOf(
                "version" to API_VERSION,
                "authority" to AUTHORITY,
                "prompt" to BrokerPrompt.canOverlay(ctx),
            ))
            "ping" -> ping(ctx)
            "request" -> requestPermission(ctx)
            "exec" -> exec(ctx, arg ?: "", extras)
            "stream.open" -> streamOpen(ctx, arg ?: "", extras)
            "stream.kill" -> streamKill(ctx, arg ?: "")
            else -> fail("NO_METHOD", "未知方法：$method")
        }
    }

    // ------------------------------------------------------------------
    // 调用方识别 / 授权判定
    // ------------------------------------------------------------------

    private class Caller(
        val uid: Int,
        val pkg: String,
        val sig: String,
        val trusted: Boolean,
    )

    /** 自己人 / system / root 视为可信，其余按 uid 反查包名与签名。 */
    private fun identify(ctx: Context): Caller? {
        val uid = Binder.getCallingUid()
        val trusted = uid == android.os.Process.myUid() ||
            uid == android.os.Process.SYSTEM_UID || uid == 0
        if (trusted) {
            return Caller(uid, ctx.packageName,
                BrokerStore.sigHashOf(ctx, ctx.packageName) ?: "", true)
        }
        val pkg = try {
            ctx.packageManager.getPackagesForUid(uid)?.firstOrNull()
        } catch (_: Exception) {
            null
        } ?: return null
        val sig = BrokerStore.sigHashOf(ctx, pkg) ?: return null
        return Caller(uid, pkg, sig, false)
    }

    private class AuthResult(
        val proceed: Boolean,
        val code: String,
        val msg: String,
        /** 仅本次允许（不落盘），供 request 告知客户端别当成持久授权。 */
        val once: Boolean = false,
    )

    /**
     * 一次授权判定。任何一条路径都不会在用户确认前放行命令。
     *
     * 结果码：TRUSTED / ALREADY / GRANTED / ONCE / DENIED / DENIED_ONCE /
     *        PROMPT_TIMEOUT / PROMPT_BUSY / DENIED_COOLDOWN / NEED_APPROVAL
     */
    private fun authorize(ctx: Context, c: Caller): AuthResult {
        if (c.trusted) return AuthResult(true, "TRUSTED", "")

        if (BrokerStore.find(ctx, c.pkg, c.uid, c.sig) != null) {
            return AuthResult(true, "ALREADY", "")
        }
        if (BrokerStore.isDenied(ctx, c.pkg, c.uid, c.sig)) {
            return AuthResult(false, "DENIED",
                "用户已永久拒绝「${BrokerStore.labelOf(ctx, c.pkg)}」的请求。" +
                    "可在 Shell Manager → 应用授权 → 已拒绝 中解除")
        }

        val label = BrokerStore.labelOf(ctx, c.pkg)
        return when (val d = BrokerPrompt.ask(ctx, c.pkg, c.uid, c.sig)) {
            BrokerPrompt.Decision.ALLOW_ALWAYS -> {
                BrokerStore.grant(ctx, c.pkg, c.uid, c.sig)
                AuthResult(true, "GRANTED", "用户已允许「$label」执行命令")
            }
            BrokerPrompt.Decision.ALLOW_ONCE ->
                AuthResult(true, "ONCE", "用户仅允许本次", once = true)
            BrokerPrompt.Decision.DENY_ALWAYS -> {
                BrokerStore.deny(ctx, c.pkg, c.uid, c.sig)
                AuthResult(false, "DENIED", "用户已永久拒绝「$label」的请求")
            }
            BrokerPrompt.Decision.DENY ->
                AuthResult(false, "DENIED_ONCE", "用户拒绝了本次请求（60 秒后可重试）")
            BrokerPrompt.Decision.TIMEOUT ->
                AuthResult(false, "PROMPT_TIMEOUT", "授权弹窗超时未处理，已按拒绝处理")
            BrokerPrompt.Decision.BUSY ->
                AuthResult(false, "PROMPT_BUSY", "同时等待授权的应用过多，请稍后重试")
            BrokerPrompt.Decision.COOLDOWN ->
                AuthResult(false, "DENIED_COOLDOWN", "刚刚被拒绝，请稍后再试")
            BrokerPrompt.Decision.NO_UI -> {
                // 没开悬浮窗权限：退回旧的「待授权列表」流程，功能不中断
                notePendingOnce(ctx, c.pkg, c.uid, c.sig)
                AuthResult(false, "NEED_APPROVAL",
                    "未授权：请在 Shell Manager → 设置 → 应用授权 中允许「$label」执行命令")
            }
        }
    }

    // ------------------------------------------------------------------
    // ping / request
    // ------------------------------------------------------------------

    private fun ping(ctx: Context): Bundle {
        val uid = Binder.getCallingUid()
        val pkg = pkgOf(ctx, uid)
        val sig = pkg?.let { BrokerStore.sigHashOf(ctx, it) }
        return ok(mapOf(
            "version" to API_VERSION,
            "uid" to uid,
            "package" to (pkg ?: ""),
            "granted" to (pkg != null && sig != null &&
                BrokerStore.find(ctx, pkg, uid, sig) != null),
            "denied" to (pkg != null && sig != null &&
                BrokerStore.isDenied(ctx, pkg, uid, sig)),
            "promptReady" to BrokerPrompt.canOverlay(ctx),
            "frameworkUp" to frameworkAlive(),
        ))
    }

    /**
     * 只请求授权、不执行命令。给终端类应用先拿权限、再执行后续命令用。
     *
     * 未授权时同样会弹窗并同步等待；允许后返回 granted=true。
     */
    private fun requestPermission(ctx: Context): Bundle {
        val c = identify(ctx)
            ?: return fail("UNKNOWN_CALLER", "无法识别调用方（uid=${Binder.getCallingUid()}）")
        val t0 = System.currentTimeMillis()
        val a = authorize(ctx, c)
        BrokerStore.appendAudit(ctx, c.pkg, c.uid, "(request)", a.code, -1,
            System.currentTimeMillis() - t0, 0)
        return if (a.proceed) {
            ok(mapOf(
                "granted" to true,
                "code" to a.code,
                "once" to a.once,
                "msg" to a.msg,
            ))
        } else {
            fail(a.code, a.msg)
        }
    }

    // ------------------------------------------------------------------
    // exec
    // ------------------------------------------------------------------

    private fun exec(ctx: Context, cmd: String, extras: Bundle?): Bundle {
        val t0 = System.currentTimeMillis()

        if (cmd.isBlank()) return fail("EMPTY_CMD", "命令为空")
        if (cmd.length > 4096) return fail("TOO_LONG", "命令过长（上限 4096 字符）")

        val c = identify(ctx)
            ?: return fail("UNKNOWN_CALLER", "无法识别调用方（uid=${Binder.getCallingUid()}）")

        // ★ 授权在命令执行之前；弹窗期间 Binder 线程一直等着，不会先跑再问
        val auth = authorize(ctx, c)
        if (!auth.proceed) {
            auditOnce(ctx, c.pkg, c.uid, cmd, auth.code, -1,
                System.currentTimeMillis() - t0, 0)
            return fail(auth.code, auth.msg)
        }

        if (!frameworkAlive()) {
            auditOnce(ctx, c.pkg, c.uid, cmd, "FRAMEWORK_DOWN", -1,
                System.currentTimeMillis() - t0, 0)
            return fail("FRAMEWORK_DOWN", "iwphone 框架未运行，无法执行命令")
        }

        val token = AutostartPrefs.webuiToken(ctx)
        val timeout = ((extras?.getInt("timeout", 15) ?: 15)).coerceIn(1, 60)
        val cwd = extras?.getString("cwd") ?: ""

        val (code, body) = httpShell(token, cmd, cwd, timeout)
        val elapsed = System.currentTimeMillis() - t0
        if (body == null) {
            auditOnce(ctx, c.pkg, c.uid, cmd, code, -1, elapsed, 0)
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
            auditOnce(ctx, c.pkg, c.uid, cmd, "REJECTED", -1, elapsed, 0)
            return fail("REJECTED", msg.ifEmpty { "框架拒绝执行" })
        }

        if (!c.trusted) BrokerStore.touch(ctx, c.pkg)
        auditOnce(ctx, c.pkg, c.uid, cmd, "OK", exit, elapsed, stdout.length)

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
    // 流式命令
    // ------------------------------------------------------------------

    /**
     * 授权并登记一条流，返回可交给 [openFile] 的 sid。
     *
     * 为什么拆成两步：`call()` 只能返回一个 Bundle，装不下持续输出；
     * `openFile()` 才是能给出 InputStream 的入口。授权放在这里是因为
     * 它可以同步等用户点弹窗（和 `exec` 完全一样），而 openFile 里再弹窗
     * 会让调用方拿到一个含义不明的 fd。
     */
    private fun streamOpen(ctx: Context, cmd: String, extras: Bundle?): Bundle {
        val t0 = System.currentTimeMillis()
        if (cmd.isBlank()) return fail("EMPTY_CMD", "命令为空")
        if (cmd.length > 4096) return fail("TOO_LONG", "命令过长（上限 4096 字符）")

        val c = identify(ctx)
            ?: return fail("UNKNOWN_CALLER", "无法识别调用方（uid=${Binder.getCallingUid()}）")

        val auth = authorize(ctx, c)
        if (!auth.proceed) {
            auditOnce(ctx, c.pkg, c.uid, "[stream] $cmd", auth.code, -1,
                System.currentTimeMillis() - t0, 0)
            return fail(auth.code, auth.msg)
        }
        if (!frameworkAlive()) {
            auditOnce(ctx, c.pkg, c.uid, "[stream] $cmd", "FRAMEWORK_DOWN", -1,
                System.currentTimeMillis() - t0, 0)
            return fail("FRAMEWORK_DOWN", "iwphone 框架未运行，无法执行命令")
        }

        val now = System.currentTimeMillis()
        // 清掉过期登记，避免"申请了却不打开"把表撑大
        val it = pending.entries.iterator()
        while (it.hasNext()) {
            if (now - it.next().value.at > STREAM_TTL_MS) it.remove()
        }
        if (pending.size + liveStreams.get() >= MAX_STREAMS) {
            return fail("TOO_MANY_STREAMS", "同时打开的流已达上限（$MAX_STREAMS）")
        }

        val sid = ByteArray(12).also { java.security.SecureRandom().nextBytes(it) }
            .joinToString("") { "%02x".format(it) }
        val cwd = extras?.getString("cwd") ?: ""
        val idle = (extras?.getInt("idle", 30) ?: 30).coerceIn(0, 3600)
        pending[sid] = PendingStream(c.uid, c.pkg, cmd, cwd, idle, now)

        if (!c.trusted) BrokerStore.touch(ctx, c.pkg)
        auditOnce(ctx, c.pkg, c.uid, "[stream] $cmd", "OK", -1,
            System.currentTimeMillis() - t0, 0)

        return ok(mapOf(
            "streamId" to sid,
            "uri" to "content://$AUTHORITY/stream/$sid",
            "idle" to idle,
        ))
    }

    /** 主动结束一条流（可选，读完直接 close 管道也行）。 */
    private fun streamKill(ctx: Context, sid: String): Bundle {
        if (sid.isEmpty()) return fail("BAD_ARG", "缺少 streamId")
        val c = identify(ctx) ?: return fail("UNKNOWN_CALLER", "无法识别调用方")

        // 还没 openFile 的登记：直接撤掉
        val p = pending.remove(sid)
        if (p != null) {
            if (!c.trusted && p.uid != c.uid) {
                return fail("NOT_OWNER", "流不属于当前调用方")
            }
            return ok(mapOf("killed" to false, "msg" to "登记已撤销（流尚未打开）"))
        }

        val owner = owners[sid]
        if (owner != null && !c.trusted && owner != c.uid) {
            return fail("NOT_OWNER", "流不属于当前调用方")
        }
        val fid = runningIds.remove(sid) ?: return ok(mapOf("killed" to false))
        killFrameworkStream(AutostartPrefs.webuiToken(ctx), fid)
        auditOnce(ctx, c.pkg, c.uid, "[stream.kill] $sid", "OK", -1, 0, 0)
        return ok(mapOf("killed" to true))
    }

    /**
     * 把框架的 NDJSON 灌进管道。
     *
     * 读端被调用方关掉时，这里的 write 会抛 BrokenPipe（管道缓冲写满之后），
     * 于是顺势断开 HTTP 并 kill 框架侧的进程组 —— 不会留下孤儿。
     * 如果命令本身很安静、缓冲一直没写满，就靠框架的空闲超时兜底。
     */
    private fun pump(
        ctx: Context,
        sid: String,
        p: PendingStream,
        writeEnd: ParcelFileDescriptor,
    ) {
        val token = AutostartPrefs.webuiToken(ctx)
        val started = System.currentTimeMillis()
        val out = ParcelFileDescriptor.AutoCloseOutputStream(writeEnd)
        var conn: HttpURLConnection? = null
        var clientGone = false
        var total = 0L

        try {
            val q = buildString {
                append("/api/shell/stream?cmd=").append(URLEncoder.encode(p.cmd, "UTF-8"))
                append("&idle=").append(p.idle)
                if (p.cwd.isNotEmpty()) {
                    append("&cwd=").append(URLEncoder.encode(p.cwd, "UTF-8"))
                }
            }
            val c = URL("http://127.0.0.1:$WEBUI_PORT$q").openConnection() as HttpURLConnection
            conn = c
            c.requestMethod = "POST"
            c.connectTimeout = 3000
            c.readTimeout = 0
            c.setRequestProperty("X-Token", token)

            if (c.responseCode != 200) {
                val body = try {
                    c.errorStream?.bufferedReader()?.use { it.readText() }
                } catch (_: Exception) {
                    null
                }
                // 统一成一条 error 事件，客户端只需要认识 NDJSON 一种格式
                var code = "HTTP_${c.responseCode}"
                var msg = "框架拒绝建立流（HTTP ${c.responseCode}）"
                try {
                    val o = JSONObject(body ?: "")
                    if (o.optString("code").isNotEmpty()) code = o.optString("code")
                    if (o.optString("msg").isNotEmpty()) msg = o.optString("msg")
                } catch (_: Exception) {
                }
                val ev = JSONObject()
                    .put("type", "error").put("code", code).put("msg", msg)
                out.write(ev.toString().toByteArray(Charsets.UTF_8))
                out.flush()
                return
            }

            val input = c.inputStream
            val buf = ByteArray(8192)
            val idScan = StringBuilder()
            var gotId = false
            while (true) {
                val n = try {
                    input.read(buf)
                } catch (_: Exception) {
                    -1
                }
                if (n < 0) break
                if (n == 0) continue
                out.write(buf, 0, n)
                out.flush()
                total += n
                // 首行里有框架侧的流 id，留作断连时主动回收用
                if (!gotId) {
                    var i = 0
                    while (i < n && !gotId) {
                        val ch = buf[i].toInt().toChar()
                        if (ch == '\n') {
                            gotId = true
                            val fid = try {
                                JSONObject(idScan.toString()).optString("id", "")
                            } catch (_: Exception) {
                                ""
                            }
                            if (fid.isNotEmpty()) {
                                runningIds[sid] = fid
                                owners[sid] = p.uid
                            }
                        } else if (idScan.length < 4096) {
                            idScan.append(ch)
                        }
                        i++
                    }
                }
            }
        } catch (_: Exception) {
            clientGone = true
        } finally {
            if (clientGone) {
                runningIds.remove(sid)?.let { killFrameworkStream(token, it) }
            }
            runningIds.remove(sid)
            owners.remove(sid)
            liveStreams.decrementAndGet()
            try {
                out.close()
            } catch (_: Exception) {
            }
            try {
                conn?.disconnect()
            } catch (_: Exception) {
            }
            BrokerStore.appendAudit(
                ctx, p.pkg, p.uid, "[stream] ${p.cmd}",
                if (clientGone) "CLIENT_GONE" else "END", -1,
                System.currentTimeMillis() - started, total.toInt(),
            )
        }
    }

    private fun killFrameworkStream(token: String, fid: String) {
        if (token.isEmpty() || fid.isEmpty()) return
        var c: HttpURLConnection? = null
        try {
            c = URL("http://127.0.0.1:$WEBUI_PORT/api/stream/kill?id=$fid")
                .openConnection() as HttpURLConnection
            c.requestMethod = "POST"
            c.connectTimeout = 1500
            c.readTimeout = 2000
            c.setRequestProperty("X-Token", token)
            c.responseCode
            try {
                c.inputStream.close()
            } catch (_: Exception) {
            }
        } catch (_: Exception) {
        } finally {
            try {
                c?.disconnect()
            } catch (_: Exception) {
            }
        }
    }

    // ------------------------------------------------------------------
    // 框架 HTTP
    // ------------------------------------------------------------------

    private fun frameworkAlive(): Boolean = try {
        val s = java.net.Socket()
        s.connect(java.net.InetSocketAddress("127.0.0.1", WEBUI_PORT), 1000)
        s.close()
        true
    } catch (_: Exception) {
        false
    }

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
            val c = URL("http://127.0.0.1:$WEBUI_PORT$q").openConnection() as HttpURLConnection
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

    private fun pkgOf(ctx: Context, uid: Int): String? = try {
        ctx.packageManager.getPackagesForUid(uid)?.firstOrNull()
    } catch (_: Exception) {
        null
    }

    private fun notePendingOnce(ctx: Context, pkg: String, uid: Int, sig: String) {
        val now = System.currentTimeMillis()
        if (now - (lastNote[pkg] ?: 0L) < NOTE_THROTTLE_MS) return
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
