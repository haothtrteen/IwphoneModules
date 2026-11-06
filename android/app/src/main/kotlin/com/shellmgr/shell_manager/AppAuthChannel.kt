package com.shellmgr.shell_manager

import android.content.Intent
import android.net.Uri
import android.provider.Settings
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject

/**
 * 「应用授权」的 Flutter ↔ 原生桥（`shellmgr/appauth`）。
 *
 * 这里只做**本应用内部**的界面数据供给：列出已授权应用、待授权请求、调用记录，
 * 以及批准/撤销。真正的跨应用调用入口在 [BrokerProvider]，两者共用 [BrokerStore]。
 *
 * 为什么不把这些操作也开放给 ContentProvider：授权必须由用户在界面上操作，
 * 若能经 provider 调 `grant`，任何应用都能给自己发权限，整套机制就废了。
 */
class AppAuthChannel(private val ctx: android.content.Context) {

    companion object {
        const val CHANNEL = "shellmgr/appauth"
    }

    fun register(messenger: BinaryMessenger) {
        MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "listGrants" -> runAsync(result) {
                    val arr = JSONArray()
                    BrokerStore.grants(ctx).sortedByDescending { it.grantedAt }.forEach { g ->
                        arr.put(entryOf(g.pkg, g.uid, g.sigHash, mapOf(
                            "grantedAt" to g.grantedAt,
                            "lastUsed" to g.lastUsed,
                            "calls" to g.calls,
                        )))
                    }
                    mapOf("ok" to true, "items" to arr.toString())
                }

                "listPending" -> runAsync(result) {
                    val arr = JSONArray()
                    BrokerStore.pending(ctx).sortedByDescending { it.lastAt }.forEach { p ->
                        arr.put(entryOf(p.pkg, p.uid, p.sigHash, mapOf(
                            "grantedAt" to 0L,
                            "firstAt" to p.firstAt,
                            "lastAt" to p.lastAt,
                            "tries" to p.tries,
                        )))
                    }
                    mapOf("ok" to true, "items" to arr.toString())
                }

                "listDenied" -> runAsync(result) {
                    val arr = JSONArray()
                    BrokerStore.deniedList(ctx).sortedByDescending { it.at }.forEach { d ->
                        arr.put(entryOf(d.pkg, d.uid, d.sigHash, mapOf(
                            "grantedAt" to d.at,
                        )))
                    }
                    mapOf("ok" to true, "items" to arr.toString())
                }

                "clearDenied" -> {
                    val pkg = call.argument<String>("pkg")
                    BrokerStore.clearDenied(ctx, pkg)
                    result.success(mapOf("ok" to true))
                }

                /** 悬浮窗权限是否已开 —— 决定「请求即确认」能不能用。 */
                "overlayState" -> result.success(
                    mapOf("ok" to true, "enabled" to BrokerPrompt.canOverlay(ctx))
                )

                /** 跳系统「显示在其他应用上层」设置页。 */
                "openOverlaySettings" -> result.success(openOverlaySettings())

                "grant" -> {
                    val pkg = call.argument<String>("pkg") ?: ""
                    result.success(grant(pkg))
                }

                "revoke" -> {
                    val pkg = call.argument<String>("pkg") ?: ""
                    BrokerStore.revoke(ctx, pkg)
                    result.success(mapOf("ok" to true))
                }

                "revokeAll" -> {
                    BrokerStore.revokeAll(ctx)
                    result.success(mapOf("ok" to true))
                }

                "clearPending" -> {
                    val pkg = call.argument<String>("pkg")
                    BrokerStore.clearPending(ctx, pkg)
                    result.success(mapOf("ok" to true))
                }

                "listAudit" -> runAsync(result) {
                    val arr = JSONArray()
                    BrokerStore.auditLog(ctx).takeLast(200).reversed().forEach { arr.put(it) }
                    mapOf("ok" to true, "items" to arr.toString())
                }

                "clearAudit" -> {
                    BrokerStore.clearAudit(ctx)
                    result.success(mapOf("ok" to true))
                }

                /**
                 * 可选应用列表（供「添加应用」挑选）。
                 *
                 * 只列**有启动图标**的应用，理由：
                 *   - 拿得到启动器列表就不需要 QUERY_ALL_PACKAGES 这个敏感权限
                 *     （Google Play 上的高风险声明项，我们自用侧载也不想背）
                 *   - 用户要授权的对象是「他认识的应用」，本来就有图标
                 */
                "installedApps" -> runAsync(result) { installedApps() }

                /** 把接入示例脚本导出到 App 外部私有目录，返回绝对路径。 */
                "exportScript" -> {
                    val name = call.argument<String>("name")
                        ?: "iwphone_request_permission.sh"
                    val text = call.argument<String>("text") ?: ""
                    result.success(exportScript(name, text))
                }

                /** 当前是否有可用的访问密钥 —— 没有的话授权页要提示用户先设置。 */
                "tokenState" -> {
                    val t = AutostartPrefs.webuiToken(ctx)
                    result.success(mapOf("ok" to true, "hasToken" to t.isNotEmpty()))
                }

                else -> result.notImplemented()
            }
        }
    }

    // ------------------------------------------------------------------

    /**
     * 导出脚本到 getExternalFilesDir —— App 专属外部目录，
     * 分区存储下无需任何权限即可写，用户用文件管理器/adb 都能取到。
     */
    private fun exportScript(name: String, text: String): Map<String, Any?> {
        if (text.isEmpty()) return mapOf("ok" to false, "path" to "")
        return try {
            val dir = ctx.getExternalFilesDir(null) ?: ctx.filesDir
            // 部分 ROM 上 App 专属外部 files/ 目录尚未创建，writeText 会直接抛
            // FileNotFoundException；实测设备里该目录就是缺失的。
            if (!dir.exists()) dir.mkdirs()
            val safe = name.replace(Regex("[^A-Za-z0-9._-]"), "_")
            val f = java.io.File(dir, safe)
            f.writeText(text)
            f.setReadable(true, false)
            mapOf("ok" to true, "path" to f.absolutePath)
        } catch (e: Exception) {
            mapOf("ok" to false, "path" to "", "msg" to (e.message ?: ""))
        }
    }

    private fun openOverlaySettings(): Map<String, Any?> = try {
        val intent = Intent(
            Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
            Uri.parse("package:${ctx.packageName}"),
        ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        ctx.startActivity(intent)
        mapOf("ok" to true)
    } catch (e: Exception) {
        mapOf("ok" to false, "msg" to "无法打开悬浮窗设置：${e.message}")
    }

    private fun grant(pkg: String): Map<String, Any?> {
        if (pkg.isEmpty()) return mapOf("ok" to false, "msg" to "包名为空")
        val uid = try {
            ctx.packageManager.getApplicationInfo(pkg, 0).uid
        } catch (e: Exception) {
            return mapOf("ok" to false, "msg" to "应用不存在：$pkg")
        }
        val sig = BrokerStore.sigHashOf(ctx, pkg)
            ?: return mapOf("ok" to false, "msg" to "读取签名失败，无法建立可信身份")
        BrokerStore.grant(ctx, pkg, uid, sig)
        return mapOf("ok" to true, "msg" to "已授权", "sig" to sig)
    }

    private fun installedApps(): Map<String, Any?> {
        val pm = ctx.packageManager
        val intent = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
        val resolved = pm.queryIntentActivities(intent, 0)

        val granted = BrokerStore.grants(ctx).map { it.pkg }.toSet()
        val seen = HashSet<String>()
        val arr = JSONArray()

        resolved.forEach { ri ->
            val pkg = ri.activityInfo?.packageName ?: return@forEach
            if (pkg == ctx.packageName || !seen.add(pkg)) return@forEach
            val label = try {
                ri.loadLabel(pm).toString()
            } catch (_: Exception) {
                pkg
            }
            val o = JSONObject()
                .put("pkg", pkg)
                .put("label", label)
                .put("granted", granted.contains(pkg))
            BrokerStore.iconPngBase64(ctx, pkg)?.let { o.put("icon", it) }
            arr.put(o)
        }

        // 按名字排序，中文按拼音的直觉排序交给 Dart 侧不做，这里给个稳定序即可
        val list = (0 until arr.length()).map { arr.getJSONObject(it) }
            .sortedBy { it.optString("label") }
        val out = JSONArray()
        list.forEach { out.put(it) }
        return mapOf("ok" to true, "items" to out.toString())
    }

    private fun entryOf(
        pkg: String,
        uid: Int,
        sig: String,
        extra: Map<String, Any>,
    ): JSONObject {
        val o = JSONObject()
            .put("pkg", pkg)
            .put("uid", uid)
            .put("sig", sig)
            .put("label", BrokerStore.labelOf(ctx, pkg))
        extra.forEach { (k, v) ->
            when (v) {
                is Long -> o.put(k, v)
                is Int -> o.put(k, v)
                else -> o.put(k, v.toString())
            }
        }
        BrokerStore.iconPngBase64(ctx, pkg)?.let { o.put("icon", it) }
        return o
    }

    /** 把耗时调用丢到后台线程 —— 读应用列表 + 编码几十个图标能到几百毫秒。 */
    private fun runAsync(
        result: MethodChannel.Result,
        block: () -> Map<String, Any?>,
    ) {
        Thread {
            val payload = try {
                block()
            } catch (e: Exception) {
                mapOf(
                    "ok" to false,
                    "msg" to "未预期异常：${e.javaClass.simpleName}: ${e.message}",
                )
            }
            result.success(payload)
        }.start()
    }
}
