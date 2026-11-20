package com.shellmgr.shell_manager.plugins

/**
 * 统一监视状态机：6 态 + COOLING / MAX_REACHED 两态节流。
 *
 * 借鉴 vFlow 的 TriggerStatus / RuleExecutionState：
 * 高频事件不能直接触发自动化，必须经过 Cooling 与 MaxReached 两道闸。
 */
enum class MonitorState {
    UNKNOWN,
    STARTING,
    RUNNING,
    DEGRADED,
    COOLING,
    MAX_REACHED,
    ERROR,
    STOPPED,
    ;

    val isHealthy: Boolean get() = this == RUNNING || this == STARTING
    val isTerminal: Boolean get() = this == ERROR || this == STOPPED || this == MAX_REACHED
}

data class ProbeResult(
    val state: MonitorState,
    val reason: String = "",
    val detail: Map<String, String> = emptyMap(),
)

data class RecoveryResult(
    val ok: Boolean,
    val message: String,
    val skipped: Boolean = false,
)
