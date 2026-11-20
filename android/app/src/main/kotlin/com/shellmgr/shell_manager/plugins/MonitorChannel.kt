package com.shellmgr.shell_manager.plugins

import android.content.Context
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject

/**
 * 监视器 / 事件桥接层（P0）。
 *
 * MethodChannel "shellmgr/monitors"：列出监视器、查状态、订阅/退订、手动探测。
 * EventChannel  "shellmgr/events"：即时事件流（无缓存，晚订阅收不到历史事件）。
 *
 * 零第三方依赖：事件在 Kotlin 侧用 CopyOnWriteArrayList + Handler 实现，
 * 通过 EventChannel 的 StreamHandler 转发给 Dart。
 */
class MonitorChannel(private val activity: Context) {
    companion object {
        const val METHOD_CHANNEL = "shellmgr/monitors"
        const val EVENT_CHANNEL = "shellmgr/events"
    }

    private val registry = MonitorRegistry(activity)
    private val automation = AutomationRegistry(activity)
    private val capabilities = CapabilityRegistry().apply {
        register(ShellCapability())
        register(AdbShellCapability())
        register(WebUiCapability())
        register(AccessibilityCapability())
        register(ShizukuCapability())
    }
    private var eventSink: EventChannel.EventSink? = null
    private var cancelSubscribe: (() -> Unit)? = null

    fun register(messenger: BinaryMessenger) {
        // 注册内置监视器（只注册，不订阅；订阅由 Dart 侧决定）
        registry.register(FrameworkMonitor())
        registry.register(AdbMonitor())
        registry.register(ModuleMonitor())

        MethodChannel(messenger, METHOD_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "list" -> {
                    val arr = JSONArray()
                    registry.pluginIds().sorted().forEach { id ->
                        arr.put(JSONObject()
                            .put("id", id)
                            .put("state", registry.state(id).name)
                            .put("subscribers", 0))
                    }
                    result.success(arr.toString())
                }
                "state" -> result.success(registry.state(call.argument<String>("id") ?: "").name)
                "all" -> {
                    val o = JSONObject()
                    registry.all().forEach { (k, v) -> o.put(k, v.name) }
                    result.success(o.toString())
                }
                "subscribe" -> {
                    val ok = registry.subscribe(call.argument<String>("id") ?: "")
                    result.success(ok)
                }
                "unsubscribe" -> {
                    registry.unsubscribe(call.argument<String>("id") ?: "")
                    result.success(true)
                }
                "probe" -> {
                    val id = call.argument<String>("id") ?: ""
                    result.success(registry.probe(id, force = true).name)
                }
                // 可视化工作流 CRUD（Dart 侧持有模块目录与表单定义）
                "workflowList" -> {
                    val arr = JSONArray(WorkflowStore.list(activity).map { it })
                    result.success(arr.toString())
                }
                "workflowSave" -> {
                    val raw = call.argument<String>("json") ?: ""
                    try {
                        WorkflowStore.save(activity, JSONObject(raw))
                        result.success(true)
                    } catch (e: Exception) {
                        result.success(false)
                    }
                }
                "workflowDelete" -> {
                    WorkflowStore.delete(activity, call.argument<String>("id") ?: "")
                    result.success(true)
                }
                "workflowRun" -> {
                    val r = WorkflowStore.run(activity, call.argument<String>("id") ?: "")
                    result.success(mapOf("ok" to r.ok, "msg" to r.message))
                }
                "automations" -> {
                    val arr = JSONArray()
                    automation.all().forEach { s ->
                        arr.put(JSONObject()
                            .put("id", s.id)
                            .put("state", automation.state(s.id).name)
                            .put("trigger", s.trigger)
                            .put("action", s.action))
                    }
                    result.success(arr.toString())
                }
                "automationLoad" -> {
                    val spec = automation.loadFromModule(call.argument<String>("module") ?: "")
                    result.success(spec != null)
                }
                "automationArm" -> result.success(automation.arm(call.argument<String>("id") ?: ""))
                "automationDisarm" -> {
                    automation.disarm(call.argument<String>("id") ?: "")
                    result.success(true)
                }
                "automationRun" -> result.success(automation.run(call.argument<String>("id") ?: ""))
                "capabilities" -> {
                    val arr = JSONArray()
                    capabilities.availabilitySnapshot(activity).forEach { (id, name, avail) ->
                        arr.put(JSONObject().put("id", id).put("name", name).put("availability", avail))
                    }
                    result.success(arr.toString())
                }
                "subscriberCount" -> result.success(PlatformEventBus.subscriberCount())
                else -> result.notImplemented()
            }
        }

        EventChannel(messenger, EVENT_CHANNEL).setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                eventSink = events
                cancelSubscribe = PlatformEventBus.subscribe("") { e ->
                    val map = mapOf(
                        "id" to e.id, "kind" to e.kind,
                        "from" to (e.from ?: ""), "to" to (e.to ?: ""),
                        "reason" to e.reason, "severity" to e.severity,
                        "ts" to e.ts,
                    )
                    events?.success(map)
                }
            }

            override fun onCancel(arguments: Any?) {
                cancelSubscribe?.invoke()
                cancelSubscribe = null
                eventSink = null
            }
        })
    }

    fun registry(): MonitorRegistry = registry
}
