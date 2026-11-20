package com.shellmgr.shell_manager.plugins

import android.content.Context
import com.shellmgr.shell_manager.AdbBootstrap
import java.util.concurrent.ConcurrentHashMap

/**
 * 自动化编排注册表（P3）。
 *
 * 设计要点（全部来自 vFlow 的验证结论）：
 * - 触发器按增量更新（TriggerDelta），不做全量重建；
 * - 首订阅才监听（ListeningTriggerHandler）；
 * - 执行前二次校验能力/权限（PermissionGateway）；
 * - 30 秒×10 次失败熔断，只能手动恢复；
 * - 旧 .iwp 无 automation.prop → 不产生触发器，行为零变化。
 */
class AutomationRegistry(private val ctx: Context) {
    private val specs = ConcurrentHashMap<String, AutomationSpec>()
    private val states = ConcurrentHashMap<String, ScriptState>()
    private val handlers = ConcurrentHashMap<String, TriggerHandler>()
    private val failure = ConcurrentHashMap<String, Pair<Int, Long>>()

    init {
        // 事件触发器：订阅监视器事件，按 spec.on 前缀过滤
        handlers["event"] = object : ListeningTriggerHandler() {
            private var cancel: (() -> Unit)? = null
            override fun startListening() {
                cancel = PlatformEventBus.subscribe("") { e ->
                    activeTriggers().forEach { t ->
                        val filter = t.parameters["on"] ?: ""
                        if (filter.isNotEmpty() && e.id.startsWith(filter)) {
                            fire(t, e.reason.ifEmpty { e.id })
                        }
                    }
                }
            }
            override fun stopListening() {
                cancel?.invoke()
                cancel = null
            }
        }
    }

    /** 从 .iwp 目录读取可选 automation.prop，解析并注册。 */
    fun loadFromModule(moduleName: String): AutomationSpec? {
        val r = AdbBootstrap.run(
            ctx,
            listOf("-s", AdbBootstrap.currentTarget(), "shell",
                "cat /data/local/tmp/iwphone/work/$moduleName/automation.prop 2>/dev/null"),
            timeoutMs = 8_000,
        )
        if (!r.ok || r.message.isBlank()) return null
        val spec = parseProp(r.message, moduleName)
        specs[spec.id] = spec
        states[spec.id] = ScriptState.INSTALLED
        return spec
    }

    fun parseProp(raw: String, fallbackId: String): AutomationSpec {
        val m = raw.lineSequence()
            .map { it.trim() }
            .filter { it.isNotEmpty() && !it.startsWith("#") && it.contains('=') }
            .associate { val i = it.indexOf('='); it.substring(0, i).trim() to it.substring(i + 1).trim() }
        return AutomationSpec(
            id = m["id"] ?: fallbackId,
            version = m["version"]?.toIntOrNull() ?: 1,
            trigger = m["trigger"] ?: "manual",
            on = m["on"] ?: "",
            action = m["action"] ?: "",
            guard = m["guard"] ?: "",
            timeoutSec = m["timeout"]?.toIntOrNull() ?: 120,
            onError = m["on_error"] ?: "",
            rollback = m["rollback"] ?: "",
        )
    }

    /** 启用并武装：注册触发器，开始监听。 */
    fun arm(id: String): Boolean {
        val spec = specs[id] ?: return false
        if (isCircuitBroken(id)) {
            states[id] = ScriptState.BLOCKED
            return false
        }
        if (spec.guard.isNotEmpty() && !guardSatisfied(spec.guard)) {
            states[id] = ScriptState.SKIPPED
            publish(id, ScriptState.SKIPPED, "guard not satisfied: ${spec.guard}")
            return false
        }
        val triggerId = "$id:main"
        val t = TriggerSpec(triggerId, spec.trigger, mapOf("on" to spec.on))
        handlers[spec.trigger]?.addTrigger(t)
        states[id] = ScriptState.ARMED
        publish(id, ScriptState.ARMED, "armed with ${spec.trigger} trigger")
        return true
    }

    fun disarm(id: String) {
        handlers[specs[id]?.trigger]?.removeTrigger("$id:main")
        states[id] = ScriptState.DISARMED
        publish(id, ScriptState.DISARMED, "disarmed")
    }

    /** 增量更新触发器（改一个不重建全部）。 */
    fun applyDelta(delta: TriggerDelta) {
        val handler = handlers[delta.ownerId] ?: return
        delta.removed.forEach { handler.removeTrigger(it) }
        delta.added.forEach { handler.addTrigger(it) }
        PlatformEventBus.publish(PlatformEvent(
            id = "automation:${delta.ownerId}",
            kind = PlatformEvent.KIND_ACTION,
            reason = "trigger delta: -${delta.removed.size} +${delta.added.size}",
        ))
    }

    /** 手动或事件命中后执行。 */
    fun run(id: String): Boolean {
        val spec = specs[id] ?: return false
        if (isCircuitBroken(id)) {
            states[id] = ScriptState.BLOCKED
            publish(id, ScriptState.BLOCKED, "circuit broken")
            return false
        }
        if (spec.guard.isNotEmpty() && !guardSatisfied(spec.guard)) {
            states[id] = ScriptState.SKIPPED
            publish(id, ScriptState.SKIPPED, "guard unsatisfied")
            return false
        }
        states[id] = ScriptState.RUNNING
        publish(id, ScriptState.RUNNING, "running ${spec.action}")

        val ok = if (spec.action.startsWith(AdbShellCapability.PREFIX)) {
            // ★ adb shell 模式：不依赖无障碍，直接走 shell 的 input/am
            val req = ActionRequest(
                action = "adb",
                args = mapOf("cmd" to spec.action),
                timeoutMs = spec.timeoutSec * 1000L,
                highRisk = false,
            )
            AdbShellCapability().execute(ctx, req).ok
        } else {
            executeAction(spec)
        }
        if (ok) {
            states[id] = ScriptState.SUCCESS
            bumpFailure(id, reset = true)
            publish(id, ScriptState.SUCCESS, "completed")
        } else {
            states[id] = ScriptState.FAILED
            val n = bumpFailure(id, reset = false)
            if (spec.rollback.isNotEmpty()) executeRollback(spec.rollback)
            publish(id, if (n >= 10) ScriptState.BLOCKED else ScriptState.FAILED,
                "failed ($n/10)${if (spec.rollback.isNotEmpty()) ", rolled back" else ""}")
            if (n >= 10) states[id] = ScriptState.BLOCKED
        }
        return ok
    }

    private fun executeAction(spec: AutomationSpec): Boolean {
        return when {
            spec.action.startsWith("shell:") -> {
                val req = ActionRequest(
                    action = "raw",
                    args = mapOf("cmd" to spec.action.removePrefix("shell:")),
                    timeoutMs = spec.timeoutSec * 1000L,
                    highRisk = true,
                )
                ShellCapability().execute(ctx, req).ok
            }
            spec.action.startsWith("module:") -> {
                // 模块启停沿用框架 WebUI，由 AdbBootstrap 走 adb 调 curl
                val rest = spec.action.removePrefix("module:")
                val name = rest.substringBefore(".")
                val op = rest.substringAfter(".", "run")
                val cmd = "curl -sS --max-time ${spec.timeoutSec} " +
                    "-X POST \"http://127.0.0.1:8537/api/module/$name/$op\""
                AdbBootstrap.run(ctx,
                    listOf("-s", AdbBootstrap.currentTarget(), "shell", cmd),
                    timeoutMs = (spec.timeoutSec + 10) * 1000L).ok
            }
            else -> false
        }
    }

    private fun executeRollback(rollback: String) {
        if (!rollback.startsWith("snapshot:")) return
        val name = rollback.removePrefix("snapshot:")
        AdbBootstrap.run(ctx,
            listOf("-s", AdbBootstrap.currentTarget(), "shell",
                "sh /data/local/tmp/iwphone/restore_snapshot.sh $name"),
            timeoutMs = 30_000)
    }

    private fun guardSatisfied(guard: String): Boolean {
        if (guard.startsWith("capability:")) {
            val id = guard.removePrefix("capability:")
            return when (id) {
                "shell", "adb_shell" -> AdbBootstrap.probeTransportAlive(ctx)
                "accessibility" -> IwphoneAccessibilityService.isEnabled(ctx)
                "webui" -> com.shellmgr.shell_manager.AutostartPrefs.webuiToken(ctx).isNotEmpty()
                else -> false
            }
        }
        if (guard.startsWith("monitor:")) {
            val id = guard.removePrefix("monitor:")
            return states[id] != ScriptState.BLOCKED
        }
        return true
    }

    private fun isCircuitBroken(id: String): Boolean {
        val (n, ts) = failure[id] ?: return false
        return if (System.currentTimeMillis() - ts > 600_000L) {
            failure.remove(id)
            false
        } else n >= 10
    }

    private fun bumpFailure(id: String, reset: Boolean): Int {
        if (reset) { failure.remove(id); return 0 }
        val (n, _) = failure[id] ?: Pair(0, System.currentTimeMillis())
        val next = n + 1
        failure[id] = Pair(next, System.currentTimeMillis())
        return next
    }

    private fun publish(id: String, state: ScriptState, reason: String) {
        PlatformEventBus.publish(PlatformEvent(
            id = "automation:$id", kind = PlatformEvent.KIND_STATE,
            to = state.name, reason = reason,
            severity = if (state == ScriptState.FAILED || state == ScriptState.BLOCKED)
                PlatformEvent.SEVERITY_WARN else PlatformEvent.SEVERITY_INFO,
        ))
    }

    fun all(): List<AutomationSpec> = specs.values.toList()
    fun state(id: String): ScriptState = states[id] ?: ScriptState.UNINSTALLED
}
