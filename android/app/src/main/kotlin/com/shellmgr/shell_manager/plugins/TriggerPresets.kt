package com.shellmgr.shell_manager.plugins

/**
 * 触发器预设 —— 把「什么时候触发」翻译成事件过滤。
 *
 * 为什么要有这一层：
 * 事件总线里跑的是 `monitor:framework` 这种 id，直接暴露给用户既看不懂、
 * 也没法表达「只在掉线时触发、恢复时不触发」。预设把
 * 「人话 + 事件前缀 + 关心哪几个状态 + 要保活的监视器」绑在一起，
 * UI 只展示 label/desc，运行时只认 key。
 *
 * 过滤器语法（内部）：`<事件 id 前缀>[@状态1|状态2]`
 * 例：`monitor:framework@STOPPED|ERROR`。
 * 裸前缀（`monitor:framework`，没有 @）继续支持 —— 旧模块的 automation.prop
 * 就是这么写的，不能因为改版让它们失效。
 */
object TriggerPresets {

    /**
     * 应用级触发器的 key 前缀。
     *
     * 为什么单独一套写法而不是塞进预设表：预设是**有限枚举**（下拉里几项就几项），
     * 而包名是无穷的。所以这两个前缀后面直接跟包名：
     *   `app_foreground:com.tencent.mm` → 监听事件 `a11y:fg:com.tencent.mm`
     *   `notif_post:com.tencent.mm`     → 监听事件 `notif:com.tencent.mm`
     * 包名部分留空表示「任意应用」。
     */
    const val APP_FOREGROUND = "app_foreground:"
    const val APP_NOTIFICATION = "notif_post:"

    data class Preset(
        /** 稳定 key，写进 workflow JSON 与 automation.json。 */
        val key: String,
        val label: String,
        val desc: String,
        /** 监听的事件 id 前缀；空串表示不监听（手动执行）。 */
        val eventPrefix: String,
        /** 只在这些「到达状态」上触发；空集合表示任意状态都触发。 */
        val states: Set<String>,
        /** 需要保活订阅的监视器 id（否则没人轮询，永远等不到事件）。 */
        val monitor: String?,
    )

    val all: List<Preset> = listOf(
        Preset(
            key = "manual",
            label = "手动执行",
            desc = "不自动触发，只在自动化页点「运行」时执行一次",
            eventPrefix = "",
            states = emptySet(),
            monitor = null,
        ),
        Preset(
            key = "framework_down",
            label = "框架停止运行",
            desc = "iwphone 守护进程（Main.sh）掉线、崩溃或未启动时触发",
            eventPrefix = "monitor:framework",
            states = setOf("DEGRADED", "ERROR", "STOPPED", "MAX_REACHED"),
            monitor = "framework",
        ),
        Preset(
            key = "framework_up",
            label = "框架恢复运行",
            desc = "守护进程重新拉起、状态回到运行中时触发一次",
            eventPrefix = "monitor:framework",
            states = setOf("RUNNING"),
            monitor = "framework",
        ),
        Preset(
            key = "adb_down",
            label = "adb 通道断开",
            desc = "自持 adb 与设备失联（无线调试掉线 / 端口变了）时触发",
            eventPrefix = "monitor:adb",
            states = setOf("DEGRADED", "ERROR", "STOPPED"),
            monitor = "adb",
        ),
        Preset(
            key = "module_exit",
            label = "模块退出",
            desc = "任一 iwphone 模块的进程消失时触发（reason 里带模块名）",
            eventPrefix = "monitor:module",
            states = setOf("STOPPED", "ERROR", "MAX_REACHED"),
            monitor = "module",
        ),
        Preset(
            key = "window_change",
            label = "前台界面切换",
            desc = "任何应用切换前台界面时触发，需要开启无障碍服务",
            eventPrefix = "a11y:window",
            states = emptySet(),
            monitor = "accessibility",
        ),
        Preset(
            key = "a11y_ready",
            label = "无障碍服务连上",
            desc = "无障碍服务被系统重新绑定后触发，适合做首次初始化",
            eventPrefix = "capability:accessibility",
            states = setOf("RUNNING"),
            monitor = "accessibility",
        ),
    )

    fun find(key: String): Preset? = all.firstOrNull { it.key == key }

    fun label(key: String): String = find(key)?.label ?: key

    /** 应用级触发器使用的包名；非应用级返回 null。 */
    fun appOf(key: String): String? = when {
        key.startsWith(APP_FOREGROUND) -> key.removePrefix(APP_FOREGROUND)
        key.startsWith(APP_NOTIFICATION) -> key.removePrefix(APP_NOTIFICATION)
        else -> null
    }

    /** 应用级触发器映射到的事件 id 前缀。 */
    fun eventPrefixOf(key: String): String? = when {
        key.startsWith(APP_FOREGROUND) -> "a11y:fg:" + key.removePrefix(APP_FOREGROUND)
        key.startsWith(APP_NOTIFICATION) -> "notif:" + key.removePrefix(APP_NOTIFICATION)
        else -> find(key)?.eventPrefix?.takeIf { it.isNotEmpty() }
    }

    /** 这个触发器是否依赖无障碍服务（UI 要提示去开）。 */
    fun needsAccessibility(key: String): Boolean =
        key.startsWith(APP_FOREGROUND) || find(key)?.monitor == "accessibility"

    /** 这个触发器是否依赖通知使用权。 */
    fun needsNotification(key: String): Boolean = key.startsWith(APP_NOTIFICATION)

    /**
     * 一条事件是否命中某个触发器。
     * 未登记的 key 按裸前缀处理（向后兼容旧 automation.prop 的 `on=`）。
     */
    fun matches(trigger: String, e: PlatformEvent): Boolean {
        if (trigger.isEmpty()) return false

        // 应用级：事件 id 本身就是 `a11y:fg:<包名>` / `notif:<包名>`。
        // 指定了包名就**精确匹配** —— 否则 `notif:com.a` 会误命中 `notif:com.abc`；
        // 包名留空(`notif_post:`)才按前缀走，表示任意应用。
        if (trigger.startsWith(APP_FOREGROUND) || trigger.startsWith(APP_NOTIFICATION)) {
            val app = appOf(trigger).orEmpty()
            val prefix = eventPrefixOf(trigger) ?: return false
            return if (app.isEmpty()) e.id.startsWith(prefix) else e.id == prefix
        }

        val preset = find(trigger)
        val prefix: String
        val states: Set<String>
        if (preset != null) {
            if (preset.eventPrefix.isEmpty()) return false
            prefix = preset.eventPrefix
            states = preset.states
        } else {
            val at = trigger.indexOf('@')
            prefix = if (at >= 0) trigger.substring(0, at) else trigger
            states = if (at >= 0) {
                trigger.substring(at + 1).split('|').filter { it.isNotEmpty() }.toSet()
            } else {
                emptySet()
            }
        }
        if (prefix.isEmpty() || !e.id.startsWith(prefix)) return false
        if (states.isEmpty()) return true
        return states.contains(e.to ?: "")
    }

    /** 供 UI 展示的 (key, label, desc) 三元组。 */
    fun describe(): List<Triple<String, String, String>> =
        all.map { Triple(it.key, it.label, it.desc) }
}
