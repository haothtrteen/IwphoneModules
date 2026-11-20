package com.shellmgr.shell_manager.plugins

import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject

/**
 * 监视器 / 事件桥接层（P0）。
 *
 * MethodChannel "shellmgr/monitors"：列出监视器、查状态、订阅/退订、手动探测，
 * 以及可视化工作流的 CRUD / 武装 / 导出。
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
    private val automation = AutomationRegistry(activity, registry)
    private val capabilities = CapabilityRegistry().apply {
        register(ShellCapability())
        register(AdbShellCapability())
        register(WebUiCapability())
        register(AccessibilityCapability())
        register(NotificationCapability())
        register(ShizukuCapability())
    }
    private var eventSink: EventChannel.EventSink? = null
    private var cancelSubscribe: (() -> Unit)? = null

    private val main = Handler(Looper.getMainLooper())

    /**
     * 把会阻塞的调用（adb / 打包 / 执行流程）挪到后台线程，结果回主线程再回给 Dart。
     *
     * MethodChannel 的 handler 默认在**平台主线程**执行，直接在里面跑 adb
     * 就是拿 UI 卡顿换实现简单 —— 扫描模块自动化、执行工作流、探测都是几百毫秒起。
     */
    private fun background(result: MethodChannel.Result, block: () -> Any?) {
        Thread {
            val value = try {
                block()
            } catch (_: Exception) {
                null
            }
            main.post { result.success(value) }
        }.apply { isDaemon = true }.start()
    }

    fun register(messenger: BinaryMessenger) {
        // 注册内置监视器（只注册，不订阅；订阅由 Dart 侧或武装的触发器决定）
        registry.register(FrameworkMonitor())
        registry.register(AdbMonitor())
        registry.register(ModuleMonitor())

        // 冷启动恢复武装状态（内部走工作线程，不阻塞首帧）
        automation.restore()

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
                    background(result) { registry.probe(id, force = true).name }
                }
                // ---------------- 触发器预设 ----------------
                "triggerPresets" -> {
                    val arr = JSONArray()
                    TriggerPresets.describe().forEach { (key, label, desc) ->
                        arr.put(JSONObject().put("key", key).put("label", label).put("desc", desc))
                    }
                    result.success(arr.toString())
                }
                // ---------------- 工作流 CRUD ----------------
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
                    val id = call.argument<String>("id") ?: ""
                    background(result) {
                        val r = WorkflowStore.runAny(activity, id)
                        mapOf("ok" to r.ok, "msg" to r.message)
                    }
                }
                // ---------------- 模块自带的自动化 ----------------
                "moduleWorkflows" -> {
                    val force = call.argument<Boolean>("force") == true
                    background(result) {
                        val arr = JSONArray()
                        ModuleAutomation.scan(activity, force).forEach { arr.put(it) }
                        arr.toString()
                    }
                }
                "moduleAutomationError" -> result.success(ModuleAutomation.error())
                // ---------------- 武装 / 解除 ----------------
                "workflowArmed" -> {
                    val o = JSONObject()
                    automation.armed().forEach { (k, v) -> o.put(k, v) }
                    result.success(o.toString())
                }
                "workflowArm" -> {
                    val id = call.argument<String>("id") ?: ""
                    val trigger = call.argument<String>("trigger") ?: "manual"
                    val wf = WorkflowStore.resolve(activity, id)
                    if (wf == null) {
                        result.success(false)
                    } else {
                        val ok = automation.armWorkflow(id, trigger) {
                            WorkflowStore.runWorkflow(activity, wf).ok
                        }
                        result.success(ok)
                    }
                }
                "workflowDisarm" -> {
                    automation.disarmWorkflow(call.argument<String>("id") ?: "")
                    result.success(true)
                }
                // ---------------- 导出为 iwphone 模块 ----------------
                "workflowExport" -> {
                    val id = call.argument<String>("id") ?: ""
                    val name = call.argument<String>("name") ?: ""
                    background(result) {
                        val wf = WorkflowStore.resolve(activity, id)
                        if (wf == null) {
                            mapOf("ok" to false, "msg" to "工作流不存在")
                        } else {
                            val r = WorkflowStore.exportModule(activity, wf, name)
                            mapOf("ok" to r.ok, "msg" to r.message)
                        }
                    }
                }
                // ---------------- automation.prop ----------------
                "automations" -> {
                    val arr = JSONArray()
                    automation.all().forEach { s ->
                        arr.put(JSONObject()
                            .put("id", s.id)
                            .put("state", automation.state(s.id).name)
                            .put("trigger", s.trigger)
                            .put("triggerLabel", TriggerPresets.label(s.on.ifEmpty { s.trigger }))
                            .put("action", s.action))
                    }
                    result.success(arr.toString())
                }
                "automationLoad" -> {
                    val module = call.argument<String>("module") ?: ""
                    background(result) { automation.loadFromModule(module) != null }
                }
                "automationArm" -> {
                    val id = call.argument<String>("id") ?: ""
                    background(result) { automation.arm(id) }
                }
                "automationDisarm" -> {
                    automation.disarm(call.argument<String>("id") ?: "")
                    result.success(true)
                }
                "automationRun" -> {
                    val id = call.argument<String>("id") ?: ""
                    background(result) { automation.run(id) }
                }
                "capabilities" -> {
                    val arr = JSONArray()
                    capabilities.availabilitySnapshot(activity).forEach { (id, name, avail) ->
                        arr.put(JSONObject().put("id", id).put("name", name).put("availability", avail))
                    }
                    result.success(arr.toString())
                }
                // ---------------- 应用级触发器 ----------------
                "appList" -> background(result) { launchableApps() }
                "notificationAccess" -> result.success(IwphoneNotificationListener.isEnabled(activity))
                "accessibilityAccess" -> result.success(IwphoneAccessibilityService.isEnabled(activity))
                "openSettings" -> {
                    val kind = call.argument<String>("kind") ?: ""
                    val action = when (kind) {
                        "notification" -> Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS
                        "accessibility" -> Settings.ACTION_ACCESSIBILITY_SETTINGS
                        else -> Settings.ACTION_SETTINGS
                    }
                    val ok = try {
                        activity.startActivity(
                            Intent(action).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        )
                        true
                    } catch (_: Exception) {
                        false
                    }
                    result.success(ok)
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

    /**
     * 可启动应用列表（包名 + 显示名），给「某应用到前台 / 发通知」的选应用弹层用。
     *
     * 只列有 LAUNCHER 入口的应用：装了但没图标的系统组件出现在列表里只会干扰选择。
     * 排序用中文 Collator，否则「微信」会排到字母后面去。
     */
    private fun launchableApps(): String {
        val pm = activity.packageManager
        val intent = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
        val resolved = try {
            pm.queryIntentActivities(intent, 0)
        } catch (_: Exception) {
            emptyList()
        }
        val seen = HashSet<String>()
        val items = ArrayList<Pair<String, String>>()
        for (ri in resolved) {
            val pkg = ri.activityInfo?.packageName ?: continue
            if (pkg == activity.packageName) continue
            if (!seen.add(pkg)) continue
            val label = try {
                ri.loadLabel(pm).toString()
            } catch (_: Exception) {
                pkg
            }
            items.add(pkg to label.ifBlank { pkg })
        }
        val collator = java.text.Collator.getInstance(java.util.Locale.CHINA)
        items.sortWith(compareBy(collator) { it.second })

        val arr = JSONArray()
        items.forEach { (pkg, label) ->
            arr.put(JSONObject().put("pkg", pkg).put("label", label))
        }
        return arr.toString()
    }
}
