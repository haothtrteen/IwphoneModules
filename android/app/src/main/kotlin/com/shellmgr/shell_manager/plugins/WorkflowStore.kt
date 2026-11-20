package com.shellmgr.shell_manager.plugins

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject
import com.shellmgr.shell_manager.AdbBootstrap
import java.io.ByteArrayOutputStream
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream

/**
 * 可视化工作流存储。
 *
 * 借鉴 vFlow：工作流 = 有序步骤列表，每步 = moduleId + parameters。
 * 模块目录由 Dart 侧声明（可视化表单的数据源），这里只负责持久化与执行，
 * 保持低耦合 —— 新增模块不需要改 Kotlin。
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

            else -> StepResult(false, "未知模块: $moduleId")
        }
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
            append("author=Shell Manager\n")
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
                "本模块由 Shell Manager 导出，用于分发自动化工作流。\n" +
                    "安装后可在 App 的「自动化」页看到其中的流程。\n")
        }
        return bos.toByteArray()
    }

    data class StepResult(val ok: Boolean, val message: String)
    data class RunResult(val ok: Boolean, val message: String)
}
