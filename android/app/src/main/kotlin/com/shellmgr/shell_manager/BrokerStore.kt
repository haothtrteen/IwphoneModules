package com.shellmgr.shell_manager

import android.content.Context
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.drawable.BitmapDrawable
import android.graphics.drawable.Drawable
import android.os.Build
import android.util.Base64
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.security.MessageDigest

/**
 * 已授权应用的持久化存储（授权清单 / 待审批请求 / 调用记录）。
 *
 * 为什么单独一个文件：这是一套「权限系统」的状态，生命周期和界面偏好、
 * 自启状态都不同 —— 用户清缓存式地重置 UI 设置时不该顺带把授权清掉。
 *
 * 存储形态刻意用 SharedPreferences + JSON 字符串而不是数据库：
 * 数据量是「几十条」级别，用 SQLite 属于拿大炮打蚊子，还要多一次 schema 迁移负担。
 *
 * ## 授权的身份是三元组 (包名, uid, 签名哈希)
 *
 * 单看包名不够：包名可被别的应用抢注，只有签名能证明「还是原来那个开发者」。
 * 单看 uid 更不够：应用卸载后 uid 会被系统回收给新装的包。
 * 三者一起校验，任一变化都视为「换了人」，重新走审批。
 */
object BrokerStore {

    private const val FILE = "broker_store"
    private const val KEY_GRANTS = "grants"
    private const val KEY_PENDING = "pending"
    private const val KEY_AUDIT = "audit"

    /** 调用记录上限。够回溯最近几十次，又不会把 prefs 撑大。 */
    private const val AUDIT_MAX = 300

    /** 待审批请求上限 —— 防止某个应用反复调用把列表刷爆。 */
    private const val PENDING_MAX = 20

    private fun sp(ctx: Context) = ctx.getSharedPreferences(FILE, Context.MODE_PRIVATE)

    // ---------------- 数据模型 ----------------

    data class Grant(
        val pkg: String,
        val uid: Int,
        val sigHash: String,
        val grantedAt: Long,
        val lastUsed: Long,
        val calls: Int,
    )

    data class PendingReq(
        val pkg: String,
        val uid: Int,
        val sigHash: String,
        val firstAt: Long,
        val lastAt: Long,
        val tries: Int,
    )

    // ---------------- 授权清单 ----------------

    fun grants(ctx: Context): List<Grant> = readArray(ctx, KEY_GRANTS).mapNotNull { o ->
        val pkg = o.optString("pkg")
        if (pkg.isEmpty()) return@mapNotNull null
        Grant(
            pkg = pkg,
            uid = o.optInt("uid", -1),
            sigHash = o.optString("sig"),
            grantedAt = o.optLong("at", 0L),
            lastUsed = o.optLong("use", 0L),
            calls = o.optInt("n", 0),
        )
    }

    /** 精确匹配三元组。同时清理「包没了 / 签名变了」的陈旧条目。 */
    fun find(ctx: Context, pkg: String, uid: Int, sigHash: String): Grant? {
        val all = grants(ctx)
        val hit = all.firstOrNull { it.pkg == pkg }
        if (hit == null) return null
        if (hit.uid != uid || hit.sigHash != sigHash) {
            // 换了签名或换了 uid → 旧授权作废（应用被重装/替换）
            revoke(ctx, pkg)
            return null
        }
        return hit
    }

    fun grant(ctx: Context, pkg: String, uid: Int, sigHash: String) {
        val now = System.currentTimeMillis()
        val list = grants(ctx).filterNot { it.pkg == pkg } + Grant(
            pkg = pkg, uid = uid, sigHash = sigHash,
            grantedAt = now, lastUsed = 0L, calls = 0,
        )
        writeArray(ctx, KEY_GRANTS, list.map { it.toJson() })
        // 授权后从待审批里移除
        writeArray(ctx, KEY_PENDING, pending(ctx).filterNot { it.pkg == pkg }.map { it.toJson() })
    }

    fun revoke(ctx: Context, pkg: String) {
        writeArray(ctx, KEY_GRANTS, grants(ctx).filterNot { it.pkg == pkg }.map { it.toJson() })
    }

    fun revokeAll(ctx: Context) {
        sp(ctx).edit().remove(KEY_GRANTS).apply()
    }

    // ---------------- 待审批 ----------------

    fun pending(ctx: Context): List<PendingReq> = readArray(ctx, KEY_PENDING).mapNotNull { o ->
        val pkg = o.optString("pkg")
        if (pkg.isEmpty()) return@mapNotNull null
        PendingReq(
            pkg = pkg,
            uid = o.optInt("uid", -1),
            sigHash = o.optString("sig"),
            firstAt = o.optLong("first", 0L),
            lastAt = o.optLong("last", 0L),
            tries = o.optInt("n", 0),
        )
    }

    /**
     * 记一次「未授权调用」。
     *
     * 这是界面上「待授权」列表的数据源：用户不一定当场看到授权提示，
     * 事后打开应用也能看见「谁在什么时候要过权限」。
     * 同包 3 秒内重复调用只累加次数，不新增条目。
     */
    fun notePending(ctx: Context, pkg: String, uid: Int, sigHash: String) {
        val now = System.currentTimeMillis()
        val list = pending(ctx).toMutableList()
        val idx = list.indexOfFirst { it.pkg == pkg }
        if (idx >= 0) {
            val old = list[idx]
            list[idx] = old.copy(
                lastAt = now,
                tries = old.tries + 1,
                uid = uid,
                sigHash = sigHash,
            )
        } else {
            if (list.size >= PENDING_MAX) list.removeAt(0)
            list.add(PendingReq(pkg, uid, sigHash, now, now, 1))
        }
        writeArray(ctx, KEY_PENDING, list.map { it.toJson() })
    }

    fun clearPending(ctx: Context, pkg: String? = null) {
        if (pkg == null) {
            sp(ctx).edit().remove(KEY_PENDING).apply()
            return
        }
        writeArray(ctx, KEY_PENDING, pending(ctx).filterNot { it.pkg == pkg }.map { it.toJson() })
    }

    // ---------------- 调用记录 ----------------

    fun auditLog(ctx: Context): List<JSONObject> = readArray(ctx, KEY_AUDIT)

    /**
     * 追加一条调用记录。
     *
     * @param code 结果码（OK / NEED_APPROVAL / DENIED / FRAMEWORK_DOWN / ERROR）
     * @param cmd  原始命令，落盘前截断 —— 记录是给人看的，不是给机器重放的
     */
    fun appendAudit(
        ctx: Context,
        pkg: String,
        uid: Int,
        cmd: String,
        code: String,
        exitCode: Int,
        ms: Long,
        outLen: Int,
    ) {
        val arr = readArray(ctx, KEY_AUDIT).toMutableList()
        val rec = JSONObject()
            .put("t", System.currentTimeMillis())
            .put("pkg", pkg)
            .put("uid", uid)
            .put("cmd", if (cmd.length > 200) cmd.take(200) + "…" else cmd)
            .put("code", code)
            .put("exit", exitCode)
            .put("ms", ms)
            .put("len", outLen)
        arr.add(rec)
        while (arr.size > AUDIT_MAX) arr.removeAt(0)
        writeArray(ctx, KEY_AUDIT, arr)
    }

    fun clearAudit(ctx: Context) {
        sp(ctx).edit().remove(KEY_AUDIT).apply()
    }

    /** 累加调用计数（只对已授权应用有意义）。 */
    fun touch(ctx: Context, pkg: String) {
        val now = System.currentTimeMillis()
        writeArray(ctx, KEY_GRANTS, grants(ctx).map {
            if (it.pkg == pkg) it.copy(lastUsed = now, calls = it.calls + 1) else it
        }.map { it.toJson() })
    }

    // ---------------- 应用信息 ----------------

    /**
     * 签名证书的 SHA-256（取前 32 个十六进制字符）。
     *
     * 取前 32 位而不是全量：界面上要显示给人看，全量 64 位既难读又占地方，
     * 32 位（128 bit）做身份比对已经足够。
     */
    fun sigHashOf(ctx: Context, pkg: String): String? {
        return try {
            val pm = ctx.packageManager
            val bytes: ByteArray? = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                val info = pm.getPackageInfo(pkg, PackageManager.GET_SIGNING_CERTIFICATES)
                val si = info.signingInfo ?: return null
                val certs = if (si.hasMultipleSigners()) si.apkContentsSigners else si.signingCertificateHistory
                certs?.firstOrNull()?.toByteArray()
            } else {
                @Suppress("DEPRECATION")
                val info = pm.getPackageInfo(pkg, PackageManager.GET_SIGNATURES)
                @Suppress("DEPRECATION")
                info.signatures?.firstOrNull()?.toByteArray()
            }
            if (bytes == null) return null
            val md = MessageDigest.getInstance("SHA-256")
            md.digest(bytes).joinToString("") { "%02x".format(it) }.take(32)
        } catch (_: Exception) {
            null
        }
    }

    fun labelOf(ctx: Context, pkg: String): String = try {
        val pm = ctx.packageManager
        pm.getApplicationLabel(pm.getApplicationInfo(pkg, 0)).toString()
    } catch (_: Exception) {
        pkg
    }

    /**
     * 应用图标的 PNG（base64）。
     *
     * 为什么要跨通道传图片：授权页必须让用户「看图认应用」。
     * 只给包名的话，几乎所有人都会在长列表里点错。
     * 尺寸压到 48dp 以内，一个图标通常 2~4KB，一屏几十个也能接受。
     */
    fun iconPngBase64(ctx: Context, pkg: String, sizePx: Int = 96): String? = try {
        val pm = ctx.packageManager
        val d: Drawable = pm.getApplicationIcon(pkg)
        val bmp = when (d) {
            is BitmapDrawable -> d.bitmap
            else -> Bitmap.createBitmap(sizePx, sizePx, Bitmap.Config.ARGB_8888).also {
                val c = Canvas(it)
                d.setBounds(0, 0, sizePx, sizePx)
                d.draw(c)
            }
        }
        val scaled = if (bmp.width > sizePx || bmp.height > sizePx) {
            Bitmap.createScaledBitmap(bmp, sizePx, sizePx, true)
        } else {
            bmp
        }
        val bos = ByteArrayOutputStream()
        scaled.compress(Bitmap.CompressFormat.PNG, 90, bos)
        Base64.encodeToString(bos.toByteArray(), Base64.NO_WRAP)
    } catch (_: Exception) {
        null
    }

    // ---------------- 内部：JSON 读写 ----------------

    private fun readArray(ctx: Context, key: String): List<JSONObject> {
        val raw = sp(ctx).getString(key, null) ?: return emptyList()
        return try {
            val arr = JSONArray(raw)
            (0 until arr.length()).mapNotNull { arr.optJSONObject(it) }
        } catch (_: Exception) {
            emptyList()
        }
    }

    private fun writeArray(ctx: Context, key: String, items: List<JSONObject>) {
        val arr = JSONArray()
        items.forEach { arr.put(it) }
        sp(ctx).edit().putString(key, arr.toString()).apply()
    }

    private fun Grant.toJson(): JSONObject = JSONObject()
        .put("pkg", pkg).put("uid", uid).put("sig", sigHash)
        .put("at", grantedAt).put("use", lastUsed).put("n", calls)

    private fun PendingReq.toJson(): JSONObject = JSONObject()
        .put("pkg", pkg).put("uid", uid).put("sig", sigHash)
        .put("first", firstAt).put("last", lastAt).put("n", tries)
}
