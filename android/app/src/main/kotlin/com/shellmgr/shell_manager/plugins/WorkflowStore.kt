package com.shellmgr.shell_manager.plugins

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject
import com.shellmgr.shell_manager.AdbBootstrap

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
     * 执行一个可视化工作流：顺序遍历步骤，按 moduleId 分派。
     * 此处只执行动作类步骤；触发器由 AutomationRegistry 的 event handler 负责。
     */
    fun run(ctx: Context, id: String): RunResult {
        val wf = get(ctx, id) ?: return RunResult(false, "工作流不存在: $id")
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
            val r = executeStep(ctx, moduleId, params)
            results.add("[$i] $moduleId: ${if (r.ok) "OK" else r.message}")
            if (!r.ok && wf.optBoolean("stopOnError", true)) {
                return RunResult(false, results.joinToString("; "))
            }
        }
        return RunResult(true, results.joinToString("; "))
    }

    private fun executeStep(ctx: Context, moduleId: String, p: JSONObject): StepResult {
        return when (moduleId) {
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
                val r = run(ctx, p.optString("workflow"))
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

    data class StepResult(val ok: Boolean, val message: String)
    data class RunResult(val ok: Boolean, val message: String)
}
