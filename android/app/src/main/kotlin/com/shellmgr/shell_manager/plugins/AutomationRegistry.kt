package com.shellmgr.shell_manager.plugins

import android.content.Context
import com.shellmgr.shell_manager.AdbBootstrap
import org.json.JSONObject
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/**
 * 自动化编排注册表（P3）。
 *
 * 设计要点（全部来自 vFlow 的验证结论）：
 * - 触发器按增量更新（TriggerDelta），不做全量重建；
 * - 首订阅才监听（ListeningTriggerHandler）；
 * - 执行前二次校验能力/权限（PermissionGateway）；
 * - 30 秒×10 次失败熔断，只能手动恢复；
 * - 旧 .iwp 无 automation.prop / automation.json → 不产生触发器，行为零变化。
 *
 * ★ 这一版补上的关键空洞：以前「触发」只往事件总线发一条 `trigger:xxx` 事件，
 *   没有任何执行体，用户看到「武装成功」却什么都没发生。现在触发器绑定
 *   [binding]（真正要跑的代码），命中即在**单线程池**里执行：
 *   - 单线程 → 多个触发器同时命中时串行跑，不会交叉点击；
 *   - 不与主线程抢 → adb 调用和 delay 步骤不会拖住 UI（以前直接在事件回调里跑会 ANR）。
 */
class AutomationRegistry(
    private val ctx: Context,
    private val monitors: MonitorRegistry? = null,
) {
    private val specs = ConcurrentHashMap<String, AutomationSpec>()
    private val states = ConcurrentHashMap<String, ScriptState>()
    private val handlers = ConcurrentHashMap<String, TriggerHandler>()
    private val failure = ConcurrentHashMap<String, Pair<Int, Long>>()

    /** triggerId -> 命中后真正执行的动作。没有绑定的触发器只发事件（旧行为）。 */
    private val bindings = ConcurrentHashMap<String, () -> Boolean>()

    /** 已武装的工作流：id -> trigger key。持久化，冷启动后自动恢复。 */
    private val armedFlows = ConcurrentHashMap<String, String>()

    private val worker = Executors.newSingleThreadExecutor()
    private val busy = AtomicBoolean(false)
    private var lastSkipAt = 0L

    init {
        // 注意：**不能在这里读 SharedPreferences**。
        // MonitorChannel 是 MainActivity 的字段初始化器，那一刻 Activity 还没
        // attachBaseContext，`ctx.getSharedPreferences` 会 NPE 把启动打崩。
        // 武装状态改为在 restore() 里读（那时 Activity 已就绪）。

        // 事件触发器：订阅监视器事件，按 TriggerPresets 的过滤规则命中
        handlers["event"] = object : ListeningTriggerHandler() {
            private var cancel: (() -> Unit)? = null
            override fun startListening() {
                cancel = PlatformEventBus.subscribe("") { e ->
                    activeTriggers().forEach { t ->
                        val filter = t.parameters["on"] ?: ""
                        if (TriggerPresets.matches(filter, e)) {
                            dispatch(t, e.reason.ifEmpty { e.id })
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

    // ------------------------------------------------------------------
    // 触发 -> 执行
    // ------------------------------------------------------------------

    private fun dispatch(t: TriggerSpec, reason: String) {
        val exec = bindings[t.triggerId]
        if (exec == null) {
            // 没绑执行体：保持旧语义，只把命中事实发出去（事件日志里能看到）
            (handlers[t.type] as? ListeningTriggerHandler)?.fire(t, reason)
            return
        }
        if (busy.get()) {
            // 串行队列已经有人在跑：丢掉这一发，避免窗口事件把队列堆爆
            val now = System.currentTimeMillis()
            if (now - lastSkipAt > 1_000L) {
                lastSkipAt = now
                PlatformEventBus.publish(PlatformEvent(
                    id = "automation:${t.triggerId}",
                    kind = PlatformEvent.KIND_AUDIT,
                    reason = "上一次还在执行，跳过这一发（$reason）",
                    severity = PlatformEvent.SEVERITY_WARN,
                ))
            }
            return
        }
        busy.set(true)
        worker.execute {
            try {
                exec()
            } catch (e: Exception) {
                PlatformEventBus.publish(PlatformEvent(
                    id = "automation:${t.triggerId}",
                    kind = PlatformEvent.KIND_ERROR,
                    reason = "执行异常：${e.javaClass.simpleName}: ${e.message}",
                    severity = PlatformEvent.SEVERITY_ERROR,
                ))
            } finally {
                busy.set(false)
            }
        }
    }

    // ------------------------------------------------------------------
    // automation.prop（模块声明式自动化）
    // ------------------------------------------------------------------

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
        val m = raw.lines()
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
        val filter = spec.on.ifEmpty { spec.trigger }
        val triggerId = "$id:main"
        handlers["event"]?.addTrigger(TriggerSpec(triggerId, "event", mapOf("on" to filter)))
        bindings[triggerId] = { run(id) }
        keepMonitorAlive(filter, +1)
        states[id] = ScriptState.ARMED
        publish(id, ScriptState.ARMED,
            "已武装：${TriggerPresets.label(filter)}")
        return true
    }

    fun disarm(id: String) {
        handlers["event"]?.removeTrigger("$id:main")
        bindings.remove("$id:main")
        keepMonitorAlive(specs[id]?.on.orEmpty(), -1)
        states[id] = ScriptState.DISARMED
        publish(id, ScriptState.DISARMED, "已解除")
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

    // ------------------------------------------------------------------
    // 工作流武装（可视化流程 + 模块自带流程共用）
    // ------------------------------------------------------------------

    /**
     * 把工作流挂到某个触发器上。
     *
     * 会顺带订阅对应监视器 —— 没有订阅就没有轮询，触发器永远等不到事件，
     * 这是「武装了却不动」的另一个常见原因。
     */
    fun armWorkflow(id: String, trigger: String, executor: () -> Boolean): Boolean {
        // 注意不能只看预设表：应用级触发器（app_foreground:/notif_post:）不在表里，
        // 它们的 key 自带包名。eventPrefixOf 才是统一的解析入口。
        if (TriggerPresets.eventPrefixOf(trigger).isNullOrEmpty()) return false
        val triggerId = "wf:$id"
        handlers["event"]?.addTrigger(TriggerSpec(triggerId, "event", mapOf("on" to trigger)))
        bindings[triggerId] = executor
        armedFlows[id] = trigger
        saveArmed()
        keepMonitorAlive(trigger, +1)
        publishWorkflow(id, "已武装：${TriggerPresets.label(trigger)}", false)
        return true
    }

    fun disarmWorkflow(id: String) {
        val trigger = armedFlows.remove(id) ?: ""
        handlers["event"]?.removeTrigger("wf:$id")
        bindings.remove("wf:$id")
        keepMonitorAlive(trigger, -1)
        saveArmed()
        publishWorkflow(id, "已解除", false)
    }

    fun armed(): Map<String, String> = armedFlows.toMap()

    fun isWorkflowArmed(id: String): Boolean = armedFlows.containsKey(id)

    private fun publishWorkflow(id: String, reason: String, warn: Boolean) {
        PlatformEventBus.publish(PlatformEvent(
            id = "automation:$id",
            kind = PlatformEvent.KIND_STATE,
            reason = reason,
            severity = if (warn) PlatformEvent.SEVERITY_WARN else PlatformEvent.SEVERITY_INFO,
        ))
    }

    // ---- 武装状态持久化（冷启动后自动恢复） ----

    private fun prefs() = try {
        ctx.getSharedPreferences("iwphone_automation", Context.MODE_PRIVATE)
    } catch (_: Exception) {
        null
    }

    private fun loadArmed() {
        val raw = prefs()?.getString("armed", null) ?: return
        try {
            val o = JSONObject(raw)
            o.keys().forEach { k -> armedFlows[k] = o.optString(k) }
        } catch (_: Exception) {
        }
    }

    private fun saveArmed() {
        val o = JSONObject()
        armedFlows.forEach { (k, v) -> o.put(k, v) }
        prefs()?.edit()?.putString("armed", o.toString())?.apply()
    }

    /**
     * 冷启动恢复：把持久化的武装状态重新挂上。
     *
     * 分两段：
     * 1. 同步读 prefs —— 让 Dart 侧第一次查 `workflowArmed` 就能拿到正确结果；
     * 2. 异步重新挂载 —— 模块自带的流程要先 adb 扫一遍才知道内容，
     *    不能在主线程做（会卡首帧）。
     */
    fun restore() {
        loadArmed()
        if (armedFlows.isEmpty()) return
        worker.execute {
            val needScan = armedFlows.keys.any { it.startsWith("m_") }
            if (needScan) ModuleAutomation.scan(ctx, force = true)
            val snapshot = armedFlows.toMap()
            snapshot.forEach { (id, trigger) ->
                val wf = WorkflowStore.resolve(ctx, id) ?: return@forEach
                armWorkflow(id, trigger) { WorkflowStore.runWorkflow(ctx, wf).ok }
            }
        }
    }

    // ------------------------------------------------------------------

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

    /** 让触发器依赖的监视器保持被订阅（引用计数，退订不会误伤事件日志页）。 */
    private fun keepMonitorAlive(trigger: String, delta: Int) {
        val m = monitors ?: return
        val id = TriggerPresets.find(trigger)?.monitor ?: return
        if (delta > 0) m.subscribe(id) else m.unsubscribe(id)
    }

    fun all(): List<AutomationSpec> = specs.values.toList()
    fun state(id: String): ScriptState = states[id] ?: ScriptState.UNINSTALLED
}
