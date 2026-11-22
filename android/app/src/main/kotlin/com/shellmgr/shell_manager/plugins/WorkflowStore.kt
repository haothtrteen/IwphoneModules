package com.shellmgr.shell_manager.plugins

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.widget.Toast
import org.json.JSONArray
import org.json.JSONObject
import com.shellmgr.shell_manager.AdbBootstrap
import com.shellmgr.shell_manager.UiPrefs
import java.io.ByteArrayOutputStream
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream

/**
 * 可视化工作流存储。
 *
 * 借鉴 vFlow：工作流 = 有序步骤列表，每步 = moduleId + parameters。
 * 模块目录由 Dart 侧声明（可视化表单的数据源），这里负责持久化与执行。
 *
 * ★ 早期这里只有纯 adb 命令，确实「新增模块不用改 Kotlin」。
 *   加入 `system.toast` / `ui.*` 之后不再成立：这些动作必须调 Android API，
 *   新增这类模块仍需在 [executeStep] 加分支。纯 shell 类动作依旧不用改。
 *
 * 零第三方依赖，SharedPreferences + org.json。
 */
object WorkflowStore {
    private const val FILE = "iwphone_workflows"
    private const val KEY = "items"

    /** flow.run 的递归上限，防住「A 调 B、B 又调 A」的死循环。 */
    private const val MAX_DEPTH = 6

    private fun sp(ctx: Context) = ctx.getSharedPreferences(FILE, Context.MODE_PRIVATE)

    fun list(ctx: Context): List<JSONObject> {
        val raw = sp(ctx).getString(KEY, null) ?: return emptyList()
        return try {
            val arr = JSONArray(raw)
            (0 until arr.length()).mapNotNull { arr.optJSONObject(it) }
        } catch (_: Exception) {
            emptyList()
        }
    }

    fun save(ctx: Context, json: JSONObject) {
        val id = json.optString("id")
        if (id.isEmpty()) return
        val arr = JSONArray(list(ctx).filterNot { it.optString("id") == id }.map { it })
        arr.put(json)
        sp(ctx).edit().putString(KEY, arr.toString()).apply()
    }

    fun delete(ctx: Context, id: String) {
        val arr = JSONArray(list(ctx).filterNot { it.optString("id") == id }.map { it })
        sp(ctx).edit().putString(KEY, arr.toString()).apply()
    }

    fun get(ctx: Context, id: String): JSONObject? = list(ctx).firstOrNull { it.optString("id") == id }

    /**
     * 按 id 解析工作流：先查本地，再查模块自带的 automation.json。
     *
     * 模块那份是只读的（`readonly=true`），这里只用于执行与导出，
     * 不回写 SharedPreferences。
     */
    fun resolve(ctx: Context, id: String): JSONObject? =
        get(ctx, id) ?: ModuleAutomation.find(id)

    fun isModuleWorkflow(wf: JSONObject?): Boolean = wf?.optBoolean("readonly") == true

    /** 执行本地工作流（id 语义，保留给旧调用点）。 */
    fun run(ctx: Context, id: String): RunResult {
        val wf = get(ctx, id) ?: return RunResult(false, "工作流不存在: $id")
        return runWorkflow(ctx, wf)
    }

    /** 执行任意来源的工作流（本地 / 模块自带）。 */
    fun runAny(ctx: Context, id: String): RunResult {
        val wf = resolve(ctx, id) ?: return RunResult(false, "工作流不存在: $id")
        return runWorkflow(ctx, wf)
    }

    /**
     * 顺序遍历步骤，按 moduleId 分派。
     * 触发器由 AutomationRegistry 的 event handler 负责，不进步骤列表。
     */
    fun runWorkflow(ctx: Context, wf: JSONObject, depth: Int = 0): RunResult {
        if (depth > MAX_DEPTH) return RunResult(false, "调用层级过深（疑似循环）")
        val steps = wf.optJSONArray("steps") ?: return RunResult(false, "工作流没有步骤")
        val results = mutableListOf<String>()
        for (i in 0 until steps.length()) {
            val step = steps.optJSONObject(i) ?: continue
            if (step.optBoolean("disabled", false)) {
                results.add("[$i] skipped")
                continue
            }
            val moduleId = step.optString("moduleId")
            val params = step.optJSONObject("params") ?: JSONObject()
            val r = executeStep(ctx, moduleId, params, depth)
            results.add("[$i] $moduleId: ${if (r.ok) "OK" else r.message}")
            if (!r.ok && wf.optBoolean("stopOnError", true)) {
                return RunResult(false, results.joinToString("; "))
            }
        }
        PlatformEventBus.publish(
            PlatformEvent(
                id = "automation:${wf.optString("id")}",
                kind = PlatformEvent.KIND_AUDIT,
                reason = if (results.isEmpty()) "无步骤" else "完成 ${results.size} 步",
            )
        )
        return RunResult(true, results.joinToString("; "))
    }

    private fun executeStep(
        ctx: Context,
        moduleId: String,
        p: JSONObject,
        depth: Int,
    ): StepResult {
        return when (moduleId) {
            // ---- 触发器占位（旧版编辑器把 trigger.* 当第一步，已迁到工作流头部） ----
            "trigger.event", "trigger.manual" -> StepResult(true, "trigger (moved to header)")

            // ---- adb shell 动作（不依赖无障碍） ----
            "adb.tap" -> runAdb(ctx, "input tap ${p.optInt("x")} ${p.optInt("y")}")
            "adb.swipe" -> runAdb(ctx, "input swipe ${p.optInt("x1")} ${p.optInt("y1")} " +
                "${p.optInt("x2")} ${p.optInt("y2")} ${p.optInt("duration", 300)}")
            "adb.text" -> runAdb(ctx, "input text ${p.optString("text").replace(Regex("\\s+"), "%s")}")
            "adb.key" -> runAdb(ctx, "input keyevent ${p.optInt("code", 4)}")
            "adb.start" -> runAdb(ctx, "am start -n ${p.optString("package")}/.MainActivity")
            "adb.stop" -> runAdb(ctx, "am force-stop ${p.optString("package")}")
            "adb.screencap" -> runAdb(ctx, "screencap -p ${p.optString("path")}")
            "adb.raw" -> {
                // 高危：原始命令走 ShellCapability 的 highRisk 流程（由调用方确认）
                val req = ActionRequest(action = "raw",
                    args = mapOf("cmd" to p.optString("cmd")), highRisk = true)
                val r = ShellCapability().execute(ctx, req)
                StepResult(r.ok, r.message)
            }

            // ---- 模块动作 ----
            "module.run" -> {
                val name = p.optString("module")
                val op = p.optString("op", "run")
                val cmd = "curl -sS --max-time 30 -X POST " +
                    "\"http://127.0.0.1:8537/api/module/$name/$op\""
                val r = AdbBootstrap.run(ctx,
                    listOf("-s", AdbBootstrap.currentTarget(), "shell", cmd),
                    timeoutMs = 40_000)
                StepResult(r.ok, r.message)
            }

            // ---- 逻辑 ----
            "logic.delay" -> {
                try {
                    Thread.sleep(p.optLong("ms", 1000).coerceIn(0, 60_000))
                    StepResult(true, "delayed")
                } catch (_: InterruptedException) {
                    StepResult(false, "interrupted")
                }
            }

            "flow.run" -> {
                val id = p.optString("workflow")
                val sub = resolve(ctx, id) ?: return StepResult(false, "子工作流不存在: $id")
                val r = runWorkflow(ctx, sub, depth + 1)
                StepResult(r.ok, r.message)
            }

            // ---- 界面识别 / 提示（需要 App 进程内的 Android API） ----
            // vFlow 的 `显示Toast` / `查找控件` / `查找直到出现` 的最小版本。
            // 不引入 ML Kit：读无障碍控件树而不是识别图片像素，见 UiActions 的说明。
            "system.toast" -> {
                val msg = p.optString("message")
                if (msg.isEmpty()) {
                    StepResult(false, "消息为空")
                } else {
                    // Toast 必须切回主线程；工作流跑在后台线程上。
                    val done = CountDownLatch(1)
                    Handler(Looper.getMainLooper()).post {
                        try {
                            Toast.makeText(
                                ctx.applicationContext, msg, Toast.LENGTH_SHORT,
                            ).show()
                        } catch (_: Exception) {
                        } finally {
                            done.countDown()
                        }
                    }
                    try {
                        done.await(2, TimeUnit.SECONDS)
                    } catch (_: InterruptedException) {
                    }
                    StepResult(true, "toast: $msg")
                }
            }

            "ui.text" -> {
                val svc = UiActions.isEnabled()
                if (!svc) {
                    StepResult(false, "无障碍服务未开启：系统设置 → 无障碍 → IWPhone")
                } else {
                    val nodes = UiActions.dump(p.optInt("max", 300), 16)
                    val filter = p.optString("filter").trim()
                    val lines = nodes.map { it.label() }.filter { line ->
                        if (filter.isEmpty()) true else {
                            try {
                                Regex(filter).containsMatchIn(line)
                            } catch (_: Exception) {
                                line.contains(filter, ignoreCase = true)
                            }
                        }
                    }
                    StepResult(
                        true,
                        if (lines.isEmpty()) "（未读到界面文字）"
                        else lines.take(80).joinToString("\n"),
                    )
                }
            }

            "ui.find" -> {
                if (!UiActions.isEnabled()) {
                    StepResult(false, "无障碍服务未开启：系统设置 → 无障碍 → IWPhone")
                } else {
                    val n = UiActions.find(
                        text = p.optString("text"),
                        viewId = p.optString("viewId"),
                        matchMode = p.optString("match", UiActions.MATCH_CONTAINS),
                        maxNodes = p.optInt("max", 300),
                    )
                    if (n == null) {
                        StepResult(false, "未找到匹配控件")
                    } else if (p.optBoolean("click", true)) {
                        // 用既有 adb 通道点击中心点：和 adb.tap 完全同一条路径，
                        // 比 performAction(ACTION_CLICK) 更能穿过不可点击的包装层。
                        val r = runAdb(ctx, "input tap ${n.x} ${n.y}")
                        StepResult(r.ok, if (r.ok) "点击 ${n.label()}" else r.message)
                    } else {
                        StepResult(true, "找到 ${n.label()}")
                    }
                }
            }

            "ui.waitText" -> {
                if (!UiActions.isEnabled()) {
                    StepResult(false, "无障碍服务未开启：系统设置 → 无障碍 → IWPhone")
                } else {
                    val appear = p.optBoolean("appear", true)
                    val r = UiActions.waitFor(
                        text = p.optString("text"),
                        viewId = p.optString("viewId"),
                        matchMode = p.optString("match", UiActions.MATCH_CONTAINS),
                        timeoutMs = p.optLong("timeoutMs", 5_000).coerceIn(100, 60_000),
                        intervalMs = p.optLong("intervalMs", 300),
                        appear = appear,
                        maxNodes = p.optInt("max", 300),
                    )
                    if (r.matched) {
                        StepResult(true,
                            if (appear) "出现 ${r.node?.label() ?: ""}"
                            else "已消失（最后命中 ${r.node?.label() ?: "无"}）")
                    } else {
                        StepResult(false,
                            if (r.timedOut) "等待超时：文字未${if (appear) "出现" else "消失"}"
                            else "等待被中断")
                    }
                }
            }

            // ---- 开发者能力：只在开发者模式开启时可用 ----
            // ★ 开关本身不授予任何系统权限。这三项用的都是**已有**权限/通道：
            //   通知 → 已实现的 NotificationListenerService（用户需单独开通知使用权）；
            //   短信 → adb shell 身份查 content://sms（不声明 READ_SMS）；
            //   定位 → adb shell 读 dumpsys location 的最后已知位置（不声明定位权限）。
            "dev.notification" -> {
                requireDeveloper(ctx)?.let { return it }
                if (!IwphoneNotificationListener.isEnabled(ctx)) {
                    StepResult(false,
                        "通知使用权未开启：设置 → 通知 → 通知使用权（本开关不会替你授权）")
                } else {
                    val items = IwphoneNotificationListener.recentNotifications(
                        p.optString("package"), p.optInt("limit", 10))
                    StepResult(true, if (items.isEmpty()) {
                        "（暂无通知记录；服务刚连接时系统不会回放旧通知）"
                    } else {
                        items.joinToString("\n") {
                            "${it.pkg} | ${it.title} | ${it.text}"
                        }
                    })
                }
            }

            "dev.sms" -> {
                requireDeveloper(ctx)?.let { return it }
                val r = runAdb(ctx,
                    "content query --uri content://sms/inbox " +
                        "--projection address:body:date:read --sort 'date DESC'")
                if (!r.ok) StepResult(false, r.message)
                else {
                    val rows = parseSmsRows(
                        r.message, p.optString("sender"), p.optInt("limit", 10))
                    StepResult(true,
                        if (rows.isEmpty()) "（无匹配短信）" else rows.joinToString("\n"))
                }
            }

            "dev.location" -> {
                requireDeveloper(ctx)?.let { return it }
                val r = runAdb(ctx, "dumpsys location")
                if (!r.ok) StepResult(false, r.message)
                else {
                    val m = Regex(
                        """last location=Location\[(\S+)\s+([-+]?\d+(?:\.\d+)?),([-+]?\d+(?:\.\d+)?)\s+hAcc=(\d+)"""
                    ).find(r.message)
                    if (m == null) {
                        StepResult(false, "未读到已知位置（设备可能从未定位过）")
                    } else {
                        StepResult(true,
                            "provider=${m.groupValues[1]} " +
                                "lat=${m.groupValues[2]} lon=${m.groupValues[3]} " +
                                "hAcc=${m.groupValues[4]}m（系统最后已知位置，不是实时定位）")
                    }
                }
            }

            else -> StepResult(false, "未知模块: $moduleId")
        }
    }

    /** 开发者模式下才允许执行 dev.* 动作（模块里的 automation.json 也算）。 */
    private fun requireDeveloper(ctx: Context): StepResult? =
        if (UiPrefs.developerMode(ctx)) null
        else StepResult(false, "开发者模式未开启：设置 → 开发者模式")

    /**
     * 解析 `content query --uri content://sms/inbox` 的输出。
     *
     * 走 adb shell（shell uid）查询，**不需要给本 App 声明 READ_SMS** ——
     * 真机实测 shell 身份可以读 content://sms。代价是依赖 adb 通道在线。
     * body 里若出现 " date=" 之类的字面量会被正则提前截断，开发者工具可接受。
     */
    private fun parseSmsRows(raw: String, sender: String, limit: Int): List<String> {
        val re = Regex("""address=(.*?) body=(.*?) date=(\d+) read=(\d+)""")
        val fmt = java.text.SimpleDateFormat("MM-dd HH:mm", java.util.Locale.getDefault())
        val out = ArrayList<String>()
        for (m in re.findAll(raw)) {
            val address = m.groupValues[1]
            if (sender.isNotEmpty() && !address.contains(sender, ignoreCase = true)) continue
            val body = m.groupValues[2]
            val whenAt = try {
                fmt.format(java.util.Date(m.groupValues[3].toLong()))
            } catch (_: Exception) {
                m.groupValues[3]
            }
            val flag = if (m.groupValues[4] == "1") "已读" else "未读"
            out.add("$whenAt | $address | $flag | $body")
            if (out.size >= limit) break
        }
        return out
    }

    private fun runAdb(ctx: Context, cmd: String): StepResult {
        val r = AdbBootstrap.run(ctx,
            listOf("-s", AdbBootstrap.currentTarget(), "shell", cmd),
            timeoutMs = 30_000)
        return StepResult(r.ok, r.message)
    }

    // ---------------------------------------------------------------
    // 导出为 iwphone 模块包
    // ---------------------------------------------------------------

    /**
     * 把一个工作流打包成 `.iwp` 推到设备的 `iwphone/module/`。
     *
     * 包内三件东西：
     * - iwphone.prop —— 模块元信息（PackageName/version/author/description）
     * - main.sh      —— 一次性入口：本模块无常驻进程，只为让它在模块列表里可见可卸
     * - automation.json —— 真正的内容，App 从 work/<模块>/ 读回
     *
     * 走 [AdbBootstrap.importPackageBytes]，复用已经验证过的推送链路
     * （落 cacheDir → adb push → chmod），不新开一条写入路径。
     */
    fun exportModule(ctx: Context, wf: JSONObject, moduleName: String): StepResult {
        val name = sanitizeModuleName(moduleName)
        if (name.isEmpty()) return StepResult(false, "模块名不合法")

        val clean = JSONObject(wf.toString())
        clean.remove("source")
        clean.remove("readonly")
        clean.remove("module")

        val doc = JSONObject()
            .put("schema", 1)
            .put("name", wf.optString("name"))
            .put("workflows", JSONArray().put(clean))

        val bytes = try {
            buildIwp(name, wf.optString("name"), doc.toString(2))
        } catch (e: Exception) {
            return StepResult(false, "打包失败：${e.javaClass.simpleName}: ${e.message}")
        }

        val r = AdbBootstrap.importPackageBytes(ctx, bytes, "$name.iwp")
        return StepResult(r.ok, r.message)
    }

    /** 模块名会被 mod_install.sh 校验：不能有空白、不能带 `..` 或 `/`。 */
    private fun sanitizeModuleName(raw: String): String {
        val base = raw.trim()
            .replace(Regex("\\s+"), "_")
            .replace("..", "")
            .replace("/", "")
            .replace("\\", "")
        return base.take(48)
    }

    private fun buildIwp(name: String, title: String, automationJson: String): ByteArray {
        val prop = buildString {
            append("PackageName=").append(name).append('\n')
            append("version=1\n")
            append("versionCode=1\n")
            append("author=IWPhone\n")
            append("description=").append(title.ifBlank { "自动化模块" }).append('\n')
        }
        val mainSh = """
            #!/system/bin/sh
            # 纯自动化模块：没有常驻进程，只携带 automation.json。
            # App 从 /data/local/tmp/iwphone/work/${name}/automation.json 读取它。
            echo "[automation] ${name}: 无常驻进程，本模块只提供自动化声明"
            exit 0
        """.trimIndent() + "\n"

        val bos = ByteArrayOutputStream()
        ZipOutputStream(bos).use { zip ->
            fun put(entry: String, body: String) {
                zip.putNextEntry(ZipEntry(entry))
                zip.write(body.toByteArray(Charsets.UTF_8))
                zip.closeEntry()
            }
            put("iwphone.prop", prop)
            put("main.sh", mainSh)
            put("automation.json", automationJson)
            put("README.txt",
                "本模块由 IWPhone 导出，用于分发自动化工作流。\n" +
                    "安装后可在 App 的「自动化」页看到其中的流程。\n")
        }
        return bos.toByteArray()
    }

    data class StepResult(val ok: Boolean, val message: String)
    data class RunResult(val ok: Boolean, val message: String)
}
