package com.shellmgr.shell_manager.plugins

/**
 * 自动化脚本声明（对应 .iwp 包内可选的 automation.prop）。
 *
 * 旧模块没有该文件 → 维持原行为，不产生 TriggerSpec。
 */
data class AutomationSpec(
    val id: String,
    val version: Int = 1,
    val trigger: String = "manual",       // event | cron | manual | boot
    val on: String = "",                  // trigger=event 时的事件过滤，如 "monitor:framework"
    val action: String = "",              // "module:<名>.run" / "shell:<cmd>" / "adb:tap x y"
    val guard: String = "",               // 前置条件，如 "capability:shell"
    val timeoutSec: Int = 120,
    val onError: String = "",
    val rollback: String = "",            // "snapshot:<模块名>"
)

/** 触发器 DTO：定义层与运行层唯一连接键是 type（插件 id）。 */
data class TriggerSpec(
    val triggerId: String,                // "${ownerId}:${stepId}"
    val type: String,
    val parameters: Map<String, String> = emptyMap(),
)

/** 增量更新：只传旧引用，改一个触发器不重建全部。 */
data class TriggerDelta(
    val ownerId: String,
    val removed: List<String> = emptyList(),
    val added: List<TriggerSpec> = emptyList(),
)

enum class ScriptState {
    INSTALLED, ENABLED, ARMED, TRIGGERED, RUNNING, SUCCESS,
    FAILED, SKIPPED, BLOCKED, DISARMED, DISABLED, UNINSTALLED,
}

/** 触发器处理器契约（对齐 vFlow ITriggerHandler）。 */
interface TriggerHandler {
    fun start()
    fun stop()
    fun addTrigger(t: TriggerSpec)
    fun removeTrigger(triggerId: String)
}

/**
 * 监听型 Handler：首个订阅才 startListening，最后退订才 stopListening。
 * 借鉴 vFlow ListeningTriggerHandler，避免常驻监听所有事件。
 */
abstract class ListeningTriggerHandler : TriggerHandler {
    private val active = java.util.concurrent.CopyOnWriteArrayList<TriggerSpec>()

    final override fun addTrigger(t: TriggerSpec) {
        val wasEmpty = active.isEmpty()
        active.add(t)
        if (wasEmpty) startListening()
    }

    final override fun removeTrigger(triggerId: String) {
        active.removeAll { it.triggerId == triggerId }
        if (active.isEmpty()) stopListening()
    }

    final override fun start() {}
    final override fun stop() {
        active.clear()
        stopListening()
    }

    protected fun activeTriggers(): List<TriggerSpec> = active.toList()

    /**
     * 把一次命中发到事件总线。
     *
     * 公开而非 protected：命中判定在 [AutomationRegistry] 里做（它才知道有没有
     * 绑定执行体），handler 只负责登记触发器，所以需要从外部调用。
     */
    fun fire(t: TriggerSpec, reason: String) {
        PlatformEventBus.publish(PlatformEvent(
            id = "trigger:${t.type}",
            kind = PlatformEvent.KIND_ACTION,
            reason = reason,
            payload = t.parameters + mapOf("triggerId" to t.triggerId),
        ))
    }

    abstract fun startListening()
    abstract fun stopListening()
}
