package com.shellmgr.shell_manager.plugins

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.AccessibilityServiceInfo
import android.content.Intent
import android.view.accessibility.AccessibilityEvent as A11yEvent

/**
 * 无障碍服务（C2 能力的最小实现）。
 *
 * 借鉴 vFlow AccessibilityService + ServiceStateBus 的分层：
 * 本服务只负责把系统 UI 事件转发到 PlatformEventBus，
 * 不做具体自动化动作 —— 动作留给后续 Automation 插件，
 * 避免把"监听"和"执行"耦合在一个类里（这也是 vFlow 的设计）。
 *
 * 零第三方依赖；不常驻轮询，事件驱动。
 */
class IwphoneAccessibilityService : AccessibilityService() {

    /**
     * 上一次进入前台的应用。
     *
     * 用来把「窗口变化」收敛成「应用切换」：同一个 App 内部弹个对话框、
     * 切个 Activity 也会发 TYPE_WINDOW_STATE_CHANGED，包名没变就不该算一次「到前台」。
     */
    private var lastForeground: String? = null

    override fun onServiceConnected() {
        super.onServiceConnected()
        instance = this
        try {
            serviceInfo = serviceInfo.apply {
                eventTypes = A11yEvent.TYPE_WINDOW_STATE_CHANGED or
                    A11yEvent.TYPE_WINDOW_CONTENT_CHANGED
                flags = flags or
                    AccessibilityServiceInfo.FLAG_REPORT_VIEW_IDS or
                    AccessibilityServiceInfo.FLAG_RETRIEVE_INTERACTIVE_WINDOWS
            }
        } catch (_: Exception) {
            // 部分 ROM 拒绝修改 flags，不影响基本事件接收
        }
        PlatformEventBus.publish(PlatformEvent(
            id = "capability:accessibility",
            kind = PlatformEvent.KIND_STATE,
            to = "RUNNING",
            reason = "accessibility service connected",
        ))
    }

    override fun onAccessibilityEvent(event: A11yEvent) {
        val pkg = event.packageName?.toString() ?: return
        val cls = event.className?.toString() ?: ""
        when (event.eventType) {
            A11yEvent.TYPE_WINDOW_STATE_CHANGED -> {
                PlatformEventBus.publish(
                    PlatformEvent(
                        id = "a11y:window",
                        kind = PlatformEvent.KIND_STATE,
                        reason = pkg,
                        payload = mapOf("package" to pkg, "class" to cls),
                    ),
                )
                // 应用级事件：包名变化才发，供 "某应用到前台" 触发器使用。
                // 跳过自己 —— 打开本 App 的界面不该触发用户配置的自动化。
                if (pkg != lastForeground && pkg != packageName) {
                    lastForeground = pkg
                    PlatformEventBus.publish(
                        PlatformEvent(
                            id = "a11y:fg:$pkg",
                            kind = PlatformEvent.KIND_STATE,
                            reason = pkg,
                            payload = mapOf("package" to pkg, "class" to cls),
                        ),
                    )
                    // 与通知监听对齐：留一条日志，方便 adb 侧确认「到前台」真的投递了
                    android.util.Log.d("IwphoneA11y", "a11y:fg:$pkg")
                }
            }
            A11yEvent.TYPE_WINDOW_CONTENT_CHANGED -> PlatformEventBus.publish(
                PlatformEvent(
                    id = "a11y:content",
                    kind = PlatformEvent.KIND_STATE,
                    reason = pkg,
                    payload = mapOf("package" to pkg, "class" to cls),
                ),
            )
        }
    }

    override fun onDestroy() {
        // 服务一断，UiActions 立刻不可用 —— 不留一个持有已死 Service 的静态引用
        if (instance === this) instance = null
        super.onDestroy()
    }

    override fun onInterrupt() {
        PlatformEventBus.publish(PlatformEvent(
            id = "capability:accessibility",
            kind = PlatformEvent.KIND_ERROR,
            reason = "accessibility interrupted",
            severity = PlatformEvent.SEVERITY_WARN,
        ))
    }

    override fun onUnbind(intent: Intent?): Boolean {
        PlatformEventBus.publish(PlatformEvent(
            id = "capability:accessibility",
            kind = PlatformEvent.KIND_STATE,
            to = "STOPPED",
            reason = "accessibility service unbound",
        ))
        return super.onUnbind(intent)
    }

    companion object {
        /**
         * 同进程内的服务引用，给 UiActions 读控件树用。
         *
         * 工作流步骤跑在 AutomationRegistry 的后台线程上，而无障碍服务与它同属
         * 一个 App 进程（Manifest 没指定独立 process），所以直接取单例即可，
         * 不需要再绕一层 Binder / ContentProvider。
         */
        @Volatile
        @JvmStatic
        var instance: IwphoneAccessibilityService? = null

        /** 用 adb 查询服务是否开启（不需要读系统安全设置）。 */
        fun isEnabled(ctx: android.content.Context): Boolean {
            val expected = ctx.packageName + "/" + IwphoneAccessibilityService::class.java.name
            val raw = android.provider.Settings.Secure.getString(
                ctx.contentResolver,
                android.provider.Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES,
            ) ?: return false
            return raw.split(':').any { it.equals(expected, ignoreCase = true) }
        }
    }
}
