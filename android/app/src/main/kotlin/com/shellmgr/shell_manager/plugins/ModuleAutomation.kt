package com.shellmgr.shell_manager.plugins

import android.content.Context
import com.shellmgr.shell_manager.AdbBootstrap
import org.json.JSONArray
import org.json.JSONObject

/**
 * 模块自带的自动化声明。
 *
 * 一个 `.iwp` 模块包除了 iwphone.prop / main.sh，还可以带一份 **automation.json**：
 * mod_install.sh 是整包 `unzip` 到 `work/<模块>/`，所以文件装完就在模块目录里，
 * App 不需要解压、不需要额外安装步骤。
 *
 * 设计取舍：
 * - **只读**：模块带来的自动化归模块所有，App 里不能改（改了下次更新模块就被覆盖，
 *   用户会以为改动丢了）。想改就「复制为我的一份」，落到本地工作流再编辑。
 * - **一次 adb 调用扫全部**：每个模块单独 `cat` 会为每个模块起一次 libadb 进程，
 *   十来个模块就要十几秒。这里用一段 shell 循环一次拿完。
 * - **30 秒缓存**：自动化页来回切不该反复走 adb。
 */
object ModuleAutomation {

    private const val MARK = "@@@IWPHONE_AUTOMATION:"

    private var cache: List<JSONObject> = emptyList()
    private var cacheAt = 0L
    private var lastError: String = ""

    fun cached(): List<JSONObject> = cache
    fun error(): String = lastError

    /**
     * 扫描所有模块目录下的 automation.json。
     *
     * @param force 忽略 30 秒缓存（用户点刷新、刚装完模块时用）
     */
    @Synchronized
    fun scan(ctx: Context, force: Boolean = false): List<JSONObject> {
        val now = System.currentTimeMillis()
        if (!force && now - cacheAt < 30_000L && cache.isNotEmpty()) return cache

        if (!AdbBootstrap.probeTransportAlive(ctx)) {
            lastError = "adb 通道不可用，读不到模块自动化"
            return cache
        }

        // 单个 shell 循环：逐模块打标记再 cat，避免 N 次进程启动
        val script = "for d in /data/local/tmp/iwphone/work/*/; do " +
            "n=\${d%/}; n=\${n##*/}; " +
            "if [ -f \"\$d/automation.json\" ]; then " +
            "echo \"$MARK\$n\"; cat \"\$d/automation.json\"; echo; fi; done"

        val r = AdbBootstrap.run(
            ctx,
            listOf("-s", AdbBootstrap.currentTarget(), "shell", script),
            timeoutMs = 15_000,
        )
        if (!r.ok) {
            lastError = r.message
            return cache
        }

        val parsed = parseSections(r.message)
        cache = parsed
        cacheAt = System.currentTimeMillis()
        lastError = ""
        return parsed
    }

    /** 把 `@@@IWPHONE_AUTOMATION:<模块名>` 分段输出切成 (模块名, JSON 文本)。 */
    fun parseSections(out: String): List<JSONObject> {
        val result = mutableListOf<JSONObject>()
        var module: String? = null
        val buf = StringBuilder()

        fun flush() {
            val name = module ?: return
            val text = buf.toString().trim()
            buf.setLength(0)
            if (text.isEmpty()) return
            result.addAll(parseOne(name, text))
        }

        for (line in out.split('\n')) {
            if (line.startsWith(MARK)) {
                flush()
                module = line.substring(MARK.length).trim()
            } else if (module != null) {
                buf.append(line).append('\n')
            }
        }
        flush()
        return result
    }

    private fun parseOne(module: String, text: String): List<JSONObject> {
        val workflows: JSONArray = try {
            val trimmed = text.trim()
            when {
                trimmed.startsWith("[") -> JSONArray(trimmed)
                else -> JSONObject(trimmed).optJSONArray("workflows") ?: JSONArray()
            }
        } catch (_: Exception) {
            lastError = "模块 $module 的 automation.json 解析失败"
            return emptyList()
        }
        return (0 until workflows.length()).mapNotNull { i ->
            workflows.optJSONObject(i)?.let { normalize(module, it) }
        }
    }

    /** 补上来源标记、全局唯一 id、默认字段 —— 让 UI 与本地工作流用同一套结构。 */
    private fun normalize(module: String, wf: JSONObject): JSONObject {
        val rawId = wf.optString("id").ifBlank { "wf" }
        val out = JSONObject(wf.toString())
        // 模块名 + 原始 id 才能全局唯一：两个模块都写 id=wifi 不该互相顶掉
        out.put("id", "m_${module}_$rawId")
        out.put("module", module)
        out.put("source", "iwphone 模块 · $module")
        out.put("readonly", true)
        if (out.optString("trigger").isBlank()) out.put("trigger", "manual")
        if (!out.has("stopOnError")) out.put("stopOnError", true)
        if (out.optString("name").isBlank()) out.put("name", rawId)
        return out
    }

    fun find(id: String): JSONObject? = cache.firstOrNull { it.optString("id") == id }
}
